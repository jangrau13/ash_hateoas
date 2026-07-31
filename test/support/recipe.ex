defmodule AshHateoas.Test.Recipe do
  @moduledoc """
  An aggregate root: the thing a client authors, validates and saves as one
  document. Declaring `aggregate_root?` is the whole configuration —
  `AshHateoas.Document.Transformers.DeriveRootActions` generates `:validate`
  and `:save` from it.

  Paired with `AshHateoas.Test.Step` and `AshHateoas.Test.Ingredient`, which
  are its parts: each belongs to a Recipe and neither is a root.
  """

  use Ash.Resource,
    domain: AshHateoas.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshHateoas.Resource, AshHateoas.Document]

  ets do
    private?(true)
  end

  hateoas do
    type("recipe")
    base("/recipes")
  end

  document do
    aggregate_root?(true)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true, allow_nil?: false)
  end

  relationships do
    has_many :steps, AshHateoas.Test.Step do
      public?(true)
    end

    has_many :ingredients, AshHateoas.Test.Ingredient do
      public?(true)
    end

    # A shared element: a technique is reachable from several recipes, so
    # removing it from one document must not delete the record.
    many_to_many :techniques, AshHateoas.Test.Technique do
      public?(true)
      through(AshHateoas.Test.RecipeTechnique)
      source_attribute_on_join_resource(:recipe_id)
      destination_attribute_on_join_resource(:technique_id)
    end
  end

  actions do
    defaults([:read, create: [:title], update: [:title]])
  end

  policies do
    policy always() do
      authorize_if(always())
    end
  end
end
