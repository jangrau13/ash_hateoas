defmodule AshHateoas.Hydra.RendererTest do
  @moduledoc """
  Pure projection tests: an affordance envelope → Hydra JSON-LD members. No HTTP.
  """

  use ExUnit.Case, async: true

  alias AshHateoas.Hydra.Renderer
  alias AshHateoas.{Affordance, Field}

  describe "operation shape" do
    test "a write affordance becomes a hydra:Operation with expects Class" do
      affordance = %Affordance{
        name: :approve,
        href: "/documents/:id/approve",
        method: :patch,
        description: "Approve this document.",
        fields: [
          %Field{name: :notify, type: "boolean", allow_nil?: true, default: {:ok, false}}
        ]
      }

      op = Renderer.operation(affordance, type: "document")

      assert op["@type"] == "Operation"
      assert op["hydra:method"] == "PATCH"
      assert op["hydra:title"] == "Approve this document."

      expects = op["hydra:expects"]
      assert expects["@type"] == "Class"
      [prop] = expects["hydra:supportedProperty"]
      assert prop["@type"] == "SupportedProperty"
      assert prop["hydra:property"]["@id"] == "https://ash-hateoas.org/vocab#document/notify"
      assert prop["hydra:property"]["@type"] == "xsd:boolean"
      assert prop["hydra:writeable"] == true
    end

    test "allow_nil? inverts to hydra:required at the edge" do
      required = Renderer.supported_property(%Field{name: :title, type: "string", allow_nil?: false})
      optional = Renderer.supported_property(%Field{name: :body, type: "string", allow_nil?: true})

      assert required["hydra:required"] == true
      assert optional["hydra:required"] == false
    end

    test "a sensitive field's default never reaches the wire" do
      # :error is the descriptor's marker for "no default may be emitted".
      sensitive = Renderer.supported_property(%Field{name: :signing_key, type: "string", default: :error})
      plain = Renderer.supported_property(%Field{name: :notify, type: "boolean", default: {:ok, false}})

      refute Map.has_key?(sensitive, "ah:default")
      assert plain["ah:default"] == false
    end

    test "an enum constraint is carried and JSON-encodable" do
      prop =
        Renderer.supported_property(%Field{
          name: :visibility,
          type: "string",
          constraints: %{enum: [:public, :private]}
        })

      assert prop["ah:constraints"] == %{"enum" => ["public", "private"]}
      assert {:ok, _} = Jason.encode(prop)
    end
  end

  describe "IriTemplate for query reads" do
    test "a GET affordance with fields becomes an IriTemplate, not an expects Class" do
      affordance = %Affordance{
        name: :search,
        href: "/documents/search",
        method: :get,
        fields: [%Field{name: :query, type: "string", allow_nil?: false}]
      }

      op = Renderer.operation(affordance, type: "document")
      template = op["hydra:expects"]

      assert template["@type"] == "IriTemplate"
      assert template["hydra:template"] == "/documents/search{?query}"
      [mapping] = template["hydra:mapping"]
      assert mapping["@type"] == "IriTemplateMapping"
      assert mapping["hydra:variable"] == "query"
      assert mapping["hydra:required"] == true
    end
  end

  describe "operation placement (href vs node @id)" do
    setup do
      approve = %Affordance{name: :approve, href: "/documents/:id/approve", method: :patch, fields: []}
      update = %Affordance{name: :update, href: "/documents/:id", method: :patch, fields: []}
      %{approve: approve, update: update}
    end

    test "same-URL operation attaches inline; named sub-action becomes a link node", ctx do
      out =
        Renderer.render(%{approve: ctx.approve, update: ctx.update},
          node_id: "/documents/123",
          path_params: %{"id" => "123"},
          type: "document"
        )

      # update's href == node @id -> inline hydra:operation
      assert [inline_op] = out["hydra:operation"]
      assert inline_op["hydra:method"] == "PATCH"

      # approve's href differs -> a link node carrying the distinct URL
      link = out["ah:approve"]
      assert link["@id"] == "/documents/123/approve"
      assert [%{"@type" => "Operation"}] = link["hydra:operation"]
    end

    test "prefix is prepended to hrefs", ctx do
      out =
        Renderer.render(%{approve: ctx.approve},
          node_id: "/api/documents/123",
          path_params: %{"id" => "123"},
          prefix: "/api"
        )

      assert out["ah:approve"]["@id"] == "/api/documents/123/approve"
    end

    test "the whole envelope survives Jason encoding", ctx do
      out = Renderer.render(%{approve: ctx.approve, update: ctx.update}, node_id: "/documents/123")
      assert {:ok, _} = Jason.encode(out)
    end
  end
end
