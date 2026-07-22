defmodule AshHateoas.Test.NoBase do
  @moduledoc """
  A resource with no `routes` block at all — the zero-config case.

  Everything is derived: the base from the domain's `short_name` and the
  json_api `type`, the routes from the actions. This is what the extension is
  for, and this fixture is the proof it holds end to end.

  The derived base is `/test/no_base` — singular. Deliberately: ash#31 removed
  name-guessing across the framework (ash_postgres stopped guessing table names,
  ash_json_api stopped guessing base routes) precisely because pluralisation is
  unreliable. An author wanting `/test/no_bases` declares `base`.
  """

  use Ash.Resource,
    domain: AshHateoas.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource, AshHateoas.Resource]

  ets do
    private? true
  end

  json_api do
    type "no_base"
  end

  attributes do
    uuid_primary_key :id
    attribute :label, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: [:label], update: [:label]]
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end
end
