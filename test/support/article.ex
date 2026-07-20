defmodule AshHateoas.Test.Article do
  @moduledoc """
  Exercises the `hateoas` DSL: an exclusion and an override on a resource that
  carries the extension.
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
    type "article"

    routes do
      base "/articles"
      get :read, primary?: true
      index :read
      post :create
      patch :update
      patch :internal_reconcile, route: "/:id/reconcile"
      patch :publish, route: "/:id/publish"
    end
  end

  hateoas do
    # Routed for internal callers, but never advertised.
    exclude :internal_reconcile
    override :publish, href: "/custom/publish/:id"
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true, allow_nil?: false
  end

  actions do
    defaults [:read, create: [:title], update: [:title]]

    update :publish do
      description "Publish this article."
      require_atomic? false
    end

    update :internal_reconcile do
      description "Reconcile internal bookkeeping."
      require_atomic? false
    end
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end
end
