defmodule AshHateoas.Test.Person do
  @moduledoc """
  A resource mapped to well-known vocabulary: a `schema.org/Person` semantic
  type, and its `additional_name` attribute mapped to `schema.org/additionalName`.
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
    type "person"
    base "/people"
    # A bare token resolves against schema.org.
    semantic_type "Person"
    semantic_property :additional_name, "additionalName"
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true, allow_nil?: false)
    attribute(:additional_name, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: [:name, :additional_name]])
  end

  policies do
    policy always() do
      authorize_if(always())
    end
  end
end
