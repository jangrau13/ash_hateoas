defmodule AshHateoas.Test.Quiet do
  @moduledoc """
  A resource that opts out of affordances entirely (R8).

  Routed and readable like any other, it simply never advertises what may be
  done next — the "turn a hot endpoint off without forking" case.
  """

  use Ash.Resource,
    domain: AshHateoas.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshJsonApi.Resource, AshHateoas.Resource]

  ets do
    private? true
  end

  json_api do
    type "quiet"

    routes do
      base "/quiets"
      get :read, primary?: true
      index :read
      post :create
    end
  end

  hateoas do
    enabled? false
    warn_on_missing_authorizers?(false)
  end

  attributes do
    uuid_primary_key :id
    attribute :label, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: [:label]]
  end
end
