defmodule AshHateoas.Test.Paged do
  @moduledoc """
  A resource whose primary read declares offset pagination, so the Hydra
  collection response carries a `hydra:PartialCollectionView`.
  """

  use Ash.Resource,
    domain: AshHateoas.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshHateoas.Resource]

  ets do
    private?(true)
  end

  hateoas do
    type("paged")
    base("/paged")
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true, allow_nil?: false)
  end

  actions do
    defaults([:destroy, create: [:label]])

    read :read do
      primary?(true)
      pagination(offset?: true, countable: true, required?: false, default_limit: 2)
    end
  end

  policies do
    policy always() do
      authorize_if(always())
    end
  end
end
