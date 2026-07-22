defmodule AshHateoas.Test.MultiRead do
  @moduledoc """
  A resource with more than one read action.

  Exists because the number of `index` routes is load-bearing and was once
  wrong. `AshHateoas.Navigation.root/2` finds a type's collection URL by
  looking up its `index` route; derive a second one and the lookup can return a
  member-scoped path, dropping the type out of the root document. A client that
  enters at the root and follows links then cannot reach it at all (R9).

  So: the primary read owns `index`, and every other read is a member route
  under `/:id/<name>`. `:by_label` is the non-primary control.
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
    type "multi_read"
  end

  attributes do
    uuid_primary_key :id
    attribute :label, :string, public?: true
  end

  actions do
    defaults [:read, create: [:label]]

    read :by_label do
      argument :label, :string, allow_nil?: false
      filter expr(label == ^arg(:label))
    end
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end
end
