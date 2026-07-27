defmodule AshHateoas.Test.AutoRouted do
  @moduledoc """
  A resource that declares no routes at all, so every route it has is derived.

  The `routes` block carries only `base` — there is no path convention to
  derive that from, and inventing one (`"comment"` -> `/comments`) would be
  making up a declaration rather than reading one. Everything below `base` is
  the transformer's output.

  Deliberately covers all four primaries plus two non-primaries, since the
  derivation rule differs between them: primaries get REST verbs, non-primaries
  get their own name under `/:id/`.
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
    type "auto_routed"
    base "/auto_routeds"
    # Confirms the assumed verb rather than changing it. Declaring it is what
    # silences the warning: the point is that a human chose POST, not that the
    # deriver guessed it. The warning itself is exercised on its own fixture.
    method :tally, :post
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: [:title], update: [:title]]

    update :publish do
      description "Publish this record."
      require_atomic? false
    end

    # A generic action returning a scalar. Routed like everything else, through
    # `ash_json_api`'s `:route` entity — which, unlike the verb entities, applies
    # no return-type check. Only the method needs declaring.
    action :tally, :boolean do
      description "A generic action returning a scalar."
      run fn _input, _ctx -> {:ok, true} end
    end
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end
end
