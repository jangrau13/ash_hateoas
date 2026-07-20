defmodule AshHateoas.Gate.StateMachine do
  @moduledoc """
  Drops actions that are not legal transitions from the record's current state.

  Authorization is not validity. An actor authorized to run a transition must
  still not see it advertised from a state the transition cannot start in —
  otherwise the affordance is a promise the endpoint will refuse.

  Transitions are in-memory DSL data, so this gate costs nothing: no DB hit, no
  policy evaluation.

  ## Optional dependency

  `ash_state_machine` is optional. This module compiles only when it is present,
  and even then applies per resource: a resource without a state machine passes
  through untouched. `AshHateoas.Gate.Chain` includes this gate only when
  `available?/0` says so.

  ## Two wildcard traps

  `:*` is handled asymmetrically by `ash_state_machine`, and both halves matter:

    * **Action `:*`** — `state_machine_transitions/2` filters on
      `action == :* or action == name`, so a wildcard transition applies to
      every action. That is handled by using the arity-2 lookup.

    * **State `:*`** — expanded at compile time by a transformer, but consuming
      code still re-checks defensively (see `AshStateMachine.possible_next_states/1`).
      This gate does the same: `current_state in from or :* in from`.

  Also: `@type` declares `from: [atom]`, but the entity schema allows a bare
  atom. Every access goes through `List.wrap/1`.
  """

  @behaviour AshHateoas.Gate

  alias AshHateoas.Gate.Context

  @doc "Whether `ash_state_machine` is available to this build."
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(AshStateMachine.Info)

  @impl AshHateoas.Gate
  def filter(candidates, %Context{record: nil}), do: candidates

  def filter(candidates, %Context{} = context) do
    if available?() and state_machine?(context.resource) do
      current = current_state(context)

      Enum.filter(candidates, &legal?(&1, context.resource, current))
    else
      candidates
    end
  end

  # An action that is not a transition at all is unaffected by the state gate —
  # only actions the state machine actually governs are filtered.
  defp legal?(action, resource, current_state) do
    case transitions_for(resource, action.name) do
      [] -> true
      transitions -> Enum.any?(transitions, &startable_from?(&1, current_state))
    end
  end

  defp startable_from?(transition, current_state) do
    from = List.wrap(transition.from)

    current_state in from or :* in from
  end

  defp transitions_for(resource, action_name) do
    AshStateMachine.Info.state_machine_transitions(resource, action_name)
  rescue
    _ -> []
  end

  defp current_state(%Context{record: record, resource: resource}) do
    attribute = AshStateMachine.Info.state_machine_state_attribute!(resource)

    Map.get(record, attribute)
  rescue
    _ -> nil
  end

  defp state_machine?(resource) do
    AshStateMachine in Spark.extensions(resource)
  rescue
    _ -> false
  end
end
