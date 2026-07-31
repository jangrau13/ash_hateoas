defmodule AshHateoas.Test.Recipe do
  @moduledoc """
  An aggregate root: the thing a client authors, validates and saves as one
  document. Carrying `AshHateoas.DslRoot` is the whole configuration —
  `AshHateoas.DslRoot.Transformers.DeriveRootActions` generates `:validate`
  and `:save` from it.

  Paired with `AshHateoas.Test.Step` and `AshHateoas.Test.Ingredient`, which
  are its parts: each belongs to a Recipe and neither is a root.
  """

  use Ash.Resource,
    domain: AshHateoas.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshHateoas.Resource, AshHateoas.DslRoot]

  ets do
    private?(true)
  end

  hateoas do
    type("recipe")
    base("/recipes")

    # An operation that *executes* the aggregate rather than reading or writing
    # it. schema.org has no term for this: `ControlAction` and `ActivateAction`
    # are device control, and `AchieveAction`'s subtypes are Win/Lose/Tie. So
    # the role is named in this package's own vocabulary, and a client matches
    # the declared type rather than the string "cook".
    #
    # Nothing here is special-cased: `semantic_action` already passes an
    # absolute IRI through verbatim, which is what makes a vocabulary the
    # package does not own — or one a customer owns — expressible.
    semantic_action(:cook, "https://ash-hateoas.org/vocab#RunAction")

    # A generic action declares no HTTP semantics, so this says what the verb is
    # rather than leaving it inferred.
    method(:cook, :post)
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

    # The domain's own execute action — the counterpart of `run` on a simulation
    # model. Its role is declared above; without that it is one POST among
    # several, indistinguishable from `create`.
    action :cook, :map do
      description("Cook the recipe.")
      run(fn _input, _context -> {:ok, %{cooked: true}} end)
    end
  end

  policies do
    policy always() do
      authorize_if(always())
    end
  end
end
