defmodule AshHateoas.Test.Order do
  @moduledoc """
  A resource with a real state machine, to exercise the state gate.

  The transition graph is deliberately linear with one wildcard:

      pending --confirm--> confirmed --ship--> shipped --deliver--> delivered
         |                     |
         +---------------------+--cancel--> cancelled   (from :* )

  So from `:pending`, `:confirm` and `:cancel` are legal but `:ship` is not —
  even for an actor authorized to run every action.
  """

  use Ash.Resource,
    domain: AshHateoas.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine, AshHateoas.Resource]

  ets do
    private? true
  end

  hateoas do
    type "order"
    base "/orders"
    # Sharpen the state transitions beyond their inferred UpdateAction.
    semantic_action :confirm, "ConfirmAction"
    semantic_action :ship, "ShipAction"
  end

  attributes do
    uuid_primary_key :id
    attribute :reference, :string, public?: true
  end

  state_machine do
    initial_states([:pending])
    default_initial_state(:pending)

    transitions do
      transition(:confirm, from: :pending, to: :confirmed)
      transition(:ship, from: :confirmed, to: :shipped)
      transition(:deliver, from: :shipped, to: :delivered)
      # A wildcard `from`: cancelling is legal from any state.
      transition(:cancel, from: :*, to: :cancelled)
    end
  end

  actions do
    defaults [:read, create: [:reference]]

    update :confirm do
      description "Confirm this order."
      require_atomic? false
      change transition_state(:confirmed)
    end

    update :ship do
      description "Ship this order."
      require_atomic? false
      change transition_state(:shipped)
    end

    update :deliver do
      description "Mark this order delivered."
      require_atomic? false
      change transition_state(:delivered)
    end

    update :cancel do
      description "Cancel this order."
      require_atomic? false
      change transition_state(:cancelled)
    end
  end

  policies do
    # Deliberately permissive: the state gate must be what filters here, not
    # authorization. If a test sees an action withheld, it is the state gate.
    policy always() do
      authorize_if always()
    end
  end
end
