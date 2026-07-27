defmodule AshHateoas.Test.Secret do
  @moduledoc """
  A resource whose READ policy is a filter, not a blanket allow.

  Read policies produce filters rather than yes/no answers, so a bare
  `Ash.can?({record, :read}, actor)` answers "may you run this query?" — usually
  `true`, returning nothing — rather than "may you see this record?". This
  resource exists to prove the authorization gate passes `data:` and therefore
  asks the question it means.
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
    type "secret"
    base "/secrets"
  end

  attributes do
    uuid_primary_key :id
    attribute :body, :string, public?: true
    attribute :owner_id, :string, public?: true
  end

  actions do
    defaults [:read, create: [:body, :owner_id]]
  end

  policies do
    # A filter policy: the query succeeds for anyone, but only returns rows the
    # actor owns. `can?` without `data:` therefore says "yes" to everyone.
    policy action_type(:read) do
      authorize_if expr(owner_id == ^actor(:id))
    end

    policy action_type(:create) do
      authorize_if always()
    end
  end
end
