defmodule AshHateoas.Test.AdminOnly do
  @moduledoc """
  A resource only an admin may read.

  R9 requires structural navigation to be filtered per actor — "an unreachable
  branch is omitted, not rendered-and-rejected". Every other test resource has a
  permissive read, so without this one the root entry document is identical for
  every identified actor and the filtering claim is untested.
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
    type "admin_only"
    base "/admin_onlys"
  end

  attributes do
    uuid_primary_key :id
    attribute :secret_note, :string, public?: true
  end

  actions do
    defaults [:read, create: [:secret_note]]
  end

  policies do
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action_type(:create) do
      authorize_if always()
    end
  end
end
