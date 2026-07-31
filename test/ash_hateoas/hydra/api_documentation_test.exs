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
