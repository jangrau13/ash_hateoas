defmodule AshHateoas.Hydra.NodeContextTest do
  @moduledoc """
  A record node must **expand** to the properties the ontology declares.

  The ApiDocumentation declares `vocab#article/title`; a node emits the key
  `"title"`. Nothing joins those two but the node's own `@context`, and until it
  did, instance data and vocabulary never met: every relationship link on every
  record expanded to **no triples at all**, and `title` and `name` were captured
  by the referenced Hydra context and expanded to `hydra:title` / `hydra:name`.

  ## Why these assertions run on expanded output

  `node["title"] == "Spec"` passes in every one of those states. The raw JSON is
  identical whether a key is bound, unbound, or bound to the wrong IRI — the
  difference exists only after a processor applies the context. Asserting on
  keys is how this shipped, and it is the same blind spot that hid four
  malformed `@context` term definitions which made every emitted document fail
  to expand outright.

  So the document goes through `JSON.LD` (see `AshHateoas.Test.JsonLd`), and the
  assertions are about triples. An unbound key does not appear as an empty
  value; it does not appear **at all**, which is precisely why a missing
  relationship link is invisible until you look at the graph.

  ## Why document-wide rather than example-by-example

  An example-based test cannot catch a whole *category* going unbound, which is
  how this survived: `additional_name` expanded correctly the entire time,
  because it carries a `semantic_property`. Every other key on every routed
  resource did not.
  """

  use ExUnit.Case, async: false

  import Plug.Test

  alias AshHateoas.Hydra.ApiDocumentation
  alias AshHateoas.Test.JsonLd

  alias AshHateoas.Test.{Actor, Article, Comment, Document, HydraEndpoint, Person}

  @admin %Actor{id: "admin-1", role: :admin}
  @hydra "http://www.w3.org/ns/hydra/core#"
  @vocab "https://ash-hateoas.org/vocab#"

  defp get(path) do
    conn(:get, path)
    |> Ash.PlugHelpers.set_actor(@admin)
    |> HydraEndpoint.call([])
    |> then(&Jason.decode!(&1.resp_body))
  end

  # Every property IRI the ApiDocumentation declares. A node asserting a
  # predicate outside this set is a dangling reference — the defect `Ontology`
  # exists to remove, reached from the instance side.
  defp declared_iris do
    [AshHateoas.Test.Domain]
    |> ApiDocumentation.build()
    |> Map.get("@included")
    |> Enum.map(& &1["@id"])
    |> MapSet.new()
  end

  defp article do
    a =
      Article |> Ash.Changeset.for_create(:create, %{title: "Spec"}) |> Ash.create!(authorize?: false)

    d =
      Document
      |> Ash.Changeset.for_create(:create, %{title: "Owner", owner_id: "admin-1"})
      |> Ash.create!(authorize?: false)

    Comment
    |> Ash.Changeset.for_create(:create, %{body: "c", document_id: d.id, article_id: a.id})
    |> Ash.create!(authorize?: false)

    a
  end

  defp person do
    Person
    |> Ash.Changeset.for_create(:create, %{name: "Ada", additional_name: "L"})
    |> Ash.create!(authorize?: false)
  end

  describe "the document expands at all" do
    test "a record node survives a conformant processor" do
      # Not a formality. Four malformed term definitions in the `@context` made
      # every document this package emitted fail here, for its entire life,
      # while every key-based assertion passed.
      node = get("/articles/#{article().id}")

      assert [_ | _] = JsonLd.expand(node)
    end
  end

  describe "a relative @id resolves against this API" do
    test "a record's identity is not resolved against w3.org" do
      # `base_url` is optional and `svc_simulation` serves relative `@id`s, so a
      # node may legitimately carry `/articles/1`. A relative IRI still has to
      # resolve against something, and with no `@base` a processor falls back to
      # the document's location — the last remote context loaded, which is
      # Hydra's. Every record in the API then had an identity under
      # `http://www.w3.org/`, colliding with everyone else's records resolved
      # the same way.
      id = article().id
      node = get("/articles/#{id}")

      assert node["@id"] == "/articles/#{id}", "expected the emitted @id to stay relative"

      expanded = JsonLd.node(node, "/articles/#{id}")
      refute String.starts_with?(expanded["@id"], "http://www.w3.org/")

      # `Plug.Test`'s default host — the request states the origin, so a
      # deployment that never sets `base_url` still gets true identities.
      assert String.starts_with?(expanded["@id"], "http://www.example.com/")
    end

    test "a collection and its members resolve against the same base" do
      id = article().id
      collection = get("/articles")

      member = JsonLd.node(collection, "/articles/#{id}")
      refute String.starts_with?(member["@id"], "http://www.w3.org/")
    end
  end

  describe "a node's data expands to the properties the ontology declares" do
    test "every data key becomes a triple, and every one is declared" do
      id = article().id
      node = get("/articles/#{id}")
      declared = declared_iris()

      expanded = JsonLd.node(node, node["@id"])

      # What the JSON claims to carry: the node's own keys, excluding the Hydra
      # and ODRL machinery that already travels prefixed.
      data_keys =
        node
        |> Map.keys()
        |> Enum.reject(&String.starts_with?(&1, "@"))
        |> Enum.reject(&String.contains?(&1, ":"))

      # The predicates that came from this resource's own vocabulary, leaving
      # aside the Hydra/ODRL machinery the node also carries.
      own =
        expanded
        |> JsonLd.predicates()
        |> Enum.filter(&String.starts_with?(&1, "#{@vocab}article/"))

      # An unbound key is dropped silently, so the count is the whole signal:
      # the JSON says three things and the graph said one.
      assert length(own) == length(data_keys),
             """
             #{length(data_keys)} data keys expanded to #{length(own)} of this resource's properties.
             keys:       #{inspect(Enum.sort(data_keys))}
             predicates: #{inspect(own)}
             A key that expands to nothing is dropped by any JSON-LD processor.
             """

      for predicate <- own do
        assert MapSet.member?(declared, predicate),
               "#{predicate} is asserted by a node but declared nowhere in the ApiDocumentation"
      end
    end

    test "a to-many relationship link is a triple, not a dropped key" do
      # The worst case measured: `comments` was unbound, so the relationship
      # link on every record node produced zero triples. The link was in the
      # JSON and absent from the graph.
      id = article().id
      expanded = "/articles/#{id}" |> get() |> then(&JsonLd.node(&1, &1["@id"]))

      assert [target] = JsonLd.values(expanded, "#{@vocab}article/comments")
      assert target =~ "/articles/#{id}/comments"
    end

    test "a scalar keeps its value through expansion" do
      expanded = "/articles/#{article().id}" |> get() |> then(&JsonLd.node(&1, &1["@id"]))

      assert JsonLd.values(expanded, "#{@vocab}article/title") == ["Spec"]
    end
  end

  describe "the Hydra context does not capture a record's own keys" do
    test "title is the article's title, not a link's title" do
      # `hydra:title` is the label of a *link or operation*, and the
      # ApiDocumentation uses it correctly on a SupportedProperty. On a record
      # it claims the node's link-title is "Spec" — a wrong triple rather than a
      # missing one, which a reasoner consumes without complaint.
      expanded = "/articles/#{article().id}" |> get() |> then(&JsonLd.node(&1, &1["@id"]))

      assert JsonLd.values(expanded, "#{@vocab}article/title") == ["Spec"]
      refute Map.has_key?(expanded, "#{@hydra}title")
    end

    test "name is the person's name, not a link's name" do
      expanded = "/people/#{person().id}" |> get() |> then(&JsonLd.node(&1, &1["@id"]))

      assert JsonLd.values(expanded, "#{@vocab}person/name") == ["Ada"]
      refute Map.has_key?(expanded, "#{@hydra}name")
    end

    test "a declared semantic_property still wins over ours" do
      # A mapped attribute advertises the well-known IRI, matching what
      # `ApiDocumentation.supported_properties/2` puts on the wire for it.
      expanded = "/people/#{person().id}" |> get() |> then(&JsonLd.node(&1, &1["@id"]))

      assert JsonLd.values(expanded, "https://schema.org/additionalName") == ["L"]
      refute Map.has_key?(expanded, "#{@vocab}person/additional_name")
    end
  end

  describe "a member expands the same inside a collection as outside it" do
    test "a collection's members carry their properties" do
      id = article().id
      member = "/articles" |> get() |> JsonLd.node("/articles/#{id}")

      assert JsonLd.values(member, "#{@vocab}article/title") == ["Spec"]
    end

    test "a related collection binds the DESTINATION's properties" do
      # The members are comments. Binding the source's terms would expand `body`
      # against `vocab#article/body`, declared nowhere — a dangling reference
      # reached by using the wrong resource.
      node = get("/articles/#{article().id}/comments")

      bodies =
        node
        |> JsonLd.nodes()
        |> Enum.flat_map(&JsonLd.values(&1, "#{@vocab}comment/body"))

      assert "c" in bodies
    end

    test "the same record expands identically in both shapes" do
      id = article().id
      alone = "/articles/#{id}" |> get() |> then(&JsonLd.node(&1, &1["@id"]))
      in_collection = "/articles" |> get() |> JsonLd.node("/articles/#{id}")

      # A member read on its own and the same member read inside its collection
      # must say the same things — the collection used the bare context, so they
      # did not.
      assert JsonLd.values(alone, "#{@vocab}article/title") ==
               JsonLd.values(in_collection, "#{@vocab}article/title")
    end

    test "a node reached THROUGH A LINK expands the same as one read directly" do
      # An expanded link carries the target's keys while the document's context
      # binds the source's, so the target's data would expand to nothing — the
      # same silent drop, one level down. The node's own scoped `@context` is
      # what makes the two agree.
      document =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "Through", owner_id: "admin-1"})
        |> Ash.create!(authorize?: false)

      Comment
      |> Ash.Changeset.for_create(:create, %{body: "via link", document_id: document.id})
      |> Ash.create!(authorize?: false)

      href = "/documents/#{document.id}"
      alone = href |> get() |> then(&JsonLd.node(&1, &1["@id"]))
      through_link = "/comments/with_document" |> get() |> JsonLd.node(href)

      assert JsonLd.values(alone, "#{@vocab}document/title") == ["Through"]

      assert JsonLd.values(through_link, "#{@vocab}document/title") ==
               JsonLd.values(alone, "#{@vocab}document/title")
    end
  end
end
