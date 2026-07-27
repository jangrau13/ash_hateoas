defmodule AshHateoas.Test.NoJsonApi do
  @moduledoc """
  Carries `AshHateoas.Resource` with no `hateoas` block and no declared type or
  base — the fully-defaulted case.

  Route derivation must run cleanly here: the type is inferred from the module
  name and the base from the domain's short name, with nothing declared by hand.
  Adding the extension to a bare resource should never stop the build.
  """

  use Ash.Resource,
    domain: AshHateoas.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshHateoas.Resource]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :label, :string, public?: true
  end

  actions do
    defaults [:read, create: [:label]]
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end
end
