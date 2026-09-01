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

      # Two types, and the second is what separates this operation from every
      # other. `Operation` alone is carried by all of them, so what used to do
      # the separating was `ah:action`, a bare string — undereferenceable,
      # unsubclassable, and local to this API.
      assert op["@type"] == ["Operation", "https://ash-hateoas.org/vocab#Document/approveAction"]
      assert op["hydra:method"] == "PATCH"
      assert op["hydra:title"] == "Approve this document."

      # The name it replaces is gone; the class is minted from it, so the
      # mapping is mechanical.
      refute Map.has_key?(op, "ah:action")

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
      assert prop["hydra:writable"] == true
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

    test "a declared role is an axiom in the ontology, not a key on the operation" do
      # `schema:potentialAction` said the operation *has* an action.
      # `@type` says it **is** one, which is the accurate reading: the node is
      # the offer to act, not a thing with an action attached — and
      # `schema:potentialAction` is defined with domain `Thing` and range
      # `Action`, which makes an `Operation` an awkward subject for it.
      #
      # The declared role survives as `rdfs:subClassOf` on the minted class,
      # where it is stated once for the API rather than repeated on every offer.
      # `ontology_test.exs` asserts that end.
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

      refute Map.has_key?(op, "schema:potentialAction")
      assert op["@type"] == ["Operation", "https://ash-hateoas.org/vocab#Order/confirmAction"]
    end

    test "no HTTP method infers anything — the class comes from the action" do
      # The rule the removed `schema:potentialAction` was written to keep, and
      # this keeps it: a role a method already implies states nothing, so
      # nothing here is derived from the verb. Four methods, one action name,
      # one class.
      for method <- [:get, :post, :patch, :delete] do
        op =
          Renderer.operation(%Affordance{name: :x, href: "/x", method: method, fields: []},
            type: "document"
          )

        assert op["@type"] == ["Operation", "https://ash-hateoas.org/vocab#Document/xAction"],
               "#{method} changed the operation's class"

        refute Map.has_key?(op, "schema:potentialAction")
      end
    end

    test "two actions sharing a method get different classes" do
      # What the method cannot do and the action name can. Both are PATCH
      # returning the same class, so `hydra:method` separates nothing.
      approve = %Affordance{name: :approve, href: "/d/:id/approve", method: :patch, fields: []}
      archive = %Affordance{name: :archive, href: "/d/:id/archive", method: :patch, fields: []}

      assert Renderer.operation(approve, type: "document")["@type"] !=
               Renderer.operation(archive, type: "document")["@type"]
    end

    test "with no resource type there is no vocabulary to mint under" do
      # The honest fallback: the bare Hydra type, rather than a class IRI
      # invented from nothing.
      op = Renderer.operation(%Affordance{name: :x, href: "/x", method: :get, fields: []})

      assert op["@type"] == "Operation"
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

      # `@list`, not a bare array. `sh:in` takes an `rdf:List`, and a plain
      # JSON-LD array is an unordered *set* that expands to one independent
      # triple per value rather than a `rdf:first`/`rdf:rest` chain — an
      # ill-formed shape, which SHACL §3.4.2 says a processor SHOULD fail the
      # whole graph over rather than skip.
      assert prop["sh:in"] == %{"@list" => ["public", "private"]}
      assert {:ok, _} = Jason.encode(prop)
    end

    test "an enum's values keep their declared order" do
      # A consequence of `@list` worth pinning: a set has no order, so a client
      # rendering a choice would get whatever order the store returned.
      prop =
        Renderer.supported_property(%Field{
          name: :size,
          type: "string",
          constraints: %{enum: [:small, :medium, :large]}
        })

      assert prop["sh:in"]["@list"] == ["small", "medium", "large"]
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
          node_id: "/documents/1",
          type: "document"
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
          node_id: "/documents/1",
          type: "document"
        )

      [perm] = out["odrl:permission"]
      [duty] = perm["odrl:duty"]
      assert duty["@type"] == "odrl:Duty"
      assert duty["odrl:action"] == %{"@id" => "odrl:obtainConsent"}
    end

    test "a sub-action's permission targets the sub-action's URL, not the record" do
      # The asset is what the request is sent to. Targeting the record would
      # grant `odrl:modify` on the record itself, when what was granted is one
      # named transition on it — and with the operations flat, the target is
      # what tells two permissions sharing an ODRL action term apart.
      out =
        Renderer.render(
          %{
            update: %Affordance{name: :update, href: "/documents/1", method: :patch, fields: []},
            publish: %Affordance{
              name: :publish,
              href: "/documents/1/publish",
              method: :patch,
              fields: []
            }
          },
          node_id: "/documents/1",
          type: "document"
        )

      targets =
        out["odrl:permission"] |> Enum.map(& &1["odrl:target"]["@id"]) |> Enum.sort()

      assert targets == ["/documents/1", "/documents/1/publish"]
    end

    test "a permission names the affordance it is about, so the two lists join" do
      # ODRL's action vocabulary is five terms wide, so `update` and `publish`
      # are both `odrl:modify` and the ODRL term alone cannot say which
      # operation a duty belongs to. `odrl:target` separates a sub-action from
      # the record, and nothing separates two operations on the record itself.
      out =
        Renderer.render(
          %{
            read: %Affordance{name: :read, href: "/documents/1", method: :get, fields: []},
            update: %Affordance{name: :update, href: "/documents/1", method: :patch, fields: []}
          },
          node_id: "/documents/1",
          type: "document"
        )

      by_action =
        Map.new(out["odrl:permission"], &{&1["ah:action"]["@id"], &1["odrl:action"]["@id"]})

      assert by_action == %{
               "https://ash-hateoas.org/vocab#Document/readAction" => "odrl:read",
               "https://ash-hateoas.org/vocab#Document/updateAction" => "odrl:modify"
             }

      # And it is the very IRI the operation carries in its `@type`, so a join
      # is a lookup rather than a convention two parties happen to share.
      assert out["hydra:operation"]
             |> Enum.map(fn op -> Enum.at(op["@type"], 1) end)
             |> Enum.sort() == Enum.sort(Map.keys(by_action))
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

    test "a router placeholder becomes a template variable" do
      # `:id` is Plug's spelling; RFC 6570 wants `{id}`. Left as-is, a client
      # expanding the template gets a URL with a literal `:id` in the path —
      # verified against a URI Template expander, which happily produces
      # `/documents/:id/related?query=q`.
      #
      # This only arises in the ApiDocumentation, which describes a *class*. On
      # a served node the affordance was built for one record, so the
      # placeholder is already substituted with that record's id.
      affordance = %Affordance{
        name: :related,
        href: "/documents/:id/related",
        method: :get,
        fields: [%Field{name: :query, type: "string", allow_nil?: false}]
      }

      template = Renderer.operation(affordance, type: "document")["hydra:expects"]

      assert template["hydra:template"] == "/documents/{id}/related{?query}"
      refute template["hydra:template"] =~ ":id"
    end

    test "a path variable is described in the mapping, like a query one" do
      # A template naming a variable the document never describes leaves a
      # client to guess what to put there. Required, always: a path segment
      # cannot be omitted the way a query parameter can.
      affordance = %Affordance{
        name: :related,
        href: "/documents/:id/related",
        method: :get,
        fields: [%Field{name: :query, type: "string", allow_nil?: false}]
      }

      template = Renderer.operation(affordance, type: "document")["hydra:expects"]
      variables = Enum.map(template["hydra:mapping"], & &1["hydra:variable"])

      assert "id" in variables
      assert "query" in variables

      id_mapping = Enum.find(template["hydra:mapping"], &(&1["hydra:variable"] == "id"))
      assert id_mapping["hydra:required"] == true
      assert id_mapping["hydra:property"]["@id"] =~ "document/id"
    end
  end

  describe "where an operation is invoked (ah:href, always)" do
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

    # An operation is found by its class, which is the only thing that
    # identifies it now.
    defp by_action(out, name) do
      iri = AshHateoas.Hydra.Context.action_class_iri("document", name)
      Enum.find(out["hydra:operation"], &(iri in List.wrap(&1["@type"])))
    end

    test "every affordance is one entry in hydra:operation", ctx do
      out =
        Renderer.render(%{approve: ctx.approve, update: ctx.update},
          node_id: "/documents/123",
          path_params: %{"id" => "123"},
          type: "document"
        )

      # One array, one traversal. Answering "what may I invoke here?" is reading
      # `hydra:operation` and nothing else — no walking data-driven keys for
      # objects that happen to wrap an operation.
      assert out["hydra:operation"]
             |> Enum.map(fn op -> Enum.at(op["@type"], 1) end)
             |> Enum.sort() == [
               "https://ash-hateoas.org/vocab#Document/approveAction",
               "https://ash-hateoas.org/vocab#Document/updateAction"
             ]

      refute Map.has_key?(out, "ah:approve")
    end

    test "an operation on the node's own URL states it anyway", ctx do
      out =
        Renderer.render(%{update: ctx.update},
          node_id: "/documents/123",
          path_params: %{"id" => "123"},
          type: "document"
        )

      # Writing it only for a sub-action left this case resting on a rule the
      # document never states — "invoke against the node this hangs on" — which
      # holds only while the operation is still attached to that node. Lift one
      # out to log or queue it and it no longer says where it goes.
      assert by_action(out, "update")["ah:href"] == %{"@id" => "/documents/123"}
    end

    test "every operation carries one, whatever its URL", ctx do
      out =
        Renderer.render(%{approve: ctx.approve, update: ctx.update},
          node_id: "/documents/123",
          path_params: %{"id" => "123"},
          type: "document"
        )

      assert Enum.all?(out["hydra:operation"], &Map.has_key?(&1, "ah:href")),
             "an operation that does not say where it goes is not invocable on its own"
    end

    test "a named sub-action carries its own URL as ah:href", ctx do
      out =
        Renderer.render(%{approve: ctx.approve},
          node_id: "/documents/123",
          path_params: %{"id" => "123"},
          type: "document"
        )

      assert by_action(out, "approve")["ah:href"] == %{"@id" => "/documents/123/approve"}
    end

    test "ah:href is a node reference, not a string", ctx do
      # `{"@id": …}` rather than a bare literal: the value is the resource the
      # request is sent to, so it has to expand to an edge. A string would
      # expand to a literal and a consumer would have a URL-shaped label.
      out =
        Renderer.render(%{approve: ctx.approve}, node_id: "/documents/123", type: "document")

      assert %{"@id" => href} = by_action(out, "approve")["ah:href"]
      assert is_binary(href)
    end

    test "prefix is prepended to an ah:href", ctx do
      out =
        Renderer.render(%{approve: ctx.approve},
          node_id: "/api/documents/123",
          path_params: %{"id" => "123"},
          prefix: "/api",
          type: "document"
        )

      assert by_action(out, "approve")["ah:href"] == %{"@id" => "/api/documents/123/approve"}
    end

    test "an affordance with no href of its own takes the node's", ctx do
      # The fallback path: nothing was derived, so the node URL is the answer —
      # and it is written down rather than left to be inferred.
      bare = %Affordance{name: :run, href: nil, method: :post, fields: []}

      out =
        Renderer.render(%{run: bare, update: ctx.update},
          node_id: "/documents/123",
          type: "document"
        )

      assert by_action(out, "run")["ah:href"] == %{"@id" => "/documents/123"}
    end

    test "with neither a derived href nor a node URL, nothing is invented" do
      # The `ApiDocumentation`'s case: it describes a class rather than a
      # record, so there is no instance to invoke anything against, and a
      # template URL would be a different statement.
      op = Renderer.operation(%Affordance{name: :x, href: nil, method: :get, fields: []})

      refute Map.has_key?(op, "ah:href")
    end

    test "the whole envelope survives Jason encoding", ctx do
      out =
        Renderer.render(%{approve: ctx.approve, update: ctx.update},
          node_id: "/documents/123",
          type: "document"
        )

      assert {:ok, _} = Jason.encode(out)
    end
  end

  describe "a node states what varies, and the catalogue states the rest" do
    setup do
      %{
        approve: %Affordance{
          name: :approve,
          href: "/documents/:id/approve",
          method: :post,
          fields: []
        },
        update: %Affordance{name: :update, href: "/documents/:id", method: :patch, fields: []}
      }
    end

    test "an operation on a node carries @type and ah:href only", ctx do
      out =
        Renderer.render(%{approve: ctx.approve, update: ctx.update},
          node_id: "/documents/123",
          type: "document"
        )

      for op <- out["hydra:operation"] do
        assert Enum.sort(Map.keys(op)) == ["@type", "ah:href"]
      end
    end

    test "the two it keeps are the two that vary" do
      # Which operations are present is decided per actor and per state, and each
      # one's URL holds the record's id. Everything else — the method, the input,
      # the return, the title — is read off the *action*, so it reads the same
      # for every record of the class and every actor who may invoke it.
      one =
        Renderer.render(
          %{approve: %Affordance{name: :approve, href: "/documents/1/approve", method: :post}},
          node_id: "/documents/1",
          type: "document"
        )

      two =
        Renderer.render(
          %{approve: %Affordance{name: :approve, href: "/documents/2/approve", method: :post}},
          node_id: "/documents/2",
          type: "document"
        )

      [%{"@type" => first_type, "ah:href" => first_href}] = one["hydra:operation"]
      [%{"@type" => second_type, "ah:href" => second_href}] = two["hydra:operation"]

      # Same operation, different record: the class is the constant a client
      # looks the shape up by, the href is what changed.
      assert first_type == second_type
      refute first_href == second_href
    end

    test "the full shape is still built, for the document that states it once", ctx do
      # `operation/2` did not go away with the thinning — it is what the
      # `ApiDocumentation` calls, and it is where a node would restate a shape if
      # an application ever narrowed one for a single state. The rule is "the
      # catalogue states the shape; a node may restate it", not "a node never
      # does".
      op = Renderer.operation(ctx.approve, type: "document")

      assert op["hydra:method"] == "POST"
      assert op["hydra:returns"]["@id"] =~ "#Document"
      assert op["hydra:expects"]["@id"] =~ "#Document/approveInput"
    end
  end

  describe "an omitted hydra:expects is not a statement" do
    test "a fieldless write declares an empty input class rather than nothing" do
      # "These are the properties, and there are none" is a statement. Absence is
      # not: a client could not tell "send an empty body" from "this document
      # does not describe the body", and for a write that is a guess about a
      # write.
      op =
        Renderer.operation(
          %Affordance{name: :open_sitting, href: "/exams/1/open_sitting", method: :post},
          type: "exam"
        )

      assert op["hydra:expects"] == %{
               "@id" => "https://ash-hateoas.org/vocab#Exam/open_sittingInput",
               "@type" => "Class",
               "hydra:supportedProperty" => []
             }
    end

    test "it is a class with no properties, never owl:Nothing" do
      # `put_returns/3` reserves `owl:Nothing` for a response with no body, and
      # the two directions are not symmetric: `hydra:expects owl:Nothing` says an
      # instance of the empty class is expected, which is unsatisfiable — "no
      # valid request to this operation exists". An empty body is a perfectly
      # valid request.
      op =
        Renderer.operation(%Affordance{name: :x, href: "/x/1/y", method: :post}, type: "thing")

      refute op["hydra:expects"]["@id"] == "owl:Nothing"
      assert op["hydra:expects"]["hydra:supportedProperty"] == []
    end

    test "a GET and a DELETE are left alone, because silence there is unambiguous" do
      # RFC 9110 says a client should not generate content in a GET, and a DELETE
      # body has no defined semantics. Stating an empty input class for either
      # would describe a request nobody should send.
      get =
        Renderer.operation(%Affordance{name: :read, href: "/x/1", method: :get}, type: "thing")

      delete =
        Renderer.operation(%Affordance{name: :destroy, href: "/x/1", method: :delete},
          type: "thing"
        )

      refute Map.has_key?(get, "hydra:expects")
      refute Map.has_key?(delete, "hydra:expects")
    end

    test "a DELETE that takes arguments still describes them" do
      # Otherwise a client could not send what the action requires. The rule is
      # about *silence* being ambiguous, not about DELETE never carrying input.
      op =
        Renderer.operation(
          %Affordance{
            name: :destroy,
            href: "/x/1",
            method: :delete,
            fields: [%AshHateoas.Field{name: :reason, type: "string", allow_nil?: false}]
          },
          type: "thing"
        )

      assert [%{"hydra:title" => "reason"}] = op["hydra:expects"]["hydra:supportedProperty"]
    end
  end
end
