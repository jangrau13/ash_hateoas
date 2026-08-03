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

      # The action's own name, which is what lets a client match a live offer
      # on a node against the operation the documentation describes — and what
      # labels a button, since "PATCH" cannot.
      assert op["ah:action"] == "approve"

      # a write returns the resource's own class
      assert op["hydra:returns"] == %{"@id" => "https://ash-hateoas.org/vocab#Document"}

      expects = op["hydra:expects"]
      assert expects["@type"] == "Class"
      # the expected input class is referenceable (has its own @id), not a blank node
      assert expects["@id"] == "https://ash-hateoas.org/vocab#Document/approveInput"

      [prop] = expects["hydra:supportedProperty"]
      assert prop["@type"] == "SupportedProperty"
      # hydra:property ranges over rdf:Property -> a reference, {"@id": iri}
      assert prop["hydra:property"] == %{"@id" => "https://ash-hateoas.org/vocab#document/notify"}
      # the value's datatype rides alongside, not on the property reference
      assert prop["sh:datatype"] == "xsd:boolean"
      assert prop["hydra:writeable"] == true
    end

    test "allow_nil? inverts to hydra:required at the edge" do
      required =
        Renderer.supported_property(%Field{name: :title, type: "string", allow_nil?: false})

      optional =
        Renderer.supported_property(%Field{name: :body, type: "string", allow_nil?: true})

      assert required["hydra:required"] == true
      assert optional["hydra:required"] == false
    end

    test "a sensitive field's default never reaches the wire" do
      # :error is the descriptor's marker for "no default may be emitted".
      sensitive =
        Renderer.supported_property(%Field{name: :signing_key, type: "string", default: :error})

      plain =
        Renderer.supported_property(%Field{name: :notify, type: "boolean", default: {:ok, false}})

      refute Map.has_key?(sensitive, "sh:defaultValue")
      assert plain["sh:defaultValue"] == false
    end

    test "an operation carries a schema:potentialAction typed by its HTTP method" do
      approve = %Affordance{
        name: :approve,
        href: "/documents/:id/approve",
        method: :patch,
        fields: []
      }

      op = Renderer.operation(approve, type: "document", path_params: %{"id" => "7"})
      action = op["schema:potentialAction"]

      # a PATCH infers UpdateAction
      assert action["@type"] == "schema:UpdateAction"
      target = action["schema:target"]
      assert target["schema:httpMethod"] == "PATCH"
      assert target["schema:urlTemplate"] == "/documents/7/approve"
      assert target["schema:contentType"] == "application/ld+json"
    end

    test "each HTTP method maps to its schema.org Action subtype" do
      for {method, type} <- [
            {:get, "schema:ReadAction"},
            {:post, "schema:CreateAction"},
            {:patch, "schema:UpdateAction"},
            {:delete, "schema:DeleteAction"}
          ] do
        op = Renderer.operation(%Affordance{name: :x, href: "/x", method: method, fields: []})
        assert op["schema:potentialAction"]["@type"] == type
      end
    end

    test "a semantic_action override wins over the method-inferred subtype" do
      confirm = %Affordance{
        name: :confirm,
        href: "/orders/:id/confirm",
        method: :patch,
        fields: []
      }

      op =
        Renderer.operation(confirm,
          type: "order",
          semantic_actions: %{confirm: "https://schema.org/ConfirmAction"}
        )

      # the override is used verbatim, not the inferred UpdateAction
      assert op["schema:potentialAction"]["@type"] == "https://schema.org/ConfirmAction"
    end

    test "a destroy returns the record it destroyed" do
      destroy = %Affordance{name: :destroy, href: "/documents/:id", method: :delete, fields: []}
      op = Renderer.operation(destroy, type: "document")

      # Not `owl:Nothing`. The plug asks Ash for the destroyed record
      # (`return_destroyed?: true`) and renders its final state, so a client can
      # show what it deleted without having fetched it first.
      assert op["hydra:returns"] == %{"@id" => "https://ash-hateoas.org/vocab#Document"}
    end

    test "without a resource type, expects has no @id and returns is omitted" do
      affordance = %Affordance{
        name: :approve,
        href: "/x",
        method: :patch,
        fields: [%Field{name: :notify, type: "boolean", allow_nil?: true}]
      }

      op = Renderer.operation(affordance)

      refute Map.has_key?(op, "hydra:returns")
      refute Map.has_key?(op["hydra:expects"], "@id")
    end

    test "an enum constraint is carried and JSON-encodable" do
      prop =
        Renderer.supported_property(%Field{
          name: :visibility,
          type: "string",
          constraints: %{enum: [:public, :private]}
        })

      assert prop["sh:in"] == ["public", "private"]
      assert {:ok, _} = Jason.encode(prop)
    end

    test "a union field emits schema:rangeIncludes with member type IRIs" do
      prop =
        Renderer.supported_property(%Field{
          name: :content,
          type: "union",
          constraints: %{union_types: [text: "string", number: "integer"]}
        })

      assert prop["schema:rangeIncludes"] == [
               %{"@id" => "xsd:string"},
               %{"@id" => "xsd:integer"}
             ]
    end

    test "a link field emits sh:nodeKind IRI" do
      prop =
        Renderer.supported_property(%Field{
          name: :related,
          type: "link"
        })

      assert prop["sh:nodeKind"] == "sh:IRI"
    end

    test "an array field emits rdfs:range pointing to jsonschema:ArraySchema" do
      prop =
        Renderer.supported_property(%Field{
          name: :tags,
          type: "array"
        })

      assert prop["rdfs:range"] == %{"@id" => "jsonschema:ArraySchema"}
    end

    test "a map field emits rdfs:range pointing to jsonschema:ObjectSchema" do
      prop =
        Renderer.supported_property(%Field{
          name: :metadata,
          type: "map"
        })

      assert prop["rdfs:range"] == %{"@id" => "jsonschema:ObjectSchema"}
    end

    test "a scalar field now emits sh:datatype instead of ah:datatype" do
      prop =
        Renderer.supported_property(%Field{
          name: :title,
          type: "string"
        })

      assert prop["sh:datatype"] == "xsd:string"
      refute Map.has_key?(prop, "ah:datatype")
    end
  end

  describe "ODRL permissions (the granted set as a policy)" do
    test "the granted affordances render as an odrl:permission list, keyed by action" do
      out =
        Renderer.render(
          %{
            read: %Affordance{name: :read, href: "/documents/1", method: :get, fields: []},
            update: %Affordance{name: :update, href: "/documents/1", method: :patch, fields: []},
            destroy: %Affordance{
              name: :destroy,
              href: "/documents/1",
              method: :delete,
              fields: []
            }
          },
          node_id: "/documents/1"
        )

      perms = out["odrl:permission"]
      assert is_list(perms)

      actions = Enum.map(perms, & &1["odrl:action"]["@id"]) |> Enum.sort()
      assert actions == ["odrl:delete", "odrl:modify", "odrl:read"]

      # each permission targets the node it hangs on
      assert Enum.all?(perms, &(&1["odrl:target"] == %{"@id" => "/documents/1"}))
      assert Enum.all?(perms, &(&1["@type"] == "odrl:Permission"))
    end

    test "a not_delegable action carries an odrl:duty to obtainConsent" do
      out =
        Renderer.render(
          %{
            publish: %Affordance{
              name: :publish,
              href: "/documents/1/publish",
              method: :patch,
              fields: [],
              not_delegable?: true
            }
          },
          node_id: "/documents/1"
        )

      [perm] = out["odrl:permission"]
      [duty] = perm["odrl:duty"]
      assert duty["@type"] == "odrl:Duty"
      assert duty["odrl:action"] == %{"@id" => "odrl:obtainConsent"}
    end

    test "an empty envelope carries no odrl:permission" do
      refute Map.has_key?(Renderer.render(%{}, node_id: "/x"), "odrl:permission")
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
      approve = %Affordance{
        name: :approve,
        href: "/documents/:id/approve",
        method: :patch,
        fields: []
      }

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
      out =
        Renderer.render(%{approve: ctx.approve, update: ctx.update}, node_id: "/documents/123")

      assert {:ok, _} = Jason.encode(out)
    end
  end
end
