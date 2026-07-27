defmodule AshHateoas.Test.EagerPrepare do
  @moduledoc """
  A resource whose search read has a required argument AND a preparation that
  dereferences it eagerly.

  This is the shape that used to vanish from the advertised surface. The
  affordance probe calls `Ash.can?({resource, action}, actor)` with no
  arguments; Ash runs the action's preparations while building the query; the
  preparation meets `nil` and raises; `AshHateoas.Gate.Authorization` caught the
  raise and dropped the affordance. So an action that is perfectly authorizable
  — `authorize_if always()` — was never advertised, and an MCP agent never saw
  it as a tool.

  `:search` reproduces the crash (`"query: " <> nil`). `:plain_read` is the
  control: no argument, no preparation, always advertised. `:forbidden_search`
  has the same crashing preparation but `forbid_if always()`, so it must stay
  hidden — proving the recovery path does not advertise a genuinely forbidden
  action.
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
    type "eager_prepare"
  end

  attributes do
    uuid_primary_key :id
    attribute :label, :string, public?: true
  end

  actions do
    defaults [:read, create: [:label]]

    # Required argument + a preparation that uses it — crashes the empty probe.
    read :search do
      argument :query, :string, allow_nil?: false

      prepare fn query, _context ->
        # `<>` on a nil raises: exactly the failure the recovery path handles.
        _ = "query: " <> Ash.Query.get_argument(query, :query)
        query
      end
    end

    # Same crashing preparation, but forbidden regardless of argument. Must NOT
    # be advertised — the recovery must not turn a real denial into an offer.
    read :forbidden_search do
      argument :query, :string, allow_nil?: false

      prepare fn query, _context ->
        _ = "query: " <> Ash.Query.get_argument(query, :query)
        query
      end
    end
  end

  policies do
    policy action(:forbidden_search) do
      forbid_if always()
    end

    policy always() do
      authorize_if always()
    end
  end
end
