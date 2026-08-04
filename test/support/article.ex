defmodule AshHateoas.Test.Article do
  @moduledoc """
  Exercises the `hateoas` DSL: an exclusion and an override on a resource that
  carries the extension.
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
    type "article"
    base "/articles"
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

    # Three narrowings of one destination, covering each branch of the rule the
    # ontology applies when deciding what a to-many's members are.
    #
    # Pinned to a literal naming a declared class, so this collection asserts
    # `#Review` where `comments` above can only assert `#Comment`.
    has_many :reviews, AshHateoas.Test.Comment do
      public? true
      destination_attribute :article_id
      filter expr(kind == :review)
    end

    # Pinned, but `reply` names no declared class — so this falls back to
    # `#Comment`. Weaker than it could be and still true, which is the point:
    # a literal nothing declares must not become an IRI nothing defines.
    has_many :replies, AshHateoas.Test.Comment do
      public? true
      destination_attribute :article_id
      filter expr(kind == :reply)
    end

    # Filtered but not *pinned*. A comparison leaves members no single class
    # covers, so it falls back too — the branch that would break if the filter
    # reader were widened to "any filter mentioning an attribute".
    has_many :top_comments, AshHateoas.Test.Comment do
      public? true
      destination_attribute :article_id
      filter expr(score > 5)
    end
  end

  actions do
    defaults [:read, create: [:title], update: [:title]]

    # A to-many is stated on the node only when the action loads it — there is
    # no per-relationship collection URL to reference, and an empty collection
    # would assert the article has no comments. So "the article with its
    # comments" is a read a caller chooses, and the default stays lean.
    read :with_comments do
      prepare build(load: [:comments])
    end

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
