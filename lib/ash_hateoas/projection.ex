defmodule AshHateoas.Projection do
  @moduledoc """
  What the affordance set would be at another state (R10).

  A refusal carries this so the party who must commit is approving a
  **direction** rather than a keystroke. A known failure mode of approval
  systems is the indistinguishable request approved by reflex; a refusal that
  says only "not permitted" invites exactly that.

  ## Nothing is executed. **MUST.**

  `Ash.Changeset.for_update/4` was considered and rejected: it runs change
  modules, and a change module doing I/O — a charge, a webhook, a mail — fires
  at build time. No option makes an arbitrary action safe to simulate, and a
  preview that issues ten refunds is worse than no preview.

  So this substitutes the state attribute on an in-memory struct and re-runs the
  gates. The record is never written, read back, or passed to a changeset.

  ## The record is a fiction in every attribute but one. **MUST NOT** authorize
  with this.

  Only the state attribute is set to the target. Everything else is the record
  as it is now — so a policy depending on an attribute the action *would* have
  changed answers about a record that will never exist. This is a projection for
  a person to read. Authorization is `Ash.can?/3` at invocation, on the real
  record, and this never substitutes for it.

  ## Cost

  This re-runs the full gate chain, including `Ash.can?/3`, which may query per
  candidate. It is acceptable only because it happens on a **refusal** — once,
  for one action, for an actor already receiving an error. It MUST NOT be
  computed while rendering affordances (R8).
  """

  alias AshHateoas.Affordance

  @typedoc "What an action would make available, and what it would take away."
  @type delta :: %{
          to: atom(),
          gained: %{atom() => Affordance.t()},
          lost: [atom()]
        }

  @doc """
  Target states `action` could move `record` into.

  Reads `ash_state_machine`'s transitions, which are in-memory DSL data. Returns
  `[]` when the package is absent, when the resource has no state machine, or
  when the action is not a transition — all of which mean "nothing to project",
  and which R10 requires be distinguishable from "nothing downstream".
  """
  @spec target_states(module(), struct(), atom()) :: [atom()]
  def target_states(resource, record, action_name) do
    if state_machine?(resource) do
      current = current_state(resource, record)

      resource
      |> transitions_for(action_name)
      |> Enum.filter(&startable_from?(&1, current))
      |> Enum.flat_map(&List.wrap(&1.to))
      |> Enum.uniq()
    else
      []
    end
  end

  @doc """
  The affordance set as it would be with `record` in `target_state`.

  Computed with the **requesting** actor: projecting another actor's future into
  this actor's refusal would mix two authorities in one payload.
  """
  @spec for_target_state(module(), struct(), term(), atom(), keyword()) ::
          AshHateoas.Backbone.envelope()
  def for_target_state(resource, record, actor, target_state, opts \\ []) do
    case state_attribute(resource) do
      nil ->
        %{}

      attribute ->
        record
        |> Map.put(attribute, target_state)
        |> AshHateoas.affordances(actor, opts)
    end
  end

  @doc """
  What each reachable state would gain and lose, relative to now.

  One entry per target state. Where a transition declares several, the result
  has several entries and a consumer MUST present them as alternatives rather
  than choosing one (R10).

  Returns `[]` when there is nothing to project, which a consumer MUST render
  differently from a projection that is empty because nothing changes.
  """
  @spec deltas(module(), struct(), term(), atom(), keyword()) :: [delta()]
  def deltas(resource, record, actor, action_name, opts \\ []) do
    current = AshHateoas.affordances(record, actor, opts)

    resource
    |> target_states(record, action_name)
    |> Enum.map(fn target ->
      projected = for_target_state(resource, record, actor, target, opts)

      %{
        to: target,
        gained: Map.drop(projected, Map.keys(current)),
        lost: current |> Map.keys() |> Enum.reject(&Map.has_key?(projected, &1)) |> Enum.sort()
      }
    end)
  end

  defp state_machine?(resource) do
    AshHateoas.Gate.StateMachine.available?() and AshStateMachine in Spark.extensions(resource)
  rescue
    _ -> false
  end

  defp state_attribute(resource) do
    AshStateMachine.Info.state_machine_state_attribute!(resource)
  rescue
    _ -> nil
  end

  defp current_state(resource, record) do
    case state_attribute(resource) do
      nil -> nil
      attribute -> Map.get(record, attribute)
    end
  end

  defp transitions_for(resource, action_name) do
    AshStateMachine.Info.state_machine_transitions(resource, action_name)
  rescue
    _ -> []
  end

  # `:*` is expanded at compile time but consuming code re-checks defensively —
  # AshHateoas.Gate.StateMachine documents both wildcard traps.
  defp startable_from?(transition, current_state) do
    from = List.wrap(transition.from)

    current_state in from or :* in from
  end
end
