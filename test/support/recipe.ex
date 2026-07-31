defmodule AshHateoas.Test.Recipe do
  @moduledoc """
  An aggregate root: the thing a client authors, validates and saves as one
  document. Declaring `aggregate_root?` is the whole configuration —
  `AshHateoas.Resource.Transformers.DeriveRootActions` generates `:validate`
  and `:save` from it.

  Paired with `AshHateoas.Test.Step` and `AshHateoas.Test.Ingredient`, which
  are its parts: each belongs to a Recipe and neither is a root.
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
    type("recipe")
    base("/recipes")
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

  relationships do
    belongs_to :recipe, AshHateoas.Test.Recipe do
      public?(true)
      allow_nil?(false)
      attribute_writable?(true)
    end
  end

  actions do
    defaults([:read, create: [:name, :unit, :quantity, :recipe_id]])
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

  relationships do
    belongs_to :recipe, AshHateoas.Test.Recipe do
      public?(true)
      allow_nil?(false)
      attribute_writable?(true)
    end
  end

  actions do
    defaults([:read, create: [:name, :body, :recipe_id]])
  end

  policies do
    policy always() do
      authorize_if(always())
    end
  end
end
