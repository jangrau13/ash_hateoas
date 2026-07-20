defmodule AshHateoas.Test.Derived do
  @moduledoc """
  A resource used by the R1 conformance tests.

  It exists to separate two sets that are easy to conflate:

    * every action the resource declares
    * the subset that is actually ROUTED

  `:unrouted_touch` is a perfectly ordinary, authorized update action that is
  simply never given a JSON:API route. R1 says the candidate set comes from the
  declared routes, so it must NOT be advertised even though the actor may run
  it. `:touch` is the same action shape but routed, as the control.

  It carries NO `hateoas` block at all — R1's "zero per-resource config".
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
      get :read, primary?: true
      index :read
      post :create
      patch :touch, route: "/:id/touch"
      # NOTE: :unrouted_touch and :admin_only are deliberately NOT routed here.
    end
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
