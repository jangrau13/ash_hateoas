defmodule AshHateoas.Test.MultiRead do
  @moduledoc """
  A resource with more than one read action.

  Exists because how a non-primary read is routed depends on what it RETURNS,
  and that distinction is load-bearing for `AshHateoas.Navigation.root/2`, which
  finds a type's collection URL by looking up its `index` route.

  A read splits by `get?`:

    * `get?: false` returns a collection, so it derives an `:index` at
      `/<name>` — a real sub-collection with its own affordance. `:by_label`
      (a filtered list) is the control for this.
    * `get?: true` returns a single record, so it stays a member route at
      `/:id/<name>` as a `:get`. `:by_id` is the control for this.

  With several indexes now expected, the canonical collection is the primary
  read's, at the base path; `Navigation` prefers it over the named ones so the
  type still resolves from the root document (R9).
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

    # A non-primary read that returns MANY — the collection-read branch. Derives
    # an `:index` at `/by_label`.
    read :by_label do
      argument :label, :string, allow_nil?: false
      filter expr(label == ^arg(:label))
    end

    # A non-primary read that returns ONE — the member-read branch. `get?: true`
    # is Ash's own marker for "innately a single result", and keeps this at
    # `/:id/by_id` as a `:get`.
    read :by_id do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id))
    end
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end
end
