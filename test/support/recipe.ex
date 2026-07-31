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

defmodule AshHateoas.Test.Ingredient do
  @moduledoc """
  A part of a `AshHateoas.Test.Recipe` aggregate, carrying the two shapes that
  matter to document validation: a constrained enum (`unit`) and a required
  name.
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
    type("ingredient")
    base("/ingredients")
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true, allow_nil?: false)

    attribute(:unit, :atom,
      public?: true,
      constraints: [one_of: [:g, :ml, :piece]]
    )

    attribute(:quantity, :integer, public?: true)
  end

  identities do
    # Name is the key an author writes, which is what lets the DSL keep the
    # uuid out of the text: a save matches on this rather than on an id the
    # author would have to carry.
    identity(:unique_name, [:name])
  end

  relationships do
    belongs_to :recipe, AshHateoas.Test.Recipe do
      public?(true)
      allow_nil?(false)
      attribute_writable?(true)
    end
  end

  actions do
    defaults([
      :read,
      :destroy,
      create: [:name, :unit, :quantity, :recipe_id],
      update: [:name, :unit, :quantity]
    ])
  end

  policies do
    policy always() do
      authorize_if(always())
    end
  end
end

defmodule AshHateoas.Test.Step do
  @moduledoc """
  A part of a `AshHateoas.Test.Recipe` aggregate. Its `uses` attribute names an
  ingredient by name rather than by id, which is what a cross-element rule has
  to check: the reference is only resolvable with the whole document in hand.
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
    type("step")
    base("/steps")
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true, allow_nil?: false)
    attribute(:body, :string, public?: true)
  end

  identities do
    identity(:unique_name, [:name])
  end

  relationships do
    belongs_to :recipe, AshHateoas.Test.Recipe do
      public?(true)
      allow_nil?(false)
      attribute_writable?(true)
    end
  end

  actions do
    defaults([:read, :destroy, create: [:name, :body, :recipe_id], update: [:name, :body]])
  end

  policies do
    policy always() do
      authorize_if(always())
    end
  end
end

defmodule AshHateoas.Test.Technique do
  @moduledoc """
  An element shared across aggregates. `Recipe many_to_many :techniques` states
  that a technique belongs to no single recipe, so removing it from one
  recipe's document unlinks it rather than destroying it — the record is still
  referenced elsewhere.
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
    type("technique")
    base("/techniques")
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true, allow_nil?: false)
  end

  identities do
    identity(:unique_name, [:name])
  end

  relationships do
    many_to_many :recipes, AshHateoas.Test.Recipe do
      public?(true)
      through(AshHateoas.Test.RecipeTechnique)
      source_attribute_on_join_resource(:technique_id)
      destination_attribute_on_join_resource(:recipe_id)
    end
  end

  actions do
    defaults([:read, :destroy, create: [:name], update: [:name]])
  end

  policies do
    policy always() do
      authorize_if(always())
    end
  end
end

defmodule AshHateoas.Test.RecipeTechnique do
  @moduledoc "Join resource for `Recipe many_to_many :techniques`."

  use Ash.Resource,
    domain: AshHateoas.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer]

  ets do
    private?(true)
  end

  attributes do
    uuid_primary_key(:id)
  end

  relationships do
    belongs_to :recipe, AshHateoas.Test.Recipe do
      public?(true)
      allow_nil?(false)
      attribute_writable?(true)
    end

    belongs_to :technique, AshHateoas.Test.Technique do
      public?(true)
      allow_nil?(false)
      attribute_writable?(true)
    end
  end

  actions do
    # `manage_relationship` on a many_to_many updates the join row as well as
    # the target, so the join needs an update action even though nothing about
    # it is author-editable.
    defaults([:read, :destroy, create: [:recipe_id, :technique_id], update: []])
  end

  policies do
    policy always() do
      authorize_if(always())
    end
  end
end
