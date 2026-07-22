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
      # The primaries are derived. Only the two custom paths are declared —
      # `/reconcile` is not what `:internal_reconcile` would derive to, so it
      # has to be said.
      patch :internal_reconcile, route: "/:id/reconcile"
      patch :publish, route: "/:id/publish"
    end
  end

  hateoas do
    # Routed for internal callers, but never advertised.
    exclude :internal_reconcile
    override :publish, href: "/custom/publish/:id"
  end

  agentic_hateoas do
    # Advertised to every actor, executed only by a committing credential.
    not_delegable(:publish)
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true, allow_nil?: false
  end

  # A to-many relationship on a resource that carries the extension: this is
  # what the route derivation acts on.
  relationships do
    has_many :comments, AshHateoas.Test.Comment do
      public? true
      destination_attribute :article_id
    end
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
