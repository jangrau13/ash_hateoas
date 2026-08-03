defmodule AshHateoas.Hydra.ApiDocumentationTest do
  @moduledoc """
  The ApiDocumentation derives entirely from resource introspection + routes.
  """

  use ExUnit.Case, async: true

  alias AshHateoas.Hydra.ApiDocumentation

  test "builds an ApiDocumentation with entrypoint and a supportedClass per resource" do
    doc =
      ApiDocumentation.build([AshHateoas.Test.Domain],
        entrypoint: "/api",
        id: "/api/doc"
      )

    assert doc["@type"] == "ApiDocumentation"
    assert doc["hydra:entrypoint"] == "/api"
    assert doc["@id"] == "/api/doc"
    assert is_list(doc["hydra:supportedClass"])
    assert doc["@context"] |> List.first() == "http://www.w3.org/ns/hydra/context.jsonld"
  end

  test "the document class carries supportedProperty and supportedOperation" do
    doc = ApiDocumentation.build([AshHateoas.Test.Domain])

    document =
      Enum.find(
        doc["hydra:supportedClass"],
        &(&1["@id"] == "https://ash-hateoas.org/vocab#Document")
      )

    assert document, "expected a Document class in supportedClass"
    assert document["@type"] == "Class"

    prop_ids =
      document["hydra:supportedProperty"]
      |> Enum.map(& &1["hydra:property"]["@id"])

    assert "https://ash-hateoas.org/vocab#document/title" in prop_ids

    methods =
      document["hydra:supportedOperation"]
      |> Enum.map(& &1["hydra:method"])
      |> Enum.uniq()

    # Derived from the routed actions: read/create/update/approve/...
    assert "GET" in methods
    assert "POST" in methods
    assert "PATCH" in methods

    # a non-GET operation names what it returns (the resource's own class)
    write = Enum.find(document["hydra:supportedOperation"], &(&1["hydra:method"] == "POST"))
    assert write["hydra:returns"] == %{"@id" => "https://ash-hateoas.org/vocab#Document"}
  end

  test "a semantic type yields a companion supportedClass keyed by the schema.org IRI" do
    doc = ApiDocumentation.build([AshHateoas.Test.Domain])
    classes = doc["hydra:supportedClass"]

    vocab =
      Enum.find(classes, &(&1["@id"] == "https://ash-hateoas.org/vocab#Person"))

    companion =
      Enum.find(classes, &(&1["@id"] == "https://schema.org/Person"))

    # both the vocab# class and its schema.org companion are present, so a node
    # dual-typed [vocab#Person, schema:Person] resolves to a class under either.
    assert vocab, "expected the vocab# Person class"
    assert companion, "expected a schema.org Person companion class"

    # each declares the other its equivalent
    assert vocab["owl:equivalentClass"] == %{"@id" => "https://schema.org/Person"}
    assert companion["owl:equivalentClass"] == %{"@id" => "https://ash-hateoas.org/vocab#Person"}

    # the companion is fully described, not a stub — it carries the operations
    assert is_list(companion["hydra:supportedOperation"])
    assert companion["hydra:supportedProperty"] == vocab["hydra:supportedProperty"]
  end

  test "a resource without a semantic type yields exactly one supportedClass entry" do
    doc = ApiDocumentation.build([AshHateoas.Test.Domain])

    document_entries =
      Enum.filter(
        doc["hydra:supportedClass"],
        &(&1["@id"] == "https://ash-hateoas.org/vocab#Document")
      )

    assert length(document_entries) == 1
  end

  test "a to-many relationship is advertised as a hydra:Link supported property" do
    doc = ApiDocumentation.build([AshHateoas.Test.Domain])

    article =
      Enum.find(
        doc["hydra:supportedClass"],
        &(&1["@id"] == "https://ash-hateoas.org/vocab#Article")
      )

    link =
      Enum.find(
        article["hydra:supportedProperty"],
        &(&1["hydra:property"]["@id"] == "https://ash-hateoas.org/vocab#article/comments")
      )

    assert link, "expected a comments link property"
    # the property node is typed hydra:Link, so a client knows the key is a link
    assert link["hydra:property"]["@type"] == "hydra:Link"
    assert link["hydra:readable"] == true
    assert link["hydra:writeable"] == false
  end

  test "a link names the class it points at" do
    doc = ApiDocumentation.build([AshHateoas.Test.Domain])

    article =
      Enum.find(
        doc["hydra:supportedClass"],
        &(&1["@id"] == "https://ash-hateoas.org/vocab#Article")
      )

    link =
      Enum.find(
        article["hydra:supportedProperty"],
        &(&1["hydra:property"]["@id"] == "https://ash-hateoas.org/vocab#article/comments")
      )

    # Without a target class a link says only "followable", never "-> what",
    # which is not enough for a client to resolve the reference to a described
    # class. `article.comments` points at Comment.
    assert link["hydra:property"]["sh:class"] == "https://ash-hateoas.org/vocab#Comment"

    # A to-many link resolves to a collection of that class, not a single node.
    assert link["ah:targetKind"] == "Collection"
  end

  test "a to-one relationship is advertised as a hydra:Link supported property" do
    doc = ApiDocumentation.build([AshHateoas.Test.Domain])

    comment =
      Enum.find(
        doc["hydra:supportedClass"],
        &(&1["@id"] == "https://ash-hateoas.org/vocab#Comment")
      )

    link =
      Enum.find(
        comment["hydra:supportedProperty"],
        &(&1["hydra:property"]["@id"] == "https://ash-hateoas.org/vocab#comment/document")
      )

    # `Comment belongs_to :document` carries no route by design — a to-one is an
    # inline node reference, not a collection route — but it is still part of the
    # class's shape. Leaving it out left roughly half the graph edges undescribed
    # and invisible to any client deriving structure from the documentation.
    assert link, "expected a document link property for the belongs_to"
    assert link["hydra:property"]["@type"] == "hydra:Link"
    assert link["hydra:property"]["sh:class"] == "https://ash-hateoas.org/vocab#Document"

    # A to-one resolves to a single node, so it carries no collection marker.
    refute Map.has_key?(link, "ah:targetKind")
  end

  test "the raw foreign-key attribute stays alongside the link" do
    doc = ApiDocumentation.build([AshHateoas.Test.Domain])

    comment =
      Enum.find(
        doc["hydra:supportedClass"],
        &(&1["@id"] == "https://ash-hateoas.org/vocab#Comment")
      )

    titles = Enum.map(comment["hydra:supportedProperty"], & &1["hydra:title"])

    # The link is added, not substituted: `document_id` is a real writable
    # attribute a client still needs in order to set the relationship.
    assert "document_id" in titles
    assert "document" in titles
  end

  describe "ah:action" do
    test "an operation carries the action's own name" do
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])

      article =
        Enum.find(
          doc["hydra:supportedClass"],
          &(&1["@id"] == "https://ash-hateoas.org/vocab#Article")
        )

      names = Enum.map(article["hydra:supportedOperation"], & &1["ah:action"])

      # Hydra gives an operation no name of its own — it describes *how* to
      # invoke one, not what the domain calls it. `publish` is the only thing
      # that can label a button; "POST" cannot.
      assert "publish" in names
      assert "read" in names
    end

    test "two operations sharing a method are distinguishable" do
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])

      recipe =
        Enum.find(
          doc["hydra:supportedClass"],
          &(&1["@id"] == "https://ash-hateoas.org/vocab#Recipe")
        )

      posts =
        recipe["hydra:supportedOperation"]
        |> Enum.filter(&(&1["hydra:method"] == "POST"))
        |> Enum.map(& &1["ah:action"])

      # Three POSTs — create, validate and save. Without a name a client sees
      # three identical offers and cannot tell which one saves a document.
      assert "create" in posts
      assert "validate" in posts
      assert "save" in posts
      assert length(Enum.uniq(posts)) == length(posts)
    end
  end

  describe "the document operations declare what they are for" do
    defp recipe_operation(action) do
      [AshHateoas.Test.Domain]
      |> ApiDocumentation.build()
      |> Map.fetch!("hydra:supportedClass")
      |> Enum.find(&(&1["@id"] == "https://ash-hateoas.org/vocab#Recipe"))
      |> Map.fetch!("hydra:supportedOperation")
      |> Enum.find(&(&1["ah:action"] == action))
    end

    test "validate is a CheckAction, not a create" do
      # Both document operations are POSTs, so the type inferred from the method
      # is `CreateAction` for each — which says checking a document creates
      # something. Declaring the role is what lets a client tell them apart
      # without matching the string "validate", which is a naming convention
      # rather than anything the API states.
      assert recipe_operation("validate")["schema:potentialAction"]["@type"] ==
               "https://schema.org/CheckAction"
    end

    test "save is distinguishable from an ordinary record update" do
      # Not `schema:UpdateAction`, though that reads right in isolation: it is
      # already what any PATCH infers, so declaring it would make a document
      # save indistinguishable from updating one record. A term is only worth
      # declaring if it says something the inference does not.
      assert recipe_operation("save")["schema:potentialAction"]["@type"] ==
               "https://ash-hateoas.org/vocab#SaveAction"

      refute recipe_operation("save")["schema:potentialAction"]["@type"] ==
               recipe_operation("update")["schema:potentialAction"]["@type"]
    end

    test "the vocabulary relates both new terms to the nearest published one" do
      # So a client speaking only schema.org still learns something true: that
      # a save writes, and that a run is an action an agent performs.
      terms =
        AshHateoas.Hydra.Context.context()
        |> Enum.find(&is_map/1)

      assert terms["ah:SaveAction"] == %{
               "rdfs:subClassOf" => %{"@id" => "schema:UpdateAction"}
             }

      assert terms["ah:RunAction"] == %{"rdfs:subClassOf" => %{"@id" => "schema:Action"}}
    end

    test "the POSTs are told apart by role, not only by name" do
      types =
        for action <- ["create", "validate", "save", "cook"],
            do: recipe_operation(action)["schema:potentialAction"]["@type"]

      assert length(Enum.uniq(types)) == 4
    end

    test "an execute action carries a role schema.org has no term for" do
      # schema.org has nothing meaning "run this": `ControlAction` and
      # `ActivateAction` are device control, and `AchieveAction`'s subtypes are
      # Win/Lose/Tie. So the role is named in this package's vocabulary.
      #
      # Nothing about it is special-cased — `semantic_action` passes an absolute
      # IRI through verbatim, which is what makes a vocabulary this package does
      # not own expressible at all.
      assert recipe_operation("cook")["schema:potentialAction"]["@type"] ==
               "https://ash-hateoas.org/vocab#RunAction"
    end

    test "a resource declaring its own semantic_action keeps it" do
      # Generated as a default, like the actions themselves.
      assert %{validate: iri} =
               AshHateoas.Resource.Info.semantic_actions(AshHateoas.Test.Recipe)

      assert iri == "https://schema.org/CheckAction"
    end
  end

  describe "a document names the classes it holds" do
    defp document_property(action) do
      [AshHateoas.Test.Domain]
      |> ApiDocumentation.build()
      |> Map.fetch!("hydra:supportedClass")
      |> Enum.find(&(&1["@id"] == "https://ash-hateoas.org/vocab#Recipe"))
      |> Map.fetch!("hydra:supportedOperation")
      |> Enum.find(&(&1["ah:action"] == action))
      |> get_in(["hydra:expects", "hydra:supportedProperty"])
      |> Enum.find(&(&1["hydra:title"] == "document"))
    end

    test "the element classes are named, not left as 'an array of something'" do
      # Without this the wire says `jsonschema:ArraySchema` and nothing more, and
      # the only statement of what an element looks like is English prose in a
      # description — which a client cannot construct a call from.
      iris = document_property("save")["sh:class"] |> Enum.map(& &1["@id"])

      assert "https://ash-hateoas.org/vocab#Step" in iris
      assert "https://ash-hateoas.org/vocab#Ingredient" in iris
      assert "https://ash-hateoas.org/vocab#Technique" in iris
    end

    test "each named class is described in full elsewhere in the same document" do
      # The point of linking rather than inlining: the description is already
      # there, and a copy could drift from it.
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])
      described = MapSet.new(doc["hydra:supportedClass"], & &1["@id"])

      for %{"@id" => iri} <- document_property("save")["sh:class"] do
        assert iri in described, "#{iri} is named but never described"
      end
    end

    test "it names what a save accepts, not every relationship" do
      # Describing a different set would advertise a document the API rejects.
      managed =
        AshHateoas.Test.Recipe
        |> AshHateoas.RootActions.managed_relationships()
        |> Enum.map(& &1.destination)

      assert length(document_property("save")["sh:class"]) == length(managed)
    end

    test "a non-public relationship's class is not named" do
      # `public?` means "appears in public interfaces" and defaults to false.
      # `Recipe.audits` is private, so a client must not be told it may write
      # `recipe_audit` elements — and since `on_missing/2` destroys what an
      # owned `has_many` omits, being told so would let a document delete rows
      # it was never shown.
      iris = document_property("save")["sh:class"] |> Enum.map(& &1["@id"])

      refute "https://ash-hateoas.org/vocab#RecipeAudit" in iris
    end

    test "validate describes the same document as save" do
      # They take the same argument; a client checking against one and saving
      # against the other must not find them disagreeing.
      assert document_property("validate")["sh:class"] == document_property("save")["sh:class"]
    end

    test "sh:class is the term a link already uses, so nothing new is needed" do
      # A client that can follow a link property can read this unchanged.
      assert %{"rdfs:range" => %{"@id" => "jsonschema:ArraySchema"}} = document_property("save")
    end
  end

  describe "ah:identity" do
    test "a declared identity names the properties that key the class" do
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])

      ingredient =
        Enum.find(
          doc["hydra:supportedClass"],
          &(&1["@id"] == "https://ash-hateoas.org/vocab#Ingredient")
        )

      # `identity :unique_name, [:name]`. Without this on the wire a client has
      # no way to know what names a record, and is left guessing from
      # convention — is the key `name`, `title`, `slug`? A guess that is merely
      # usually right fails silently on the domain that names things
      # differently.
      assert ingredient["ah:identity"] == [
               [%{"@id" => "https://ash-hateoas.org/vocab#ingredient/name"}]
             ]
    end

    test "a resource with no declared identity carries no key" do
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])

      comment =
        Enum.find(
          doc["hydra:supportedClass"],
          &(&1["@id"] == "https://ash-hateoas.org/vocab#Comment")
        )

      # Absent rather than guessed. A client then knows it cannot match this
      # class by a natural key, instead of matching the wrong record.
      refute Map.has_key?(comment, "ah:identity")
    end

    test "the term is related to owl:hasKey in the context" do
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])
      terms = Enum.find(doc["@context"], &is_map/1)

      # `owl:hasKey` states the same fact but as a reasoning axiom — it
      # licenses an engine to conclude two records are the same individual,
      # where a client needs "match the record with this name". Declaring the
      # narrower term a subproperty keeps the weaker inference available
      # without asking a client to act on it.
      assert terms["ah:identity"]["rdfs:subPropertyOf"] == %{"@id" => "owl:hasKey"}
      assert terms["rdfs"] == "http://www.w3.org/2000/01/rdf-schema#"
    end
  end

  test "operations advertise their possibleStatus from the gate chain" do
    doc = ApiDocumentation.build([AshHateoas.Test.Domain])

    document =
      Enum.find(
        doc["hydra:supportedClass"],
        &(&1["@id"] == "https://ash-hateoas.org/vocab#Document")
      )

    # Document has authorizers -> a PATCH can 403, can fail validation (422),
    # and targets a member (404).
    patch =
      Enum.find(document["hydra:supportedOperation"], &(&1["hydra:method"] == "PATCH"))

    codes = patch["hydra:possibleStatus"] |> Enum.map(& &1["hydra:statusCode"])
    assert 403 in codes
    assert 422 in codes
    assert 404 in codes

    assert Enum.all?(patch["hydra:possibleStatus"], &(&1["@type"] == "Status"))
  end

  test "a supported property references the property and carries the datatype separately" do
    doc = ApiDocumentation.build([AshHateoas.Test.Domain])

    document =
      Enum.find(
        doc["hydra:supportedClass"],
        &(&1["@id"] == "https://ash-hateoas.org/vocab#Document")
      )

    title =
      Enum.find(
        document["hydra:supportedProperty"],
        &(&1["hydra:property"]["@id"] == "https://ash-hateoas.org/vocab#document/title")
      )

    # hydra:property is a reference node (rdf:Property range), datatype rides on ah:
    assert title["hydra:property"] == %{"@id" => "https://ash-hateoas.org/vocab#document/title"}
    assert title["sh:datatype"] == "xsd:string"
  end

  test "the whole document is JSON-encodable" do
    doc = ApiDocumentation.build([AshHateoas.Test.Domain], entrypoint: "/api")
    assert {:ok, _} = Jason.encode(doc)
  end
end
