defmodule AshHateoas.Resource.Transformers.EnforceNotDelegable do
  @moduledoc """
  Installs the refusal on every action declared `not_delegable`.

  The author writes the declaration; the enforcement is derived from it — a
  resource author never wires up a change, exactly as they never write an
  affordance.

  Enforcing here rather than in a transport is what makes the rule
  transport-independent: `AshHateoas.Resource.Changes.EnforceNotDelegable` runs
  inside Ash, so a consumer calling `Ash.update/2` directly is refused
  identically to one going through the Hydra plug.

  ## Only where a change can run

  Read actions take preparations rather than changes, and generic actions run
  arbitrary code with no changeset. Neither is given the refusal, and the
  verifier warns instead — silently accepting a declaration that cannot be
  enforced would be worse than saying so at compile time.

  ## Prepended

  The refusal is the first change on the action, so it is added before any
  change the author wrote can act on the changeset.
  """

  use Spark.Dsl.Transformer

  alias AshHateoas.Resource.Changes
  alias Spark.Dsl.Transformer

  @change %Ash.Resource.Change{
    change: {Changes.EnforceNotDelegable, []},
    on: nil,
    only_when_valid?: false,
    description: "Refuses this action for a credential that does not commit.",
    always_atomic?: false,
    where: []
  }

  # Ordering is declared against Ash's own action transformers rather than
  # against everything: a blanket `after?(_) -> true` deadlocks with any
  # transformer claiming `before?(_) -> true`, which MarkPrimaryGet does.
  #
  # Only actions matter here, and Ash has finished building them by the time
  # extension transformers run, so no ordering is actually required.
  @impl true
  def after?(_), do: false

  @impl true
  def before?(_), do: false

  @impl true
  def transform(dsl_state) do
    declared = AshHateoas.Resource.Info.not_delegable(dsl_state)

    {:ok,
     Enum.reduce(declared, dsl_state, fn action_name, acc ->
       install(acc, action_name)
     end)}
  end

  defp install(dsl_state, action_name) do
    case Ash.Resource.Info.action(dsl_state, action_name) do
      %{type: type} = action when type in [:create, :update, :destroy] ->
        Transformer.replace_entity(
          dsl_state,
          [:actions],
          %{action | changes: [@change | action.changes]},
          &(&1.name == action_name)
        )

      _other ->
        # Missing, or of a type that takes no changes. The verifier reports it;
        # this stays silent rather than raising a second, less informative error.
        dsl_state
    end
  end
end
