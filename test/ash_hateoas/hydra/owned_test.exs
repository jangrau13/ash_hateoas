defmodule AshHateoas.Hydra.OwnedTest do
  @moduledoc """
  A resource is connected to another by a **link**, and by nothing else.

      /domain/entry/<entry-id>

  `Entry.ledger` is required — an entry has no independent existence — and the
  address says nothing about it. That separation is what these tests pin.

  ## Why the URL stopped carrying the owner

  It used to nest, and the two spellings disagreed about identity:

    * **a link says a record *is* a URL.** `LinkInput` resolves an IRI by
      matching its path against the same derived routes that serve a GET, so the
      URLs the API issues are the URLs it accepts. One record, one address.
    * **nesting said a record is a URL *plus the path you came by*.** The same
      entry under another ledger segment was a 404 rather than the same record,
      so its identity was not its IRI alone.

  For a graph that is fatal rather than stylistic. A triple names its subject by
  IRI; if the IRI carries the containment then the containment cannot *be* a
  triple, and the edge the domain most cares about is structure no reasoner ever
  sees. A client holding `{"ledger": {"@id": …}}` and a record id also had no
  way to build the address without knowing the nesting convention out of band —
  which is what Richardson Level 3 forbids.

  ## What these tests assert

    * the member is flat, and it is the **only** address
    * the collection exists — `Ash.read(Entry)` was always a legitimate query,
      and a collection is its representation. What the domain lacks is not the
      *list* but a reason to privilege it
    * the edge is stated as a link, in both directions
    * a write names the ledger by IRI rather than inheriting it from the path

  The wrong-owner-404 tests that stood here have **no successor**: that
  constraint was the URL's, not the domain's. Its real content — an entry
  belongs to one ledger — is enforced by the required `belongs_to` and asserted
  through the link instead.
  """

  use ExUnit.Case, async: false

  import Plug.Test

  alias AshHateoas.Test.{Actor, Entry, HydraEndpoint, Ledger}

  @admin %Actor{id: "admin-1", role: :admin}

  defp request(method, path, payload \\ nil) do
    conn =
      if payload do
        conn(method, path, Jason.encode!(payload))
        |> Plug.Conn.put_req_header("content-type", "application/ld+json")
      else
        conn(method, path)
      end

    conn |> Ash.PlugHelpers.set_actor(@admin) |> HydraEndpoint.call([])
  end

  defp get(path), do: request(:get, path)
  defp body(conn), do: Jason.decode!(conn.resp_body)

  setup do
    ledger =
      Ledger |> Ash.Changeset.for_create(:create, %{name: "Mine"}) |> Ash.create!(authorize?: false)

    other =
      Ledger
      |> Ash.Changeset.for_create(:create, %{name: "Theirs"})
      |> Ash.create!(authorize?: false)

    entry =
      Entry
      |> Ash.Changeset.for_create(:create, %{memo: "M", ledger_id: ledger.id})
      |> Ash.create!(authorize?: false)

    {:ok, ledger: ledger, other: other, entry: entry}
  end

  describe "the address is flat" do
    test "a record resolves at its own URL", %{entry: entry} do
      conn = get("/domain/entry/#{entry.id}")

      assert conn.status == 200
      assert body(conn)["memo"] == "M"
    end

    test "the node's @id is that URL", %{entry: entry} do
      # The identity a triple can name. Under nesting this was the path the
      # client happened to arrive by, which is not a property of the record.
      assert body(get("/domain/entry/#{entry.id}"))["@id"] == "/domain/entry/#{entry.id}"
    end

    test "the nested URL is gone", %{ledger: ledger, entry: entry} do
      # Not merely unadvertised. A second address for one record is two IRIs for
      # one thing, with nothing on the wire saying they are the same.
      assert get("/domain/ledger/#{ledger.id}/entry/#{entry.id}").status == 404
    end

    test "no placeholder survives into any advertised URL", %{entry: entry} do
      # Kept from the nesting era, where it caught all three href builders. It
      # is cheaper than it looks and it guards a whole class: an unsubstituted
      # placeholder is a pattern rather than an address, and it 404s.
      raw = get("/domain/entry/#{entry.id}").resp_body

      refute raw =~ ":ledger_id", "a route placeholder reached the wire"
      refute raw =~ "{ledger_id}", "an unexpanded variable reached a served node"
      refute raw =~ "{id}", "an unexpanded variable reached a served node"
    end
  end

  describe "the collection exists" do
    test "every record is listed, across owners", %{other: other} do
      Entry
      |> Ash.Changeset.for_create(:create, %{memo: "Theirs", ledger_id: other.id})
      |> Ash.create!(authorize?: false)

      memos =
        "/domain/entry"
        |> get()
        |> body()
        |> Map.get("hydra:member")
        |> Enum.map(& &1["memo"])
        |> Enum.sort()

      assert memos == ["M", "Theirs"]
    end

    test "it is a read, not a claim that records float free" do
      # `Ash.read(Entry)` has always been a legitimate query and this is its
      # representation. The old docs argued the collection "stops existing"
      # because a flat list is "not a resource the domain has" — wrong on its
      # own terms: what the domain lacks is a reason to privilege the list.
      assert get("/domain/entry").status == 200
    end
  end

  describe "the edge is a link, in both directions" do
    test "the record carries its ledger as a node reference", %{ledger: ledger, entry: entry} do
      node = body(get("/domain/entry/#{entry.id}"))

      assert node["ledger"]["@id"] == "/domain/ledger/#{ledger.id}"
    end

    test "the link resolves", %{entry: entry} do
      # What makes it a link rather than a decoration: the URL the record states
      # is one the API serves.
      href = body(get("/domain/entry/#{entry.id}"))["ledger"]["@id"]

      assert get(href).status == 200
    end

    test "no foreign key is needed to reach the owner", %{entry: entry} do
      # The point of the link. A client holding the record needs no knowledge of
      # a nesting convention, and no `ledger_id` to paste into a path it built
      # itself.
      node = body(get("/domain/entry/#{entry.id}"))

      assert is_binary(node["ledger"]["@id"])
    end
  end

  describe "a write names its parent" do
    test "a create posts to the flat collection with the ledger as an IRI", %{ledger: ledger} do
      conn =
        request(:post, "/domain/entry", %{
          "memo" => "New",
          "ledger" => %{"@id" => "/domain/ledger/#{ledger.id}"}
        })

      assert conn.status in [200, 201]
      assert body(conn)["memo"] == "New"
      assert body(conn)["ledger"]["@id"] == "/domain/ledger/#{ledger.id}"
    end

    test "an update patches the flat member", %{entry: entry} do
      conn = request(:patch, "/domain/entry/#{entry.id}", %{"memo" => "Changed"})

      assert conn.status == 200
      assert body(conn)["memo"] == "Changed"
    end

    test "the ledger is not inherited from the path", %{ledger: ledger} do
      # Under nesting the owner id was merged into the write from the URL. With
      # a flat address there is nothing to inherit, so a create that names no
      # ledger must be refused rather than silently taking one.
      conn = request(:post, "/domain/entry", %{"memo" => "Orphan"})

      refute conn.status in [200, 201],
             "a required link must be named, not inferred from the address"

      # And naming it works, which is what proves the refusal is about the
      # missing link rather than about the route.
      assert request(:post, "/domain/entry", %{
               "memo" => "Named",
               "ledger" => %{"@id" => "/domain/ledger/#{ledger.id}"}
             }).status in [200, 201]
    end
  end

  describe "the owner is unaffected" do
    test "it keeps its own routes", %{ledger: ledger} do
      assert get("/domain/ledger/#{ledger.id}").status == 200
      assert get("/domain/ledger").status == 200
    end

    test "it states its entries when the read loads them", %{ledger: ledger, entry: entry} do
      # The other direction of the same edge. Being pointed at is a fact about
      # the relationship, not a declaration either resource makes.
      assert %{"@type" => "Collection", "hydra:member" => [member]} = loaded(ledger)["entries"]
      assert member["@id"] == "/domain/entry/#{entry.id}"
    end
  end

  describe "a to-many link survives having no route" do
    test "a loaded collection carries its members", %{ledger: ledger} do
      # The regression this stage most risks. Both `unloaded_link/5` and
      # `loaded_link/5` fell through to `nil` without a `%Route{}`, so removing
      # the related routes without fixing them first makes every to-many link
      # vanish from every node — "described in the ontology and absent from the
      # node", which is the defect first-class links were written to fix,
      # reintroduced from the other end.
      entries = loaded(ledger)["entries"]

      assert entries["hydra:totalItems"] == 1
      assert length(entries["hydra:member"]) == 1
    end

    test "the collection is a blank node, not a fabricated URL", %{ledger: ledger} do
      # Honest rather than degraded: this collection is not separately
      # addressable, it exists as the value of this property on this record.
      # Minting an `@id` no route serves would be worse than having none.
      refute Map.has_key?(loaded(ledger)["entries"], "@id")
    end

    test "an unloaded to-many is absent, not empty", %{ledger: ledger} do
      # Zero members would assert the ledger *has* no entries, which is false —
      # it has one. Omitting the key means "not loaded", which is what is true.
      refute Map.has_key?(body(get("/domain/ledger/#{ledger.id}")), "entries")
    end

    test "members carry their own flat @id, so each is a link and the data", %{
      ledger: ledger,
      entry: entry
    } do
      [member] = loaded(ledger)["entries"]["hydra:member"]

      assert member["memo"] == "M"
      assert get(member["@id"]).status == 200
      assert member["@id"] == "/domain/entry/#{entry.id}"
    end
  end

  # This ledger, read by an action that loads `:entries`. A named read derives a
  # collection index rather than a member route, so the node comes out of
  # `hydra:member` — which is the same idiom `/comments/with_document` uses.
  defp loaded(ledger) do
    "/domain/ledger/with_entries"
    |> get()
    |> body()
    |> Map.get("hydra:member")
    |> Enum.find(&(&1["@id"] == "/domain/ledger/#{ledger.id}"))
  end
end
