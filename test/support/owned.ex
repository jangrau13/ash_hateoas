defmodule AshHateoas.Test.Ledger do
  @moduledoc """
  An owner: a resource other records are addressed *through*.

  Paired with `AshHateoas.Test.Entry`, which declares `owned_by :ledger` and so
  nests its URLs under this one's. Nothing here says it is an owner — being
  owned is the child's declaration, since it is the child whose addressability
  depends on it.
  """

  use Ash.Resource,
    domain: AshHateoas.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshHateoas.Resource]

  ets do
    private?(true)
  end

  hateoas do
    type("ledger")
    warn_on_missing_authorizers?(false)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true, allow_nil?: false)
  end

  relationships do
    has_many(:entries, AshHateoas.Test.Entry, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: [:name], update: [:name]])
    default_accept([:name])
  end
end

defmodule AshHateoas.Test.Entry do
  @moduledoc """
  An owned resource: it has no independent existence, so its URL says so.

      /domain/ledger/<ledger-id>/entry/<entry-id>

  rather than a flat `/domain/entry/<entry-id>`.

  `owned_by :ledger` names the **relationship**, not the resource. The
  destination is read from the relationship itself, so the declaration cannot
  disagree with the data model, and `ash_hateoas` learns what owns what without
  learning what a ledger *is*.

  Two properties this fixture exists to pin, neither of which any other fixture
  covers:

    * an entry id under the **wrong** ledger is a 404 — nesting is a constraint,
      not decoration
    * there is **no** `/domain/entry` collection — a flat list of every entry
      across every ledger is not a resource this domain has
  """

  use Ash.Resource,
    domain: AshHateoas.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshHateoas.Resource]

  ets do
    private?(true)
  end

  hateoas do
    type("entry")
    owned_by(:ledger)
    warn_on_missing_authorizers?(false)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:memo, :string, public?: true, allow_nil?: false)
  end

  relationships do
    belongs_to :ledger, AshHateoas.Test.Ledger do
      public?(true)
      allow_nil?(false)
      attribute_writable?(true)
    end
  end

  actions do
    defaults([:read, :destroy, create: [:memo, :ledger_id], update: [:memo]])
    default_accept([:memo, :ledger_id])
  end
end
