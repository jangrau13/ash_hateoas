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
      Enum.find(doc["hydra:supportedClass"], &(&1["@id"] == "https://ash-hateoas.org/vocab#Document"))

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
  end

  test "the whole document is JSON-encodable" do
    doc = ApiDocumentation.build([AshHateoas.Test.Domain], entrypoint: "/api")
    assert {:ok, _} = Jason.encode(doc)
  end
end
