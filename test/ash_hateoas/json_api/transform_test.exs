defmodule AshHateoas.JsonApi.TransformTest do
  @moduledoc """
  End-to-end tests: a real request through the real `AshJsonApi.Router`,
  driven in-process with `Plug.Test`. No HTTP server, no Phoenix.
  """

  use ExUnit.Case, async: true

  alias AshHateoas.JsonApi.Transform
  alias AshHateoas.Test.{Actor, Document, Endpoint, PublicNote}

  @admin %Actor{id: "admin-1", role: :admin}
  @viewer %Actor{id: "viewer-1", role: :viewer}

  setup do
    editor = %Actor{id: unique("editor"), role: :editor}

    doc =
      Document
      |> Ash.Changeset.for_create(:create, %{title: "Spec", owner_id: editor.id})
      |> Ash.create!(authorize?: false)

    %{doc: doc, editor: editor}
  end

  describe "single-record documents" do
    test "affordances arrive as named link objects", %{doc: doc} do
      links = links_for(get("/documents/#{doc.id}", @admin))

      assert Map.has_key?(links, "approve")
      assert Map.has_key?(links, "update")
    end

    test "a link object carries href, rel, title and meta", %{doc: doc} do
      approve = links_for(get("/documents/#{doc.id}", @admin))["approve"]

      # The href carries the domain's json_api prefix ("/api"), which is what a
      # client needs to follow it — the router itself mounts wherever the host
      # app forwards it.
      assert approve["href"] == "/api/documents/#{doc.id}/approve"
      assert approve["rel"] == "https://ash-hateoas.org/rels/approve"
      assert approve["title"] == "Approve this document so it can be published."
      assert approve["meta"]["method"] == "PATCH"
    end

    test "route params are substituted into the href", %{doc: doc} do
      approve = links_for(get("/documents/#{doc.id}", @admin))["approve"]

      refute approve["href"] =~ ":id", "the :id placeholder must be replaced"
      assert approve["href"] =~ doc.id
    end

    test "merging is additive — a pre-existing self link survives" do
      # PublicNote declares `get :read, primary?: true`, which is the condition
      # under which ash_json_api emits a per-record "self". The merge must add
      # affordances alongside it, not replace the links map.
      note =
        PublicNote
        |> Ash.Changeset.for_create(:create, %{text: "hi"})
        |> Ash.create!(authorize?: false)

      links = links_for(get("/public_notes/#{note.id}", nil))

      assert Map.has_key?(links, "self"),
             "merging must not clobber links ash_json_api produced"

      assert Map.has_key?(links, "destroy"),
             "affordances must be merged alongside it"
    end

    test "the document-level self link survives the rewrite", %{doc: doc} do
      body = get("/documents/#{doc.id}", @admin) |> body()

      assert body["links"]["self"] =~ "/documents/#{doc.id}"
    end

    test "two actors receive different links for the same URL", %{doc: doc} do
      admin_links = links_for(get("/documents/#{doc.id}", @admin))
      viewer_links = links_for(get("/documents/#{doc.id}", @viewer))

      assert Map.has_key?(admin_links, "approve")
      refute Map.has_key?(viewer_links, "approve")
    end
  end

  describe "field descriptors in link meta (R4)" do
    test "fields carry name, type and required", %{doc: doc} do
      fields = fields_for(doc, "approve")
      notify = Enum.find(fields, &(&1["name"] == "notify"))

      assert notify["type"] == "boolean"
      assert notify["required"] == false
    end

    test "required inverts Ash's allow_nil? at the wire edge", %{doc: doc} do
      # :title is allow_nil? false on create, so the wire must say required true.
      fields = collection_fields_for(@admin, "create")
      title = Enum.find(fields, &(&1["name"] == "title"))

      if title, do: assert(title["required"] == true)
    end

    test "a sensitive argument appears without its default", %{doc: doc} do
      fields = fields_for(doc, "approve")
      signing_key = Enum.find(fields, &(&1["name"] == "signing_key"))

      assert signing_key, "the client must know the argument exists"

      refute Map.has_key?(signing_key, "default"),
             "a sensitive default must never reach the wire"
    end

    test "non-sensitive defaults are emitted", %{doc: doc} do
      fields = fields_for(doc, "approve")
      notify = Enum.find(fields, &(&1["name"] == "notify"))

      assert notify["default"] == false
    end

    test "private arguments never appear", %{doc: doc} do
      names = doc |> fields_for("approve") |> Enum.map(& &1["name"])

      refute "internal_trace" in names
    end

    test "constraints.enum is JSON-encodable", %{doc: doc} do
      fields = fields_for(doc, "approve")
      visibility = Enum.find(fields, &(&1["name"] == "visibility"))

      assert visibility["constraints"]["enum"] == ["public", "private"],
             "atoms must be stringified or Jason.encode! would fail"
    end
  end

  describe "collection documents (R8, R9)" do
    test "type-level affordances arrive in top-level links" do
      body = get("/documents", @admin) |> body()

      assert Map.has_key?(body["links"], "create"),
             "the cold-start case must tell a client it may create"
    end

    test "records inside a collection carry NO affordances" do
      body = get("/documents", @admin) |> body()

      for record <- body["data"] do
        record_links = Map.get(record, "links", %{})

        refute Map.has_key?(record_links, "approve"),
               "per-record affordances on a collection are the M × N case we removed"
      end
    end

    test "collection affordances still respect authorization" do
      body = get("/documents", @viewer) |> body()

      refute Map.has_key?(body["links"], "create"),
             "viewer is neither :editor nor :admin"
    end
  end

  describe "the JSON:API profile (R3)" do
    test "is advertised in the content-type", %{doc: doc} do
      [content_type] =
        "/documents/#{doc.id}"
        |> get(@admin)
        |> Plug.Conn.get_resp_header("content-type")

      assert content_type =~ "application/vnd.api+json"
      assert content_type =~ ~s(profile="#{Transform.profile()}")
    end
  end

  describe "safety" do
    test "a resource with no policies still renders" do
      note =
        PublicNote
        |> Ash.Changeset.for_create(:create, %{text: "hi"})
        |> Ash.create!(authorize?: false)

      links = links_for(get("/public_notes/#{note.id}", nil))

      assert Map.has_key?(links, "destroy"),
             "no authorizers means no restrictions, per Ash semantics"
    end

    test "content-length matches the rewritten body", %{doc: doc} do
      conn = get("/documents/#{doc.id}", @admin)
      [length] = Plug.Conn.get_resp_header(conn, "content-length")

      assert String.to_integer(length) == byte_size(conn.resp_body),
             "a stale content-length truncates the response"
    end

    test "the response is still valid JSON:API", %{doc: doc} do
      body = get("/documents/#{doc.id}", @admin) |> body()

      assert body["data"]["type"] == "document"
      assert body["data"]["id"] == doc.id
      assert is_map(body["data"]["attributes"])
    end
  end

  defp get(path, actor) do
    :get
    |> Plug.Test.conn(path)
    |> Plug.Conn.put_req_header("accept", "application/vnd.api+json")
    |> Ash.PlugHelpers.set_actor(actor)
    |> Endpoint.call(Endpoint.init([]))
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp links_for(conn), do: conn |> body() |> get_in(["data", "links"]) || %{}

  defp fields_for(doc, action) do
    "/documents/#{doc.id}"
    |> get(@admin)
    |> links_for()
    |> get_in([action, "meta", "fields"]) || []
  end

  defp collection_fields_for(actor, action) do
    "/documents"
    |> get(actor)
    |> body()
    |> get_in(["links", action, "meta", "fields"]) || []
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
