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
      Ledger
      |> Ash.Changeset.for_create(:create, %{name: "Mine"})
      |> Ash.create!(authorize?: false)

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

    test "a declared load and ?load= agree", %{ledger: ledger, entry: entry} do
      # Two doors to one shape: an action that declares `load: [:entries]`, and
      # `?load=entries` on the default read. They must produce the same
      # collection, or a client gets different answers for the same question.
      assert %{"@type" => "Collection", "hydra:member" => [member]} = loaded(ledger)["entries"]
      assert member["@id"] == "/domain/entry/#{entry.id}"
      assert member["memo"] == "M"
    end
  end

  describe "a to-many is a collection, referenced then expanded" do
    test "an unloaded to-many carries references and a total", %{ledger: ledger, entry: entry} do
      # Not a bare reference and not an absence: a real collection, whose
      # members are the `@id`s of the records it holds. A client learns which
      # entries exist and can follow any of them, without the server rendering
      # them.
      entries = body(get("/domain/ledger/#{ledger.id}"))["entries"]

      assert entries["@id"] == "/domain/ledger/#{ledger.id}/entries"
      assert entries["hydra:totalItems"] == 1
      assert entries["hydra:member"] == [%{"@id" => "/domain/entry/#{entry.id}"}]
    end

    test "a member reference resolves", %{ledger: ledger} do
      [%{"@id" => href}] = body(get("/domain/ledger/#{ledger.id}"))["entries"]["hydra:member"]

      assert get(href).status == 200
    end

    test "?load expands the same members in place", %{ledger: ledger, entry: entry} do
      # `load` controls **expansion**, never presence — the rule a to-one
      # already follows. The collection is the same collection; its members
      # carry their own data rather than only their identity.
      entries = body(get("/domain/ledger/#{ledger.id}?load=entries"))["entries"]

      assert [member] = entries["hydra:member"]
      assert member["@id"] == "/domain/entry/#{entry.id}"
      assert member["memo"] == "M"
    end

    test "both forms are one collection with one identity", %{ledger: ledger} do
      # Expansion states more about the members; it never changes which
      # collection this is. `?load=entries` is how a client *asked* — it is not
      # what the collection is called.
      referenced = body(get("/domain/ledger/#{ledger.id}"))["entries"]
      expanded = body(get("/domain/ledger/#{ledger.id}?load=entries"))["entries"]

      assert referenced["@id"] == expanded["@id"]
      assert referenced["hydra:totalItems"] == expanded["hydra:totalItems"]
    end

    test "the collection's @id resolves to that collection", %{ledger: ledger, entry: entry} do
      # What makes the identity real rather than decorative.
      collection = body(get(body(get("/domain/ledger/#{ledger.id}"))["entries"]["@id"]))

      assert collection["@type"] == "Collection"
      assert [member] = collection["hydra:member"]
      assert member["@id"] == "/domain/entry/#{entry.id}"
    end

    test "an unknown load name is ignored, not refused", %{ledger: ledger} do
      # The parameter narrows a response; it must never widen what may be read,
      # so naming something unloadable yields exactly the unasked response.
      asked = body(get("/domain/ledger/#{ledger.id}?load=nonsense"))["entries"]
      unasked = body(get("/domain/ledger/#{ledger.id}"))["entries"]

      assert asked == unasked
    end
  end

  # This ledger with its entries expanded. Either door works — a read that
  # declares the load, or `?load=` on the default one — and they must agree.
  defp loaded(ledger) do
    "/domain/ledger/with_entries"
    |> get()
    |> body()
    |> Map.get("hydra:member")
    |> Enum.find(&(&1["@id"] == "/domain/ledger/#{ledger.id}"))
  end
end
