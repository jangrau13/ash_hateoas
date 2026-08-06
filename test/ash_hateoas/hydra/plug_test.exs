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

  alias AshHateoas.Test.{
    Actor,
    Article,
    Comment,
    Document,
    HydraEndpoint,
    MultiRead,
    Order,
    Paged,
    Person,
    ReadFailure
  }

  # An API's classes are named after where it is served, so this is the test
  # connection's own origin. The library namespace carries only the library's
  # own terms (`ah:Script`, `ah:identity`), which every implementation shares.
  @vocab "http://www.example.com/vocab#"

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

  describe "there is no entry point" do
    test "GET / serves nothing" do
      # A collection-of-collections is not a resource — nothing in any domain
      # corresponds to it, so there is nothing here to represent.
      assert get("/", @admin).status == 404
    end

    test "a client can start anywhere, because every response describes the API" do
      # What replaces it, and what a hardcoded index was never needed for. A
      # client holding *any* URL — a bookmark, another service's link — is one
      # hop from the full description.
      doc =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "Anywhere", owner_id: "admin-1"})
        |> Ash.create!(authorize?: false)

      for path <- ["/documents/#{doc.id}", "/documents", "/doc"] do
        conn = get(path, @admin)

        assert conn.status == 200

        assert [link] = Plug.Conn.get_resp_header(conn, "link")
        assert link =~ Context.api_documentation_rel()
      end
    end

    test "a record's parent is its collection, and nothing above it" do
      doc =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "Parented", owner_id: "admin-1"})
        |> Ash.create!(authorize?: false)

      node = body(get("/documents/#{doc.id}", @admin))

      assert node["hydra:collection"]["@id"] =~ "/documents"

      # `hydra:view` is reserved for what it is for — a
      # `hydra:PartialCollectionView` on a paged collection — and a member node
      # has none.
      refute Map.has_key?(node, "hydra:view")
    end
  end

  describe "the ApiDocumentation (GET /doc)" do
    test "carries supportedClass with properties and operations" do
      doc = body(get("/doc", @admin))

      assert doc["@type"] == "ApiDocumentation"
      assert is_list(doc["hydra:supportedClass"])

      document =
        Enum.find(doc["hydra:supportedClass"], &(&1["@id"] == "#{@vocab}Document"))

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
      assert node["@type"] == "#{@vocab}Document"
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

    test "the node carries the granted set as an odrl:permission list", %{doc: doc} do
      admin = body(get("/documents/#{doc.id}", @admin))
      viewer = body(get("/documents/#{doc.id}", @viewer))

      admin_actions = admin["odrl:permission"] |> Enum.map(& &1["odrl:action"]["@id"])
      viewer_actions = viewer["odrl:permission"] |> Enum.map(& &1["odrl:action"]["@id"])

      # both may read; only the admin gets the modifying permissions
      assert "odrl:read" in admin_actions
      assert "odrl:read" in viewer_actions
      assert "odrl:modify" in admin_actions
      refute "odrl:modify" in viewer_actions

      # permissions target the node
      assert Enum.all?(
               admin["odrl:permission"],
               &(&1["odrl:target"]["@id"] =~ "/documents/#{doc.id}")
             )
    end

    test "structural navigation is emitted as typed node references", %{doc: doc} do
      node = body(get("/documents/#{doc.id}", @admin))

      # A navigation link is a {"@id", "@type"} node ref, never {href, rel}.
      collection = node["hydra:collection"]
      assert collection["@id"] =~ "/documents"
      assert collection["@type"] == "Collection"
      refute Map.has_key?(collection, "href")
      refute Map.has_key?(collection, "rel")

      # `collection` is the only structural link. There was a second, `up`,
      # rendered as `hydra:view` and pointing at `/` — a record's owning
      # "collection-of-collections", which is not a resource.
      refute Map.has_key?(node, "hydra:view")
    end
  end

  describe "resource links" do
    test "a followable link renders as a JSON-LD reference node, not a bare string" do
      # The value's host is the trust boundary — internal vs external is read off
      # the @id itself, so no extra flag is emitted.
      doc =
        Document
        |> Ash.Changeset.for_create(:create, %{
          title: "Linked",
          owner_id: "admin-1",
          related_order: "https://another-backend.example/orders/xyz"
        })
        |> Ash.create!(authorize?: false)

      node = body(get("/documents/#{doc.id}", @admin))

      assert node["related_order"] == %{"@id" => "https://another-backend.example/orders/xyz"}
    end

    test "an ordinary attribute stays a plain value" do
      doc =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "Plain", owner_id: "admin-1"})
        |> Ash.create!(authorize?: false)

      assert body(get("/documents/#{doc.id}", @admin))["title"] == "Plain"
    end

    test "an unloaded to-many is a collection of references" do
      article =
        Article
        |> Ash.Changeset.for_create(:create, %{title: "Hydra"})
        |> Ash.create!(authorize?: false)

      # Its own `@id`, its true size, and its members as bare `@id`s. A client
      # learns which comments exist and can follow any of them, without the
      # server rendering them.
      comments = body(get("/articles/#{article.id}", @admin))["comments"]

      assert comments["@id"] == "/articles/#{article.id}/comments"
      assert comments["@type"] == "Collection"
      assert comments["hydra:totalItems"] == 0
    end

    test "?load expands the members without changing the collection" do
      article =
        Article
        |> Ash.Changeset.for_create(:create, %{title: "Hydra"})
        |> Ash.create!(authorize?: false)

      document =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "D", owner_id: "admin-1"})
        |> Ash.create!(authorize?: false)

      Comment
      |> Ash.Changeset.for_create(:create, %{
        body: "mine",
        document_id: document.id,
        article_id: article.id
      })
      |> Ash.create!(authorize?: false)

      referenced = body(get("/articles/#{article.id}", @admin))["comments"]
      expanded = body(get("/articles/#{article.id}?load=comments", @admin))["comments"]

      # One collection, one identity. `load` controls **expansion**, never
      # presence — the rule a to-one already follows.
      assert referenced["@id"] == expanded["@id"]
      assert referenced["hydra:totalItems"] == expanded["hydra:totalItems"]

      assert [%{"@id" => ref}] = referenced["hydra:member"]
      assert [member] = expanded["hydra:member"]
      assert member["@id"] == ref
      assert member["body"] == "mine"
    end

    test "the related collection link RESOLVES, and holds only that record's related rows" do
      article =
        Article
        |> Ash.Changeset.for_create(:create, %{title: "Followed"})
        |> Ash.create!(authorize?: false)

      other =
        Article
        |> Ash.Changeset.for_create(:create, %{title: "Unrelated"})
        |> Ash.create!(authorize?: false)

      document =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "Owner", owner_id: "admin-1"})
        |> Ash.create!(authorize?: false)

      for {body_text, article_id} <- [{"mine", article.id}, {"theirs", other.id}] do
        Comment
        |> Ash.Changeset.for_create(:create, %{
          body: body_text,
          document_id: document.id,
          article_id: article_id
        })
        |> Ash.create!(authorize?: false)
      end

      # The members arrive IN the node rather than one fetch away, so this is
      # one request where it was N+1. Each member still carries its own flat
      # `@id`, so it is a link and the data at once.
      node =
        "/articles/with_comments"
        |> get(@admin)
        |> body()
        |> Map.get("hydra:member")
        |> Enum.find(&(&1["@id"] =~ article.id))

      collection = node["comments"]

      assert collection["@type"] == "Collection"

      # Scoped to the source record: a collection holding every comment would
      # be present and well-formed while still being wrong.
      assert Enum.map(collection["hydra:member"], & &1["body"]) == ["mine"]
      assert collection["hydra:totalItems"] == 1

      # And each member resolves on its own.
      assert get(hd(collection["hydra:member"])["@id"], @admin).status == 200
    end

    test "the collection's @id resolves; the JSON:API linkage route does not" do
      article =
        Article
        |> Ash.Changeset.for_create(:create, %{title: "Gone"})
        |> Ash.create!(authorize?: false)

      # `/articles/7/comments` addresses this article's comments — a real
      # resource, and the identity the inline collection carries, so it must
      # resolve. `/relationships/comments` returned linkage without the members;
      # the reference list the node now carries says that in place.
      assert get("/articles/#{article.id}/comments", @admin).status == 200
      assert get("/articles/#{article.id}/relationships/comments", @admin).status == 404
    end

    test "the node advertises how to ask for expansion" do
      # A client must discover `?load=` rather than know it out of band, which
      # is what Level 3 requires. `hydra:IriTemplate` is the only construct
      # Hydra has for a client-parameterised request — there is no term for
      # "expand this" — so the template is where this is said.
      article =
        Article
        |> Ash.Changeset.for_create(:create, %{title: "Ask"})
        |> Ash.create!(authorize?: false)

      template = body(get("/articles/#{article.id}", @admin))["hydra:search"]

      assert template["@type"] == "IriTemplate"
      assert template["hydra:template"] == "/articles/#{article.id}{?load*}"

      # One mapping per loadable relationship, each keyed on the property IRI
      # the ontology declares — so the legal values are stated by enumeration in
      # terms a client can resolve.
      properties =
        template
        |> Map.get("hydra:mapping")
        |> Enum.map(& &1["hydra:property"]["@id"])

      assert "#{@vocab}article/comments" in properties
      assert Enum.all?(template["hydra:mapping"], &(&1["hydra:variable"] == "load"))
      assert Enum.all?(template["hydra:mapping"], &(&1["hydra:required"] == false))
    end

    test "the template is on the addressed node, not on every member" do
      # Repeating it on each member of each page would be noise: a member is one
      # URL away from the node that addresses it.
      Article |> Ash.Changeset.for_create(:create, %{title: "M"}) |> Ash.create!(authorize?: false)

      member = hd(body(get("/articles", @admin))["hydra:member"])

      refute Map.has_key?(member, "hydra:search")
    end

    test "a member is never addressed through another record" do
      # The distinction this stage draws: a collection that has no other address
      # gets one; a record that already has an address does not get a second.
      article =
        Article
        |> Ash.Changeset.for_create(:create, %{title: "Nested"})
        |> Ash.create!(authorize?: false)

      document =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "D", owner_id: "admin-1"})
        |> Ash.create!(authorize?: false)

      comment =
        Comment
        |> Ash.Changeset.for_create(:create, %{
          body: "b",
          document_id: document.id,
          article_id: article.id
        })
        |> Ash.create!(authorize?: false)

      assert get("/articles/#{article.id}/comments/#{comment.id}", @admin).status == 404
      assert get("/comments/#{comment.id}", @admin).status == 200
    end

    test "a belongs_to surfaces as a node reference built from the foreign key" do
      document =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "Target", owner_id: "admin-1"})
        |> Ash.create!(authorize?: false)

      comment =
        Comment
        |> Ash.Changeset.for_create(:create, %{body: "points home", document_id: document.id})
        |> Ash.create!(authorize?: false)

      node = body(get("/comments/#{comment.id}", @admin))

      # A node reference and nothing more: the target's identity, no target data.
      assert %{"@id" => ref} = node["document"]
      assert ref =~ "/documents/#{document.id}"
      assert map_size(node["document"]) == 1
    end

    test "the to-one reference RESOLVES to the target node" do
      document =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "Resolvable", owner_id: "admin-1"})
        |> Ash.create!(authorize?: false)

      comment =
        Comment
        |> Ash.Changeset.for_create(:create, %{body: "follow me", document_id: document.id})
        |> Ash.create!(authorize?: false)

      node = body(get("/comments/#{comment.id}", @admin))
      target = body(get(node["document"]["@id"], @admin))

      assert target["@id"] =~ "/documents/#{document.id}"
      assert target["title"] == "Resolvable"
    end

    test "a LOADED to-one link is stated in place, carrying the target's own @id" do
      document =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "Expanded", owner_id: "admin-1"})
        |> Ash.create!(authorize?: false)

      Comment
      |> Ash.Changeset.for_create(:create, %{body: "loaded", document_id: document.id})
      |> Ash.create!(authorize?: false)

      # `with_document` loads :document — the only lever, an ordinary Ash
      # preparation. Same link, stated rather than referenced.
      collection = body(get("/comments/with_document", @admin))
      comment = Enum.find(collection["hydra:member"], &(&1["body"] == "loaded"))

      target = comment["document"]
      assert target["@id"] =~ "/documents/#{document.id}"
      assert target["title"] == "Expanded"

      # Identity is unchanged by expansion: the same URL the reference carried.
      assert target["@id"] == body(get("/documents/#{document.id}", @admin))["@id"]
    end

    test "a LOADED to-many link states its collection in place, at the same @id" do
      document =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "Has comments", owner_id: "admin-1"})
        |> Ash.create!(authorize?: false)

      Comment
      |> Ash.Changeset.for_create(:create, %{body: "in place", document_id: document.id})
      |> Ash.create!(authorize?: false)

      collection = body(get("/documents/with_comments", @admin))
      node = Enum.find(collection["hydra:member"], &(&1["@id"] =~ document.id))

      comments = node["comments"]
      assert comments["@type"] == "Collection"
      assert comments["hydra:totalItems"] == 1
      assert [member] = comments["hydra:member"]
      assert member["body"] == "in place"

      # The expanded collection keeps the URL the unloaded reference carries,
      # so following it and reading it give the same answer.
      unloaded = body(get("/documents/#{document.id}", @admin))["comments"]
      assert comments["@id"] == unloaded["@id"]
    end

    test "a cycle terminates: the back-reference is a plain node reference" do
      document =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "Cyclic", owner_id: "admin-1"})
        |> Ash.create!(authorize?: false)

      Comment
      |> Ash.Changeset.for_create(:create, %{body: "back-ref", document_id: document.id})
      |> Ash.create!(authorize?: false)

      # document → comments → document: the second hop is already rendered, so
      # it degrades to the reference rather than recursing.
      collection = body(get("/documents/with_comments", @admin))
      node = Enum.find(collection["hydra:member"], &(&1["@id"] =~ document.id))
      [member] = node["comments"]["hydra:member"]

      assert member["document"] == %{"@id" => node["@id"]}
    end

    test "a nil foreign key yields no key at all — absent, not null" do
      document =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "Holder", owner_id: "admin-1"})
        |> Ash.create!(authorize?: false)

      comment =
        Comment
        |> Ash.Changeset.for_create(:create, %{body: "unattached", document_id: document.id})
        |> Ash.create!(authorize?: false)

      node = body(get("/comments/#{comment.id}", @admin))

      # the optional belongs_to :article was never related
      refute Map.has_key?(node, "article")
    end
  end

  describe "writing links" do
    setup do
      document =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "Write target", owner_id: "admin-1"})
        |> Ash.create!(authorize?: false)

      %{document: document}
    end

    test "a create relates by node reference — the IRI a read emits", %{document: document} do
      created =
        body(
          request(:post, "/comments", @admin, %{
            "body" => "by reference",
            "document" => %{"@id" => "/documents/#{document.id}"}
          })
        )

      # Written as a link, and readable back as the same link.
      assert created["document"]["@id"] =~ "/documents/#{document.id}"
      assert body(get(created["@id"], @admin))["document"]["@id"] =~ "/documents/#{document.id}"
    end

    test "a create relates by IDENTITY OBJECT — the declared natural key", %{document: document} do
      Person
      |> Ash.Changeset.for_create(:create, %{name: "Ada"})
      |> Ash.create!(authorize?: false)

      created =
        body(
          request(:post, "/comments", @admin, %{
            "body" => "by name",
            "document" => %{"@id" => "/documents/#{document.id}"},
            "author" => %{"name" => "Ada"}
          })
        )

      # The identity object named an existing individual; the response carries
      # its IRI. The key was a lookup, never content.
      assert %{"@id" => author} = created["author"]
      assert author =~ "/people/"
      assert body(get(author, @admin))["name"] == "Ada"
    end

    test "a write response carries links in the same shape a read does", %{document: document} do
      Person
      |> Ash.Changeset.for_create(:create, %{name: "Shape"})
      |> Ash.create!(authorize?: false)

      created =
        body(
          request(:post, "/comments", @admin, %{
            "body" => "shape",
            "document" => %{"@id" => "/documents/#{document.id}"},
            "author" => %{"name" => "Shape"}
          })
        )

      # Managing a relationship leaves its target loaded, which would expand
      # that one link and reference every other — a shape decided by how the
      # write ran rather than by what the action declares.
      assert Map.keys(created["author"]) == ["@id"]
      assert Map.keys(created["document"]) == ["@id"]

      read = body(get(created["@id"], @admin))
      assert read["author"] == created["author"]
      assert read["document"] == created["document"]
    end

    test "an update replaces a link", %{document: document} do
      other =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "Other", owner_id: "admin-1"})
        |> Ash.create!(authorize?: false)

      comment =
        Comment
        |> Ash.Changeset.for_create(:create, %{body: "relinked", document_id: document.id})
        |> Ash.create!(authorize?: false)

      updated =
        body(
          request(:patch, "/comments/#{comment.id}", @admin, %{
            "document" => %{"@id" => "/documents/#{other.id}"}
          })
        )

      assert updated["document"]["@id"] =~ "/documents/#{other.id}"
    end

    test "an update clears an optional link with null", %{document: document} do
      person =
        Person
        |> Ash.Changeset.for_create(:create, %{name: "Removable"})
        |> Ash.create!(authorize?: false)

      comment =
        Comment
        |> Ash.Changeset.for_create(:create, %{
          body: "has author",
          document_id: document.id,
          author_id: person.id
        })
        |> Ash.create!(authorize?: false)

      updated = body(request(:patch, "/comments/#{comment.id}", @admin, %{"author" => nil}))

      # Cleared means the key is gone, not present-and-null.
      refute Map.has_key?(updated, "author")
    end

    test "a REQUIRED link refuses to be cleared", %{document: document} do
      comment =
        Comment
        |> Ash.Changeset.for_create(:create, %{body: "must stay", document_id: document.id})
        |> Ash.create!(authorize?: false)

      conn = request(:patch, "/comments/#{comment.id}", @admin, %{"document" => nil})

      # The affordance advertises `hydra:required`; the write path must not
      # contradict it.
      assert conn.status == 422
      assert body(conn)["hydra:title"] =~ "required"

      # And the link still holds.
      assert body(get("/comments/#{comment.id}", @admin))["document"]["@id"] =~ document.id
    end

    test "an IRI pointing at the WRONG class is refused", %{document: document} do
      person =
        Person
        |> Ash.Changeset.for_create(:create, %{name: "Not a document"})
        |> Ash.create!(authorize?: false)

      conn =
        request(:post, "/comments", @admin, %{
          "body" => "mismatched",
          "document" => %{"@id" => "/people/#{person.id}"}
        })

      assert conn.status == 422
      assert body(conn)["hydra:title"] =~ "person"
      # Not silently ignored: relating to the wrong class is an error the
      # client can act on.
      refute is_nil(document)
    end

    test "an IRI that names no resource of this API is refused" do
      conn =
        request(:post, "/comments", @admin, %{
          "body" => "foreign",
          "document" => %{"@id" => "https://elsewhere.example/documents/1"}
        })

      assert conn.status == 422
    end

    test "an identity object whose keys are not a declared identity is refused", %{
      document: document
    } do
      conn =
        request(:post, "/comments", @admin, %{
          "body" => "guessed key",
          "document" => %{"@id" => "/documents/#{document.id}"},
          "author" => %{"additional_name" => "guessed"}
        })

      # Matching on a guessed property matches the wrong record, or none, and
      # does so silently — so it is refused rather than attempted.
      assert conn.status == 422
      assert body(conn)["hydra:title"] =~ "identity"
    end

    test "a dangling reference is refused, and says nothing about existence", %{
      document: document
    } do
      unknown = Ash.UUID.generate()

      conn =
        request(:post, "/comments", @admin, %{
          "body" => "dangling",
          "document" => %{"@id" => "/documents/#{unknown}"}
        })

      assert conn.status in [400, 404, 422]
      refute is_nil(document)
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

  describe "a named collection read (GET /base/<action>)" do
    setup do
      for label <- ["alpha", "alpha", "beta"] do
        MultiRead
        |> Ash.Changeset.for_create(:create, %{label: label})
        |> Ash.create!(authorize?: false)
      end

      :ok
    end

    test "a named index is not shadowed by the /:id member route — it runs its own action" do
      # /domain/multi_read/by_label must reach the by_label read, NOT be captured
      # as /domain/multi_read/:id with id="by_label" (which would 404). This is
      # the regression: a literal path segment beats the :id wildcard.
      coll = body(get("/domain/multi_read/by_label?label=alpha", @admin))

      assert coll["@type"] == "Collection"
      # by_label filters on the query argument -> only the two "alpha" rows
      assert coll["hydra:totalItems"] == 2

      for member <- coll["hydra:member"] do
        assert member["label"] == "alpha"
      end
    end

    test "the primary base index still runs the primary read (all rows)" do
      coll = body(get("/domain/multi_read", @admin))
      assert coll["@type"] == "Collection"
      assert coll["hydra:totalItems"] == 3
    end
  end

  describe "a failing collection read is classified, not blanket-403" do
    test "a policy denial is a 403 Forbidden" do
      conn = get("/domain/read_failure/denied", @admin)
      assert conn.status == 403
      assert body(conn)["@type"] == "Error"
    end

    test "a prepare that adds a field error is a 400 Bad Request, not 403" do
      conn = get("/domain/read_failure/invalid", @admin)

      # the read is authorized — the failure is invalid/unavailable input, so the
      # status must NOT be 403 (the old blanket behaviour)
      assert conn.status == 400
      node = body(conn)
      assert node["@type"] == "Error"
      assert node["hydra:description"] =~ "unavailable"
    end

    test "a prepare that raises is a 500 Internal Server Error, not 403" do
      conn = get("/domain/read_failure/boom", @admin)

      assert conn.status == 500
      assert body(conn)["@type"] == "Error"
    end

    test "the primary read still succeeds" do
      ReadFailure
      |> Ash.Changeset.for_create(:create, %{label: "ok"})
      |> Ash.create!(authorize?: false)

      coll = body(get("/domain/read_failure", @admin))
      assert coll["@type"] == "Collection"
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

    test "a transition carries its schema.org potentialAction (semantic_action override)",
         %{order: order} do
      node = body(get("/orders/#{order.id}", @admin))

      # confirm is a named sub-action -> link node; its operation carries the
      # schema:potentialAction, sharpened to ConfirmAction by semantic_action.
      link = node["ah:confirm"]
      [op] = link["hydra:operation"]
      action = op["schema:potentialAction"]

      assert action["@type"] == "https://schema.org/ConfirmAction"

      # The role is *all* it carries. Where the operation acts is the link
      # node's own `@id`, and how is `hydra:method` — so a `schema:target`
      # would say both a second time, in a second vocabulary.
      refute Map.has_key?(action, "schema:target")
      assert link["@id"] == "/orders/#{order.id}/confirm"
      assert op["hydra:method"] == "PATCH"
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

    test "DELETE a member destroys it and returns the record it destroyed" do
      doc =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "Doomed", owner_id: "admin-1"})
        |> Ash.create!(authorize?: false)

      conn = request(:delete, "/documents/#{doc.id}", @admin, %{})
      assert conn.status == 200

      # The record's final state, so a client can show what it deleted without
      # having fetched it beforehand and held it across the delete.
      destroyed = Jason.decode!(conn.resp_body)
      assert destroyed["title"] == "Doomed"
      assert destroyed["@id"] =~ doc.id

      # and it is gone
      assert body(get("/documents/#{doc.id}", @admin))["@type"] == "Error"
    end

    test "a destroyed record is returned without operations" do
      doc =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "Doomed", owner_id: "admin-1"})
        |> Ash.create!(authorize?: false)

      destroyed = Jason.decode!(request(:delete, "/documents/#{doc.id}", @admin, %{}).resp_body)

      # Every affordance on this node would address a record that no longer
      # exists, so a client following one gets a 404 having been told it was
      # available. The representation says what the record *was*, not what may
      # be done to it.
      refute Map.has_key?(destroyed, "hydra:operation")
    end

    test "the declared return of a destroy matches what it actually sends" do
      doc =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "Doomed", owner_id: "admin-1"})
        |> Ash.create!(authorize?: false)

      conn = request(:delete, "/documents/#{doc.id}", @admin, %{})
      assert conn.status == 200

      # The two must stay in step. A body carrying the record while the
      # documentation declared `owl:Nothing` would be the same mismatch stage 1
      # fixed for validate/save — a client parsing what it was told to expect
      # and finding something else.
      operation =
        body(get("/doc", @admin))["hydra:supportedClass"]
        |> Enum.find(&(&1["@id"] == "#{@vocab}Document"))
        |> Map.fetch!("hydra:supportedOperation")
        |> Enum.find(&(&1["hydra:method"] == "DELETE"))

      assert operation["hydra:returns"] == %{"@id" => "#{@vocab}Document"}

      declared = Jason.decode!(conn.resp_body)["@type"]
      assert "#{@vocab}Document" in List.wrap(declared)
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
               "#{@vocab}Person",
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

    test "the ApiDocumentation advertises the subclass relation, not equivalence" do
      doc = body(get("/doc", @admin))

      person_class =
        Enum.find(
          doc["hydra:supportedClass"],
          &(&1["@id"] == "#{@vocab}Person")
        )

      # Not `owl:equivalentClass`, which asserts the two are the same set. A
      # local Person has an id, a tenant and domain rules `schema:Person` knows
      # nothing of — and equivalence licenses substitution in *both*
      # directions, so a reasoner could conclude things about schema.org's
      # class from statements about ours.
      refute Map.has_key?(person_class, "owl:equivalentClass")

      # The honest claim, asserted once in the ontology: a local Person *is a*
      # schema.org Person, without the converse.
      declared =
        Enum.find(doc["@included"], &(&1["@id"] == "#{@vocab}Person"))

      assert declared["rdfs:subClassOf"] == %{"@id" => "https://schema.org/Person"}
      assert declared["@type"] == ["owl:Class", "hydra:Class"]

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

  describe "base_url makes rendered hrefs absolute" do
    @base "https://api.example.com"

    # Mount the plug with a base_url, bypassing HydraEndpoint (which has none).
    defp get_based(path, actor) do
      opts = AshHateoas.Hydra.Plug.init(domains: [AshHateoas.Test.Domain], base_url: @base)

      conn(:get, path)
      |> Ash.PlugHelpers.set_actor(actor)
      |> AshHateoas.Hydra.Plug.call(opts)
    end

    setup do
      doc =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "Based", owner_id: "admin-1"},
          actor: @admin
        )
        |> Ash.create!()

      %{doc: doc}
    end

    test "a member node's @id is absolute", %{doc: doc} do
      node = body(get_based("/documents/#{doc.id}", @admin))

      assert node["@id"] == "#{@base}/documents/#{doc.id}"
    end

    test "a record's collection link is absolute", %{doc: doc} do
      node = body(get_based("/documents/#{doc.id}", @admin))

      # A collection link is a typed node reference — the URL lives in @id.
      assert get_in(node, ["hydra:collection", "@id"]) == "#{@base}/documents"
    end

    test "the Link header advertises an absolute ApiDocumentation URL", %{doc: doc} do
      # Asserted on a real resource rather than `/`, which serves nothing. The
      # header is what makes any URL a valid place to start, so it has to be
      # right on the URLs a client actually holds.
      conn = get_based("/documents/#{doc.id}", @admin)

      [link] = get_resp_header(conn, "link")
      assert link =~ "<#{@base}/doc>"
    end

    test "a named sub-action's href is absolute", %{doc: doc} do
      node = body(get_based("/documents/#{doc.id}", @admin))

      # Document has an `approve` sub-action at /documents/:id/approve.
      assert get_in(node, ["ah:approve", "@id"]) == "#{@base}/documents/#{doc.id}/approve"
    end

    test "routing still matches the plain path — base_url is render-only", %{doc: doc} do
      # The request path carries no host; matching must still find the member.
      assert get_based("/documents/#{doc.id}", @admin).status == 200
    end
  end
end
