defmodule AshHateoas.Test.NoJsonApi do
  @moduledoc """
  Carries `AshHateoas.Resource` without `AshJsonApi.Resource`.

  There is no `[:json_api, :routes]` path to write into, so the route
  transformer has nothing to do. It must no-op rather than raise: adding
  AshHateoas to a resource that is not part of the HTTP surface should not stop
  the build.
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
