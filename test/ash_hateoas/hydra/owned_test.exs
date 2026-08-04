defmodule AshHateoas.Hydra.OwnedTest do
  @moduledoc """
  A resource that declares an owner is addressed through it.

      /domain/ledger/<ledger-id>/entry/<entry-id>

  `owned_by :ledger` names a **relationship**, so the destination — and
  therefore what the URL nests under — is read from the data model rather than
  restated. The declaration cannot disagree with the relationship it names, and
  `ash_hateoas` learns what owns what without learning what a ledger *is*.

  ## What the nesting has to be, to be worth anything

  A URL that merely *looks* nested is decoration. These tests pin the two
  properties that make it a constraint:

    * a record id under the **wrong** owner is a 404, not a redirect and not a
      silent success — otherwise the owner segment is ignored and the address
      lies about containment
    * there is **no** flat collection — a list of every entry across every
      ledger is not a resource this domain has, and keeping one would be the
      single URL still implying entries exist independently

  Both are asserted on what the router *does*, not on the shape of the route
  string.
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

  describe "the URL carries the owner" do
    test "a record resolves under its owner", %{ledger: ledger, entry: entry} do
      conn = get("/domain/ledger/#{ledger.id}/entry/#{entry.id}")

      assert conn.status == 200
      assert body(conn)["memo"] == "M"
    end

    test "the node's @id is the nested URL, not a flat one", %{ledger: ledger, entry: entry} do
      node = body(get("/domain/ledger/#{ledger.id}/entry/#{entry.id}"))

      assert node["@id"] == "/domain/ledger/#{ledger.id}/entry/#{entry.id}"
    end

    test "no placeholder survives into any advertised URL", %{ledger: ledger, entry: entry} do
      # The failure this hit three times while being built: nesting adds a
      # second placeholder to every route, and each href builder substituted
      # only `:id`. A node then advertises `/ledger/:ledger_id/entry/<id>` —
      # a pattern rather than an address, and one that 404s.
      raw = get("/domain/ledger/#{ledger.id}/entry/#{entry.id}").resp_body

      refute raw =~ ":ledger_id", "a route placeholder reached the wire"

      # Both spellings, because `schema:urlTemplate` now renders placeholders in
      # RFC 6570's. That is right in the *documentation*, which describes a
      # class and has no id to substitute — but a served node was built for one
      # record, so an unbound `{ledger_id}` here would mean a client following
      # `schema:target` POSTs to a literal brace. `hateoas2dsl` prefers the
      # template over the node's own `@id` (`submit.ts:183`), so it would.
      refute raw =~ "{ledger_id}", "an unexpanded variable reached a served node"
      refute raw =~ "{id}", "an unexpanded variable reached a served node"
    end
  end

  describe "the owner is a constraint, not decoration" do
    test "a record under the WRONG owner is a 404", %{other: other, entry: entry} do
      # The entry exists and the ledger exists; only the pairing is wrong. A
      # 200 here would mean the owner segment is ignored, and the URL would be
      # asserting a containment the server does not check.
      assert get("/domain/ledger/#{other.id}/entry/#{entry.id}").status == 404
    end

    test "an unknown owner is a 404 even for a real record", %{entry: entry} do
      assert get("/domain/ledger/#{Ash.UUID.generate()}/entry/#{entry.id}").status == 404
    end

    test "a wrong owner is indistinguishable from a missing record", %{
      other: other,
      entry: entry
    } do
      # Both 404. Checking containment after the read rather than as a filter
      # keeps a mismatch from confirming the record exists somewhere else.
      wrong_owner = get("/domain/ledger/#{other.id}/entry/#{entry.id}")
      missing = get("/domain/ledger/#{other.id}/entry/#{Ash.UUID.generate()}")

      assert wrong_owner.status == missing.status
      assert body(wrong_owner) == body(missing)
    end

    test "a nested collection holds only that owner's records", %{
      ledger: ledger,
      other: other
    } do
      Entry
      |> Ash.Changeset.for_create(:create, %{memo: "Theirs", ledger_id: other.id})
      |> Ash.create!(authorize?: false)

      memos =
        "/domain/ledger/#{ledger.id}/entry"
        |> get()
        |> body()
        |> Map.get("hydra:member")
        |> Enum.map(& &1["memo"])

      assert memos == ["M"]
    end
  end

  describe "an owned resource has no independent address" do
    test "the flat member URL does not exist", %{entry: entry} do
      assert get("/domain/entry/#{entry.id}").status == 404
    end

    test "the flat collection does not exist" do
      # A list of every entry across every ledger is not a resource this domain
      # has. Keeping one would be the single URL still implying an entry stands
      # on its own.
      assert get("/domain/entry").status == 404
    end
  end

  describe "writes nest too" do
    test "a create posts to the nested collection", %{ledger: ledger} do
      conn = request(:post, "/domain/ledger/#{ledger.id}/entry", %{"memo" => "New"})

      assert conn.status in [200, 201]
      assert body(conn)["memo"] == "New"
    end

    test "an update patches the nested member", %{ledger: ledger, entry: entry} do
      conn =
        request(:patch, "/domain/ledger/#{ledger.id}/entry/#{entry.id}", %{"memo" => "Changed"})

      assert conn.status == 200
      assert body(conn)["memo"] == "Changed"
    end

    test "an update under the wrong owner is refused", %{other: other, entry: entry} do
      # The write path has to enforce what the read path enforces, or the
      # constraint is only advisory — a client that constructs the URL rather
      # than following it could edit across owners.
      conn =
        request(:patch, "/domain/ledger/#{other.id}/entry/#{entry.id}", %{"memo" => "Hijacked"})

      assert conn.status == 404

      assert Ash.get!(Entry, entry.id, authorize?: false).memo == "M",
             "the record must be untouched"
    end
  end

  describe "being an owner changes nothing about the owner" do
    test "the owner keeps its flat routes", %{ledger: ledger} do
      assert get("/domain/ledger/#{ledger.id}").status == 200
      assert get("/domain/ledger").status == 200
    end

    test "only the child declares the relationship" do
      # `owned_by` sits on the owned resource, since it is the child whose
      # addressability depends on the owner. A resource does not become an
      # owner by being pointed at.
      assert AshHateoas.Resource.Info.owned_by(Entry) == :ledger
      assert AshHateoas.Resource.Info.owned_by(Ledger) == nil
    end

    test "the owner is resolved from the relationship, not restated" do
      # The declaration names a relationship; the destination comes from the
      # data model. So the two cannot drift.
      assert %{name: :ledger, destination: Ledger} = AshHateoas.Resource.Info.owner(Entry)
    end
  end
end
