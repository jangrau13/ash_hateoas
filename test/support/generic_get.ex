defmodule AshHateoas.Test.GenericGet do
  @moduledoc """
  A generic action whose author declared it a read.

  POST is what the deriver assumes for a generic action, because nothing in the
  action says whether it mutates and POST understates nothing. `:peek` only
  reads, so the assumption is wrong for it — advertising it as unsafe and
  uncacheable — and `method :peek, :get` is how that is corrected.

  Declaring the method also silences the verifier's warning, which is the point:
  the warning marks an assumption, and this is a human having made the choice.
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
    method :peek, :get
  end

  attributes do
    uuid_primary_key :id
    attribute :label, :string, public?: true
  end

  actions do
    defaults [:read, create: [:label]]

    action :peek, :boolean do
      description "Reads something and returns a scalar. Safe, so GET."
      run fn _input, _ctx -> {:ok, true} end
    end
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end
end
