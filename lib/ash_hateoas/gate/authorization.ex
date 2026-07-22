defmodule AshHateoas.Gate.Authorization do
  @moduledoc """
  Drops actions the actor may not invoke (R6, R7).

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
  consequence is accepted (R6): a client may occasionally be offered an action
  it turns out not to be permitted, and receive a `403`. Affordances are
  advisory — the endpoint re-runs every policy on invocation, so an optimistic
  proposal degrades to a clean error, never an invalid write.

  ## Errors are loud (R7)

  `Ash.can?/3` raises rather than returning a tagged tuple, so a raising policy
  check surfaces as an exception. Every exception is logged with full context
  before the affordance is dropped — silently degrading a real bug into a
  missing affordance is unacceptable on an authorization-adjacent surface.

  The limit of this approach: a raised forbidden-error and a genuine bug arrive
  through the same clause and cannot be told apart here. Both are logged;
  neither is swallowed.

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
    subject = subject(action, context)

    # `:domain` is consumed by Ash.Helpers.domain!/2 before the option schema is
    # validated, so it is accepted here but is NOT in @can_opts — passing it to
    # Ash.can/3 would be rejected outright. Only forward `:tenant`, and let the
    # domain be resolved from the resource, which the backbone already verified.
    Ash.can?(subject, context.actor, can_opts(action, context))
  rescue
    exception ->
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

  # Record-level uses {record, action}, which makes Ash inject `data: [record]`
  # so record-dependent policies see the record. Collection-level has no record
  # (R9), so the subject is the resource itself.
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
