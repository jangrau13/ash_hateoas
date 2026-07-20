defmodule AshHateoas.Gate do
  @moduledoc """
  A filter in the affordance pipeline (§3).

  Gates are an **ordered, composable chain**, not hardcoded branches. Each gate
  receives the surviving candidate actions plus the request context, and returns
  a possibly-reduced list. The chain short-circuits when the list empties.

  Three consequences the requirements need anyway:

    * the state gate is just another entry, present only when
      `ash_state_machine` is — no capability branching inside the backbone
    * a consumer can insert their own gate (a tenancy rule, a feature flag)
      without forking this package
    * each gate is independently testable

  ## Implementing a gate

      defmodule MyApp.FeatureFlagGate do
        @behaviour AshHateoas.Gate

        @impl true
        def filter(candidates, %AshHateoas.Gate.Context{} = ctx) do
          Enum.reject(candidates, &MyApp.Flags.hidden?(&1.name, ctx.actor))
        end
      end

  Then pass it through: `AshHateoas.affordances(record, actor, gates: [...])`.
  """

  alias AshHateoas.Gate.Context

  @doc """
  Reduce the candidate action list.

  Receives `Ash.Resource.Actions` structs and MUST return a subset of them.
  A gate must not add candidates, and must not raise for an expected outcome —
  filtering is the mechanism for "not available".
  """
  @callback filter(candidates :: [struct()], context :: Context.t()) :: [struct()]
end

defmodule AshHateoas.Gate.Context do
  @moduledoc """
  Everything a gate needs to decide, threaded through the chain unchanged.

  `record` is `nil` for collection-level affordances (R9) — there is no record
  in hand, so gates that reason about record state (such as the state machine
  gate) MUST treat `nil` as "not applicable" and pass candidates through.
  """

  @type t :: %__MODULE__{
          resource: module(),
          record: struct() | nil,
          actor: term(),
          domain: module(),
          tenant: term()
        }

  @enforce_keys [:resource, :domain]
  defstruct [:resource, :record, :actor, :domain, :tenant]
end

defmodule AshHateoas.Gate.Chain do
  @moduledoc """
  Runs gates in order, short-circuiting as soon as no candidates remain.
  """

  alias AshHateoas.Gate.Context

  @doc """
  Apply each gate in turn.

  Returns the surviving candidates. Stops early on an empty list, so an
  expensive gate never runs for a record whose candidates were already
  eliminated by a cheap one — order gates cheapest-first.
  """
  @spec run([struct()], [module()], Context.t()) :: [struct()]
  def run(candidates, gates, %Context{} = context) do
    Enum.reduce_while(gates, candidates, fn gate, acc ->
      case gate.filter(acc, context) do
        [] -> {:halt, []}
        remaining -> {:cont, remaining}
      end
    end)
  end
end
