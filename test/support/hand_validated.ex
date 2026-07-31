defmodule AshHateoas.Test.HandValidated do
  @moduledoc """
  An aggregate root that writes its own `:validate`.

  `Ash.Resource.Builder.add_new_action/4` is a no-op when an action of that name
  already exists, so the hand-written one is used as-is and `:save` is still
  generated. That is what makes `aggregate_root?` a default rather than a
  commitment: an author overrides the half they care about without giving up
  the other.
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
    type("hand_validated")
    base("/hand_validated")
  end

  document do
    aggregate_root?(true)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true)
  end

  actions do
    defaults([:read, create: [:title]])

    action :validate, :map do
      description "Hand-written, and not replaced."
      argument(:document, {:array, :map}, allow_nil?: false)

      run(fn _input, _context -> {:ok, %{"valid?" => true, "errors" => []}} end)
    end
  end

  policies do
    policy always() do
      authorize_if(always())
    end
  end
end
