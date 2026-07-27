defmodule AshHateoas.Test.HandRouted do
  @moduledoc """
  A resource with two same-shaped update actions, both routed by derivation.

  Under the Hydra transport every route is derived — there is no hand-routing —
  so `:publish` and `:archive` both derive to `/:id/<name>`. Kept as a
  multi-update resource; the old "declared route wins" precedence it once pinned
  no longer exists.
  """

  use Ash.Resource,
    domain: AshHateoas.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshHateoas.Resource]

  ets do
    private? true
  end

  hateoas do
    type "hand_routed"
    base "/hand_routeds"
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
