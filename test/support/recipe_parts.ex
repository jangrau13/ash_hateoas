defmodule AshHateoas.Test.RecordsContext do
  @moduledoc """
  A change that reports what `AshHateoas.DslRoot.document_context/1` prepared.

  Stands in for the real thing — a change that would otherwise query per element
  — because what has to be tested is that the context *arrives*, not what a
  domain puts in it. Sending it to the test process is the smallest way to
  observe that, and it also counts: a hook computed per element rather than per
  document shows up as one message per element.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case changeset.context do
      %{test_pid: pid} when is_pid(pid) ->
        send(pid, {:document_context, Map.get(changeset.context, :prepared)})
        changeset

      _ ->
        changeset
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
      update: [:name, :unit, :quantity]
    ])

    create :create do
      primary?(true)
      accept([:name, :unit, :quantity, :recipe_id])

      # Reports the document context it was cast with — see `RecordsContext`.
      # A change is the only vantage point from which that is observable, since
      # it is the thing the context exists for.
      change(AshHateoas.Test.RecordsContext)
    end
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

defmodule AshHateoas.Test.MixingBowl do
  @moduledoc """
  An element whose `type` is **two words**, which is the only thing it is for.

  Every other element of the `Recipe` document is one lower-case word, so
  `Macro.camelize` round-trips by luck: `step` → `Step` → `step`. An underscore
  does not survive that trip — `mixing_bowl` → `MixingBowl` → `mixingbowl` — and
  camelizing is not injective, so no inverse recovers it.

  A client deriving the document's `kind` from the class IRI therefore sends a
  token this server has never heard of. Measured on a live API whose types all
  carry a prefix: **every** element of a 214-element save rejected as an unknown
  kind. Nothing here caught it, because until this fixture no multi-word type
  was ever an authorable element of a document.

  What the wire states instead, and what a client must read, is `hydra:title` on
  the class — the raw type, undamaged. `AshHateoas.Test.RecipeAudit` also
  carries an underscore and cannot stand in for this: its relationship is
  `public?: false` precisely so it is *excluded* from a document.

  An owned `has_many` rather than a `many_to_many`, deliberately: `on_missing/2`
  answers `:destroy` for an owned one, so this proves the underscore on the path
  where a mismatched kind would risk data rather than merely a rejected save.
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
    type("mixing_bowl")
    base("/mixing_bowls")
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true, allow_nil?: false)
    attribute(:litres, :integer, public?: true)
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
    defaults([:read, :destroy, create: [:name, :litres, :recipe_id], update: [:name, :litres]])
  end

  policies do
    policy always() do
      authorize_if(always())
    end
  end
end
