defmodule AshHateoas.Test.Derived do
  @moduledoc """
  A resource used by the R1 conformance tests.

  It exists to separate two sets that are easy to conflate:

    * every action the resource declares
    * the subset that is actually ROUTED

  `:unrouted_touch` is a perfectly ordinary, authorized update action that is
  declared `unrouted`, so it never reaches the HTTP surface. R1 says the
  candidate set comes from the routes, so it must NOT be advertised even though
  the actor may run it. `:touch` is the same action shape, left routed, as the
  control.

  The `hateoas` block was once absent here — under the old allow-list default,
  saying nothing was enough to keep an action off the surface. Now that every
  action is routed by default, keeping one off is a declaration, and this is
  what that declaration looks like.
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
    type "derived"

    routes do
      base "/deriveds"
      # Every route here is derived. :unrouted_touch and :admin_only are kept
      # off the surface by the `hateoas` block below, not by omission.
    end
  end

  hateoas do
    unrouted :unrouted_touch
    unrouted :admin_only
  end

  attributes do
    uuid_primary_key :id
    attribute :label, :string, public?: true
  end

  actions do
    defaults [:read, create: [:label]]

    update :touch do
      description "Touch this record."
      require_atomic? false
    end

    update :unrouted_touch do
      description "Identical to :touch, but never routed."
      require_atomic? false
    end

    update :admin_only do
      description "Routed nowhere and admin-gated."
      require_atomic? false
    end
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end
end
