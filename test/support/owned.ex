defmodule AshHateoas.Test.Ledger do
  @moduledoc """
  The one side of a required `belongs_to`.

  Paired with `AshHateoas.Test.Entry`, whose `ledger` is `allow_nil?: false` —
  an entry means nothing without one. That dependence is stated by the
  relationship and by nothing else: both resources are addressed flatly, and the
  edge between them travels as a link in both directions (`ledger` on the entry,
  `entries` here).
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

    # A to-many is stated on the node only when the action loads it — there is
    # no per-relationship collection URL to reference otherwise, and an empty
    # collection would assert this ledger has no entries. So "the whole ledger"
    # is a read a caller chooses, and the lean default stays lean.
    read :with_entries do
      prepare(build(load: [:entries]))
    end
  end
end

defmodule AshHateoas.Test.Entry do
  @moduledoc """
  A record that depends on another and is addressed as though it did not.

      /domain/entry/<entry-id>

  The `ledger` is required — an entry has no independent existence — and the URL
  says nothing about it. That separation is the property this fixture pins:
  **a resource is connected to another by a link, and by nothing else.**

  It used to nest, under `/domain/ledger/<ledger-id>/entry/<entry-id>`, and the
  two spellings disagreed about identity. A link says a record *is* a URL, since
  `LinkInput` resolves an IRI against the same routes that serve a GET. Nesting
  said a record is a URL *plus the path you came by* — the same entry under
  another ledger segment being a 404 rather than the same record. A triple names
  its subject by IRI, so containment carried in the address is structure no
  reasoner ever sees, and the graph loses the edge the domain most cares about.

  Three properties this fixture exists to pin, none of which any other covers:

    * the member is flat, and it is the **only** address
    * `/domain/entry` exists — `Ash.read(Entry)` was always a legitimate query,
      and the collection is its representation
    * a write names the ledger by IRI rather than inheriting it from the path
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
