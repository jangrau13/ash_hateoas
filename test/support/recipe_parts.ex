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

    # A second attribute, so a shared element has something *editable*. With
    # `name` alone there was nothing to change that was not the identity — a
    # changed name is a different element — so no test could tell whether a
    # document's edits reached the record. They did not, and the save reported
    # success anyway.
    attribute(:summary, :string, public?: true)
  end

  identities do
    identity(:unique_name, [:name])
  end

  # No inverse `many_to_many :recipes` here. It would make Technique and Recipe
  # mutually dependent at compile time, and relationship-route derivation reads
  # each destination's type — which deadlocks. The link is navigable from the
  # aggregate, which is the direction a document is authored in.

  actions do
    defaults([:read, :destroy, create: [:name, :summary], update: [:name, :summary]])
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
