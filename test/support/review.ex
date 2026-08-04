defmodule AshHateoas.Test.Review do
  @moduledoc """
  The class a narrowed relationship names.

  `Article has_many :reviews, Comment, filter: expr(kind == :review)` says every
  member of that collection is a review, and the wire can carry that claim only
  if a class called `review` is declared — which is this.

  Deliberately *not* related to `Comment` in Ash's eyes. The emitter's rule is
  "a filter pins an attribute to a literal, and a class of that name is
  declared"; it never asks how the two resources are related, because Ash has no
  way to say so. That is precisely why the claim must be read off the filter
  rather than off a declared hierarchy — and why the fallback exists for every
  narrowing whose literal names nothing.
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
    type("review")
    base("/reviews")
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:body, :string, public?: true, allow_nil?: false)
  end

  actions do
    defaults([:read, :destroy, create: [:body], update: [:body]])
  end

  policies do
    policy always() do
      authorize_if(always())
    end
  end
end
