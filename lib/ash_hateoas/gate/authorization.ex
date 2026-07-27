defmodule AshHateoas.Gate.Authorization do
  @moduledoc """
  Drops actions the actor may not invoke.

  Calls `Ash.can?/3` exactly as Ash provides it — no option tuning. This is the
  **single source of truth** invariant: the same function the endpoint will use
  on invocation decides what is advertised, so affordances and endpoints cannot
  diverge into two implementations of one policy.

  ## Posture on undecidable authorization

  In practice this is precise, not optimistic. Record-level checks pass the
  record as the subject, so `run_queries?` (default `true`) lets Ash resolve
  record-dependent policies — `expr(owner_id == ^actor(:id))` answers `true` for
  the owner and `false` for anyone else, rather than degrading to `:maybe`.

  Where a decision genuinely cannot be reached, `Ash.can?/3` defaults to
  `maybe_is: true` and answers `true`, so the affordance is advertised. The
  consequence is accepted: a client may occasionally be offered an action
  it turns out not to be permitted, and receive a `403`. Affordances are
  advisory — the endpoint re-runs every policy on invocation, so an optimistic
  proposal degrades to a clean error, never an invalid write.

  ## The probe runs preparations, and preparations can raise

  The probe supplies no arguments, and for a read/create/action `Ash.can?/3`
  normalizes `{resource, action}` to `for_read(action, %{})`, which RUNS the
  action's preparations. A preparation that dereferences a required argument
  then meets `nil` and raises — a semantic search whose `prepare` embeds the
  query is the canonical case (`"search_query: " <> nil`). That is the query
  being malformed by the empty probe, not the authorization failing.

  So a raise is not taken at face value. It is retried against a query with the
  action set directly and `for_read` never called, so the preparation pipeline
  never runs (`authorized_without_preparations/2`). Skipping preparations does
  not weaken the check: policies authorize the ACTION, preparations shape WHICH
  ROWS. If the retry answers, that answer stands and the action is advertised
  as it should be.

  ## Errors are loud

  If the preparation-free retry ALSO raises, the exception was a genuine
  fault — a policy check itself blew up — not a missing argument. That is
  logged with full context and the affordance dropped: silently degrading a
  real bug into a missing affordance is unacceptable on an
  authorization-adjacent surface.

  Known limit: an action whose POLICY (not preparation) depends on an argument
  value — `authorize_if expr(^arg(:tier) == "public")` — resolves that arg to
  `nil` during the probe and is decided `false`, so it is not advertised even
  though some input would authorize it. This predates the retry above and is
  unchanged by it; `Ash.can?/3` returns a definite `false` here rather than
  `:maybe`, so no option flips it, and telling an argument-driven `false` from a
  genuine denial needs reaching into Ash's policy internals. Left as a known
  gap rather than fixed fragilely.

  ## Resources with no authorizers

  `Ash.can?/3` short-circuits to `true` before evaluating anything when a
  resource declares no authorizers. Such a resource advertises every routed
  action to every actor, including anonymous ones. That is correct Ash
  semantics — no policies means no restrictions — and this gate does not
  override it. `AshHateoas.Resource`'s verifier warns at compile time instead.
  """

  @behaviour AshHateoas.Gate

  require Logger

  alias AshHateoas.Gate.Context

  @impl AshHateoas.Gate
  def filter(candidates, %Context{} = context) do
    Enum.filter(candidates, &authorized?(&1, context))
  end

  defp authorized?(action, %Context{} = context) do
    # `:domain` is consumed by Ash.Helpers.domain!/2 before the option schema is
    # validated, so it is accepted here but is NOT in @can_opts — passing it to
    # Ash.can/3 would be rejected outright. Only forward `:tenant`, and let the
    # domain be resolved from the resource, which the backbone already verified.
    Ash.can?(subject(action, context), context.actor, can_opts(action, context))
  rescue
    exception ->
      # The probe runs with no arguments, and for a read/create/action that Ash
      # is `{resource, action}` normalized to `for_read(action, %{})`, which
      # RUNS the action's preparations. A preparation that dereferences a
      # required argument then hits `nil` and raises — the query is malformed,
      # not the authorization. Retry against a query the same probe would build
      # WITHOUT running preparations; if that answers, the raise was the missing
      # argument and the action is authorizable, so honour that answer.
      case authorized_without_preparations(action, context) do
        {:ok, decision} ->
          decision

        :error ->
          # A genuine raise — a policy check itself blew up — survives the
          # preparation-free retry too. Keep the loud log and drop: a real
          # bug must not be silently degraded into a missing affordance.
          Logger.error("""
          [ash_hateoas] Authorization check raised while computing affordances; \
          dropping #{inspect(action.name)}.

            resource: #{inspect(context.resource)}
            action:   #{inspect(action.name)}
            record:   #{record_label(context.record)}
            actor:    #{inspect(context.actor)}

          #{Exception.format(:error, exception, __STACKTRACE__)}
          """)

          false
      end
  end

  # Authorize the action WITHOUT running its preparations.
  #
  # `Ash.can?` re-runs preparations when handed `{resource, action}` (via
  # `for_read`) but takes a pre-built `%Ash.Query{}` as-is. So a query with the
  # action set directly — never through `for_read` — carries the policies but
  # not the preparation pipeline that crashed on the missing argument.
  #
  # This does not weaken the check: policies authorize the ACTION, while
  # preparations shape WHICH ROWS. Verified against both a `forbid_if always()`
  # and a record-dependent `expr(owner == ^actor(...))` policy — the
  # preparation-free query denies and permits exactly as the normal path does.
  # Only a read/create/action has preparations to skip; a member subject that is
  # a plain record has none, so this applies to the resource/query forms.
  defp authorized_without_preparations(action, %Context{} = context) do
    query =
      context.resource
      |> Ash.Query.new()
      |> Map.put(:action, action)

    {:ok, Ash.can?(query, context.actor, can_opts(action, context))}
  rescue
    _ -> :error
  end

  # Record-level uses {record, action}, which makes Ash inject `data: [record]`
  # so record-dependent policies see the record. Collection-level has no record,
  # so the subject is the resource itself.
  defp subject(action, %Context{record: nil, resource: resource}), do: {resource, action}
  defp subject(action, %Context{record: record}), do: {record, action}

  # Read policies produce FILTERS rather than a yes/no answer, so the question
  # "may you see THIS record?" is expressed by passing `data:`.
  #
  # Measured: for a filter policy (`expr(owner_id == ^actor(:id))`) with the
  # record as subject, Ash already resolves it correctly without `data:` —
  # owner true, stranger false either way. This is belt-and-braces, matching the
  # documented idiom, and guards the cases where the record is not automatically
  # threaded into the query.
  defp can_opts(%{type: :read}, %Context{record: record} = context) when not is_nil(record) do
    [tenant: context.tenant, data: record]
  end

  defp can_opts(_action, %Context{} = context) do
    [tenant: context.tenant]
  end

  defp record_label(nil), do: "(none — collection-level)"

  defp record_label(record) do
    case Map.get(record, :id) do
      nil -> inspect(record.__struct__)
      id -> "#{inspect(record.__struct__)}<#{inspect(id)}>"
    end
  end
end
