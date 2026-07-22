defmodule AshHateoas.Test.HandRouted do
  @moduledoc """
  A resource that routes one action itself and leaves the rest to derivation.

  Pins the precedence rule: an author's declaration wins, and derivation fills
  in only what was left unsaid. `:publish` is routed at a path no convention
  would produce, so a derived route replacing it would be visible rather than
  coincidentally identical. `:archive` is the control — same shape, undeclared,
  so it must be derived.

  A partial `routes` block is a partial declaration, not an opt-out.
  """

  use Ash.Resource,
    domain: AshHateoas.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource, AshHateoas.Resource]

  ets do
    private? true
  end

  json_api do
    type "hand_routed"

    routes do
      base "/hand_routeds"
      patch :publish, route: "/:id/ship-it"
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true
  end

  actions do
    defaults [:read, create: [:title], update: [:title]]

    update :publish do
      description "Routed by hand, at a path no convention would derive."
      require_atomic? false
    end

    update :archive do
      description "Same shape as :publish, but left to derivation."
      require_atomic? false
    end
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end
end
