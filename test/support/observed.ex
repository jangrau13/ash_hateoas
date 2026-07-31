defmodule AshHateoas.Test.Observed do
  @moduledoc """
  A resource exercising `observable` declarations: both reserved subjects and a
  property-level one, plus an `unrouted` update that must never notify.

  Deliberately public (`warn_on_missing_authorizers? false`) — an observable
  resource is the public-read case, since a hub re-fetching a topic carries no
  actor.
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
    observable :resource
    observable :collection
    observable :name
    unrouted :retitle
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
    attribute :email, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: [:name, :email], update: [:name, :email]]

    update :retitle do
      accept [:name]
    end
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end
end
