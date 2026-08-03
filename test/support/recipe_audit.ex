defmodule AshHateoas.Test.RecipeAudit do
  @moduledoc """
  A part of `Recipe` that nobody authors.

  Exists to hold the *non-public* case, which nothing else in the suite covered:
  every other to-many on a root here is explicitly `public?(true)`, so a
  relationship left at Ash's default (`public?: false`) was never exercised —
  and `managed_relationships/1` did not filter on it.

  The consequence was concrete. `element_classes/1` reads the same function, so
  this class was named in `sh:class` on the `document` argument — advertised as
  an element an author may write — while the relationship itself appeared
  nowhere in the documentation, because that path *does* filter `public?`. And
  since `on_missing/2` returns `:destroy` for an owned `has_many`, a document
  that simply omitted these rows deleted them.

  An audit trail is the honest shape for it: written by the system, read by
  nobody through the document, and not something a client should be able to
  remove by leaving it out.
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
    type("recipe_audit")
    base("/recipe-audits")
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:note, :string, public?: true, allow_nil?: false)
  end

  relationships do
    belongs_to :recipe, AshHateoas.Test.Recipe do
      public?(true)
      allow_nil?(false)
      attribute_writable?(true)
    end
  end

  actions do
    defaults([:read, create: [:note, :recipe_id]])
  end

  policies do
    policy always() do
      authorize_if(always())
    end
  end
end
