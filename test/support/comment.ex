defmodule AshHateoas.Test.Comment do
  @moduledoc """
  A resource on the far side of a relationship, so the data-graph navigation
  has something to walk to.

  `Document` has_many :comments; this belongs_to it. Without a pair like this
  nothing in the suite exercises relationship links at all, and the claim that
  they are derived and rendered stays unverified.
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
    type "comment"
    base "/comments"
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:body, :string, public?: true, allow_nil?: false)

    # A discriminator, so `Article` can narrow one `has_many` several ways.
    # Only `:review` has a class of its own (`AshHateoas.Test.Review`), which
    # is what lets one fixture cover both branches of the member-class rule: a
    # narrowing whose literal names a declared class, and one whose does not.
    attribute(:kind, :atom,
      public?: true,
      constraints: [one_of: [:review, :reply, :note]]
    )

    attribute(:score, :integer, public?: true)
  end

  # The to-one cases: a required `belongs_to` (document) and an optional one
  # (article), both surfaced on the record as node references built from the
  # local foreign key.
  relationships do
    belongs_to :document, AshHateoas.Test.Document do
      public?(true)
      allow_nil?(false)
      attribute_writable?(true)
    end

    belongs_to :article, AshHateoas.Test.Article do
      public?(true)
      allow_nil?(true)
      attribute_writable?(true)
    end

    # A target carrying a declared identity, so a client may name it by its
    # natural key rather than by URL.
    belongs_to :author, AshHateoas.Test.Person do
      public?(true)
      allow_nil?(true)
      attribute_writable?(true)
    end
  end

  actions do
    defaults([
      :read,
      create: [:body, :kind, :score, :document_id, :article_id, :author_id],
      update: [:body, :kind, :score, :document_id, :article_id, :author_id]
    ])

    # A read that loads its to-one link. The link is then stated in place —
    # the target's own node, carrying its own `@id` — rather than referenced.
    # This is the only lever: expansion follows what the action loads.
    read :with_document do
      prepare(build(load: [:document]))
    end
  end

  policies do
    policy always() do
      authorize_if(always())
    end
  end
end
