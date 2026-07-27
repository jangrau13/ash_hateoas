defmodule AshHateoas.Test.Comment do
  @moduledoc """
  A resource on the far side of a relationship, so R9's data-graph navigation
  has something to walk to.

  `Document` has_many :comments; this belongs_to it. Without a pair like this
  nothing in the suite exercises relationship links at all, and a claim that
  `ash_json_api` emits them stays unverified.
  """

  use Ash.Resource,
    domain: AshHateoas.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshHateoas.Resource]

  # `belongs_to :document` is the to-one case, deliberately left underived —
  # see the transformer's moduledoc for the upstream bug it avoids.

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
    attribute(:article_id, :uuid, public?: true)
  end

  relationships do
    belongs_to :document, AshHateoas.Test.Document do
      public?(true)
      allow_nil?(false)
      attribute_writable?(true)
    end
  end

  actions do
    defaults([:read, create: [:body, :document_id, :article_id]])
  end

  policies do
    policy always() do
      authorize_if(always())
    end
  end
end
