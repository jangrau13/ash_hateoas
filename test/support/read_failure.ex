defmodule AshHateoas.Test.ReadFailure do
  @moduledoc """
  A resource whose named collection reads each fail in a DIFFERENT way, to prove
  the Hydra plug classifies a read failure honestly instead of collapsing every
  one to `403 Forbidden`:

    * `denied` — a policy refuses it → `403`
    * `invalid` — its prepare adds a field error → `400`
    * `boom` — its prepare raises → `500`

  The primary `:read` stays open, so the base collection still works.
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
    type "read_failure"
  end

  attributes do
    uuid_primary_key :id
    attribute :label, :string, public?: true
  end

  actions do
    defaults [:read, create: [:label]]

    # A read a policy denies — the genuine 403 case.
    read :denied do
      argument :label, :string, public?: true, allow_nil?: true
    end

    # A read that fails validation inside its preparation — invalid input /
    # unavailable, a 400. (This is the shape svc_lca's `semantic_search` takes when
    # its embedding backend is unreachable: the prepare adds a `:query` error.)
    read :invalid do
      argument :label, :string, public?: true, allow_nil?: true

      prepare fn query, _context ->
        Ash.Query.add_error(query, field: :label, message: "search is unavailable")
      end
    end

    # A read whose preparation RAISES — the server's problem, a 500. (A dependency
    # the action needs is down and the action does not catch it.)
    read :boom do
      argument :label, :string, public?: true, allow_nil?: true

      prepare fn _query, _context ->
        raise "backend unreachable"
      end
    end
  end

  policies do
    # Only `:denied` is refused; every other read is open, so the base index and
    # the other named reads reach their own failure modes rather than a policy.
    policy action(:denied) do
      forbid_if always()
    end

    policy action_type(:read) do
      authorize_if always()
    end
  end
end
