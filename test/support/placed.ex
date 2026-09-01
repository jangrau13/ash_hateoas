defmodule AshHateoas.Test.Placed do
  @moduledoc """
  A resource with a `:map` attribute, which is the one shape this package cannot
  declare terms for.

  The value's inner keys are the application's own data. `AshHateoas.Hydra.Context`
  builds a term for the *attribute* (`location`), and nothing can build one for
  what is inside it — so a bare inner key expands to nothing and is dropped in
  silence.

  This fixture is the correct usage: every inner key is **prefixed**, so the
  `@context`'s own prefix bindings resolve it. `no_dropped_keys_test.exs` covers
  it, and would fail if `address` here were written bare — which is exactly the
  failure an application hits with no warning of its own.
  """

  use Ash.Resource,
    domain: AshHateoas.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshHateoas.Resource]

  ets do
    private? true
  end

  hateoas do
    type "placed"
    base "/placed"
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true)
    attribute(:location, :map, public?: true)
    attribute(:stops, {:array, :map}, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: [:label, :location, :stops], update: [:label]])
  end

  policies do
    policy always() do
      authorize_if(always())
    end
  end
end
