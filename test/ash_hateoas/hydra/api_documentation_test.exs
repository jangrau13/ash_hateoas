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
    assert title["ah:datatype"] == "xsd:string"
  end

  test "the whole document is JSON-encodable" do
    doc = ApiDocumentation.build([AshHateoas.Test.Domain], entrypoint: "/api")
    assert {:ok, _} = Jason.encode(doc)
  end
end
