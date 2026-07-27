defmodule AshHateoas.Hydra.PlugTest do
  @moduledoc """
  End-to-end: real requests through `AshHateoas.Hydra.Plug`, driven in-process
  with `Plug.Test`. No HTTP server, no Phoenix.
  """

  # Not async: several tests read whole collections from a shared private ETS
  # table, so a concurrently-writing test could perturb a count.
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias AshHateoas.Hydra.Context
  alias AshHateoas.Test.{Actor, Document, HydraEndpoint, Order, Paged, Person}

  @admin %Actor{id: "admin-1", role: :admin}
  @viewer %Actor{id: "viewer-1", role: :viewer}

  defp get(path, actor) do
    conn(:get, path)
    |> Ash.PlugHelpers.set_actor(actor)
    |> HydraEndpoint.call([])
  end

  defp request(method, path, actor, payload) do
    conn(method, path, Jason.encode!(payload))
    |> put_req_header("content-type", "application/ld+json")
    |> Ash.PlugHelpers.set_actor(actor)
    |> HydraEndpoint.call([])
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  describe "content type and discovery" do
    test "every response is application/ld+json with an apiDocumentation Link header" do
      conn = get("/", @admin)

      assert get_resp_header(conn, "content-type") |> hd() =~ "application/ld+json"

      [link] = get_resp_header(conn, "link")
      assert link =~ Context.api_documentation_rel()
      assert link =~ "/doc"
    end
  end

  describe "the entry point (GET /)" do
    test "lists reachable types with their collection links" do
      doc = body(get("/", @admin))

      assert doc["@type"] == "EntryPoint"
      collections = doc["hydra:collection"]
      assert is_map(collections)
      # document and order are both routed and readable
      assert Map.has_key?(collections, "document")
      assert get_in(collections, ["document", "href"]) =~ "/documents"
    end
  end

  describe "the ApiDocumentation (GET /doc)" do
    test "carries supportedClass with properties and operations" do
      doc = body(get("/doc", @admin))

      assert doc["@type"] == "ApiDocumentation"
      assert is_list(doc["hydra:supportedClass"])

      document =
        Enum.find(doc["hydra:supportedClass"], &(&1["@id"] == Context.class_iri("document")))

      assert document["@type"] == "Class"
      assert Enum.any?(document["hydra:supportedProperty"], &(&1["hydra:title"] == "title"))
      assert Enum.any?(document["hydra:supportedOperation"], &(&1["hydra:method"] == "PATCH"))
    end
  end

  describe "a single record (GET member)" do
    setup do
      doc =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "Spec", owner_id: "admin-1"})
        |> Ash.create!(authorize?: false)

      %{doc: doc}
    end

    test "renders a JSON-LD node with @id, @type and flattened attributes", %{doc: doc} do
      node = body(get("/documents/#{doc.id}", @admin))

      assert node["@id"] =~ "/documents/#{doc.id}"
      assert node["@type"] == Context.class_iri("document")
      assert node["title"] == "Spec"
      assert node["@context"]
    end

    test "carries the actor's affordances as operations", %{doc: doc} do
      node = body(get("/documents/#{doc.id}", @admin))

      # approve is a named sub-action -> a link node with a distinct URL
      approve = node["ah:approve"]
      assert approve["@id"] =~ "/documents/#{doc.id}/approve"
      assert [%{"@type" => "Operation", "hydra:method" => "PATCH"}] = approve["hydra:operation"]
    end

    test "two actors see different operation sets", %{doc: doc} do
      admin = body(get("/documents/#{doc.id}", @admin))
      viewer = body(get("/documents/#{doc.id}", @viewer))

      # admin may approve; a viewer may not
      assert Map.has_key?(admin, "ah:approve")
      refute Map.has_key?(viewer, "ah:approve")
    end
  end

  describe "a collection (GET index)" do
    setup do
      for i <- 1..2 do
        Document
        |> Ash.Changeset.for_create(:create, %{title: "Doc #{i}", owner_id: "admin-1"})
        |> Ash.create!(authorize?: false)
      end

      :ok
    end

    test "renders a hydra:Collection with member and totalItems" do
      coll = body(get("/documents", @admin))

      assert coll["@type"] == "Collection"
      assert is_list(coll["hydra:member"])
      assert coll["hydra:totalItems"] >= 2
    end

    test "collection-level affordances live on the collection, members carry none" do
      coll = body(get("/documents", @admin))

      # create is a collection-level operation
      assert coll["hydra:operation"] || coll["ah:create"]

      # members are bare nodes — no per-record operations (bounds page cost)
      for member <- coll["hydra:member"] do
        refute Map.has_key?(member, "hydra:operation")
        refute Map.has_key?(member, "ah:approve")
      end
    end
  end

  describe "the state machine over the wire" do
    setup do
      order =
        Order
        |> Ash.Changeset.for_create(:create, %{reference: "R-1"})
        |> Ash.create!(authorize?: false)

      %{order: order}
    end

    test "a pending order offers confirm and cancel, not ship", %{order: order} do
      node = body(get("/orders/#{order.id}", @admin))

      assert Map.has_key?(node, "ah:confirm")
      assert Map.has_key?(node, "ah:cancel")
      refute Map.has_key?(node, "ah:ship")
    end

    test "after confirming, it offers ship not confirm", %{order: order} do
      confirmed =
        order
        |> Ash.Changeset.for_update(:confirm, %{})
        |> Ash.update!(authorize?: false)

      node = body(get("/orders/#{confirmed.id}", @admin))

      assert Map.has_key?(node, "ah:ship")
      refute Map.has_key?(node, "ah:confirm")
    end
  end

  describe "writes" do
    test "POST to the collection creates a record and returns 201 with the node" do
      conn = request(:post, "/documents", @admin, %{"title" => "New", "owner_id" => "admin-1"})

      assert conn.status == 201
      node = body(conn)
      assert node["title"] == "New"
      assert node["@id"] =~ "/documents/"
    end

    test "PATCH a member runs the update and returns the new state" do
      doc =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "Old", owner_id: "admin-1"})
        |> Ash.create!(authorize?: false)

      conn = request(:patch, "/documents/#{doc.id}", @admin, %{"title" => "Renamed"})

      assert conn.status == 200
      assert body(conn)["title"] == "Renamed"
    end

    test "invoking a state transition over the wire advances the machine" do
      order =
        Order
        |> Ash.Changeset.for_create(:create, %{reference: "R-2"})
        |> Ash.create!(authorize?: false)

      # confirm is a named sub-action at /orders/:id/confirm (PATCH)
      conn = request(:patch, "/orders/#{order.id}/confirm", @admin, %{})
      assert conn.status == 200

      # the returned node now offers ship, not confirm
      node = body(get("/orders/#{order.id}", @admin))
      assert Map.has_key?(node, "ah:ship")
      refute Map.has_key?(node, "ah:confirm")
    end

    test "DELETE a member destroys it and returns 204" do
      doc =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "Doomed", owner_id: "admin-1"})
        |> Ash.create!(authorize?: false)

      conn = request(:delete, "/documents/#{doc.id}", @admin, %{})
      assert conn.status == 204

      # and it is gone
      assert body(get("/documents/#{doc.id}", @admin))["@type"] == "Error"
    end

    test "an unauthorized write is refused, not performed" do
      doc =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "Guarded", owner_id: "someone-else"})
        |> Ash.create!(authorize?: false)

      # @viewer is neither admin nor owner -> update policy denies
      conn = request(:patch, "/documents/#{doc.id}", @viewer, %{"title" => "Hijacked"})
      assert conn.status in [403, 404]
    end
  end

  describe "pagination" do
    setup do
      for i <- 1..5 do
        Paged
        |> Ash.Changeset.for_create(:create, %{label: "P#{i}"})
        |> Ash.create!(authorize?: false)
      end

      :ok
    end

    test "a paged collection carries a PartialCollectionView with page links" do
      coll = body(get("/paged?limit=2&offset=0", @admin))

      assert coll["@type"] == "Collection"
      assert length(coll["hydra:member"]) == 2
      assert coll["hydra:totalItems"] >= 5

      view = coll["hydra:view"]
      assert view["@type"] == "PartialCollectionView"
      assert view["hydra:first"] =~ "offset=0"
      assert view["hydra:next"] =~ "offset=2"
      # first page has no previous
      refute Map.has_key?(view, "hydra:previous")
    end

    test "a middle page carries previous and next" do
      view = body(get("/paged?limit=2&offset=2", @admin))["hydra:view"]

      assert view["hydra:previous"] =~ "offset=0"
      assert view["hydra:next"] =~ "offset=4"
    end

    test "an unpaginated resource emits no view" do
      coll = body(get("/documents", @admin))
      refute Map.has_key?(coll, "hydra:view")
    end
  end

  describe "well-known (schema.org) types and properties" do
    setup do
      person =
        Person
        |> Ash.Changeset.for_create(:create, %{name: "Jane", additional_name: "Q"})
        |> Ash.create!(authorize?: false)

      %{person: person}
    end

    test "a record node carries both its own class and the schema.org type", %{person: person} do
      node = body(get("/people/#{person.id}", @admin))

      assert node["@type"] == [
               "https://ash-hateoas.org/vocab#Person",
               "https://schema.org/Person"
             ]
    end

    test "a mapped attribute resolves to its schema.org property via @context", %{person: person} do
      node = body(get("/people/#{person.id}", @admin))

      # the flat key still carries the value...
      assert node["additional_name"] == "Q"

      # ...and the node @context binds that key to the schema.org property.
      context_terms =
        node["@context"]
        |> Enum.filter(&is_map/1)
        |> Enum.reduce(%{}, &Map.merge(&2, &1))

      assert context_terms["additional_name"] == "https://schema.org/additionalName"
    end

    test "the ApiDocumentation advertises the equivalence" do
      doc = body(get("/doc", @admin))

      person_class =
        Enum.find(
          doc["hydra:supportedClass"],
          &(&1["@id"] == "https://ash-hateoas.org/vocab#Person")
        )

      assert person_class["owl:equivalentClass"] == %{"@id" => "https://schema.org/Person"}

      # the mapped property advertises the schema.org IRI directly
      property_ids =
        person_class["hydra:supportedProperty"]
        |> Enum.map(& &1["hydra:property"]["@id"])

      assert "https://schema.org/additionalName" in property_ids
    end

    test "an absolute IRI is used verbatim, a bare token resolves against schema.org" do
      assert AshHateoas.Resource.Info.semantic_type(Person) == "https://schema.org/Person"

      assert AshHateoas.Resource.Info.semantic_properties(Person) == %{
               additional_name: "https://schema.org/additionalName"
             }
    end
  end
end
