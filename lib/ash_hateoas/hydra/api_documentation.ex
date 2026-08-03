defmodule AshHateoas.Hydra.ApiDocumentation do
  @moduledoc """
  Builds the `hydra:ApiDocumentation` — the machine-readable description of the
  API a generic client discovers first (via the `Link` header) and dereferences
  to learn the API's classes, their properties, and their operations.

  Everything here is derived from what the resources already declare, per R1:

    * `hydra:entrypoint` — the API's base URL.
    * `hydra:supportedClass` — one `hydra:Class` per resource carrying the
      extension, with `hydra:supportedProperty` from its public attributes and
      `hydra:supportedOperation` from its derived routes. A resource that
      declares a well-known (e.g. schema.org) type yields a **second** class
      entry keyed by that IRI too — mirroring the record node's dual `@type`, so
      a client indexing by either IRI finds a described class.

  ## Catalogue vs. availability

  `supportedOperation` describes the operations a class *supports* — their
  method, expected input and returned type. It is actor-independent and asserts
  no availability: whether an operation may be invoked *now*, on *this* record,
  by *this* actor is answered by the per-node `hydra:operation` the backbone
  gates. The documentation is the stable catalogue; the node is the live offer.
  """

  alias AshHateoas.Hydra.{Context, Ontology, Renderer, TypeMapper}
  alias AshHateoas.{Index, Route}

  @doc """
  Build the full `ApiDocumentation` document for `domains`.

  ## Options

    * `:entrypoint` — the API base URL (`hydra:entrypoint`).
    * `:id` — the document's own `@id` (its URL, e.g. `/doc`).
  """
  @spec build([module()], keyword()) :: map()
  def build(domains, opts \\ []) do
    classes =
      domains
      |> Index.build()
      |> Enum.sort_by(fn {type, _resource} -> type end)
      |> Enum.flat_map(fn {type, resource} -> supported_classes(resource, type) end)

    report = validation_report(classes)

    # The report classes derive from no resource, so the ontology's own walk
    # never reaches their properties. They are declared alongside the classes
    # they belong to — together or not at all.
    report_declarations =
      if report == [], do: [], else: Ontology.report_properties()

    %{
      "@context" => Context.context(),
      "@type" => "ApiDocumentation",
      # The vocabulary this document uses, declared in the document that uses
      # it. `@included` puts these node objects' triples in the default graph
      # while asserting nothing about the ApiDocumentation itself, so one fetch
      # gets both the affordances and the ontology behind them.
      "@included" => Ontology.build(domains) ++ report_declarations,
      "hydra:supportedClass" => classes ++ report
    }
    |> put_unless_nil("@id", Keyword.get(opts, :id))
    |> put_unless_nil("hydra:entrypoint", Keyword.get(opts, :entrypoint))
  end

  # The class a document action returns, described rather than merely named.
  #
  # Not derived from a resource, because it is not one: it has no table, no
  # identity and no routes — it is the shape of a response. But naming a class
  # in `hydra:returns` and describing it nowhere is the same defect this
  # documentation has for properties, so it is described here.
  #
  # Emitted only when something returns it. A domain with no document action has
  # no use for the term, and a class nothing references is noise.
  defp validation_report(classes) do
    if Enum.any?(classes, &returns_report?/1) do
      [
        %{
          "@id" => Context.vocab_iri("ValidationReport"),
          "@type" => "Class",
          "hydra:title" => "ValidationReport",
          "hydra:description" =>
            "The result of checking a document: whether it is valid, and one entry per problem found.",
          "hydra:supportedProperty" => [
            report_property("valid?", "validationReport", "xsd:boolean", nil, [
              "Whether the document passed every check."
            ]),
            # `sh:class` names the member class, the same term a link property
            # uses for its target. `rdfs:range` alone would say "an array" and
            # stop there, leaving the entry shape to be read from prose — which
            # is the defect this documentation exists to remove, one level down.
            report_property(
              "errors",
              "validationReport",
              "jsonschema:ArraySchema",
              Context.vocab_iri("ValidationError"),
              ["One entry per problem. Empty when valid."]
            )
          ]
        },
        %{
          "@id" => Context.vocab_iri("ValidationError"),
          "@type" => "Class",
          "hydra:title" => "ValidationError",
          "hydra:description" => "One problem found in a document.",
          "hydra:supportedProperty" => [
            report_property("index", "validationError", "xsd:integer", nil, [
              "Position of the offending element in the submitted document. ",
              "Null for a problem belonging to the document as a whole."
            ]),
            report_property("kind", "validationError", "xsd:string", nil, [
              "The element's declared kind, as submitted. Null when it named none."
            ]),
            report_property("name", "validationError", "xsd:string", nil, [
              "The element's name, so a client can locate it when positions have shifted."
            ]),
            report_property("field", "validationError", "xsd:string", nil, [
              "The property the problem concerns. Null for a problem belonging to ",
              "the whole element."
            ]),
            report_property("message", "validationError", "xsd:string", nil, [
              "A human-readable description of the problem. Always present."
            ])
          ]
        }
      ]
    else
      []
    end
  end

  defp returns_report?(class) do
    class
    |> Map.get("hydra:supportedOperation", [])
    |> List.wrap()
    |> Enum.any?(&(get_in(&1, ["hydra:returns", "@id"]) == Context.vocab_iri("ValidationReport")))
  end

  defp report_property(name, owner, range, member_class, description) do
    %{
      "@type" => "SupportedProperty",
      "hydra:property" => %{"@id" => Context.property_iri(owner, name)},
      "hydra:title" => name,
      "hydra:description" => Enum.join(description),
      "hydra:readable" => true,
      "hydra:writeable" => false,
      "rdfs:range" => %{"@id" => range}
    }
    |> put_unless_nil("sh:class", member_class && %{"@id" => member_class})
  end

  # A resource yields its own `vocab#` class, and — when it declares a well-known
  # (e.g. schema.org) type — a companion class keyed by that IRI too. A record
  # node is dual-typed `[vocab#Class, schema:Class]`, so a client indexing the
  # documentation by *either* IRI must find a fully-described class; the companion
  # is that second entry.
  #
  # The companion is a *description* keyed by the well-known IRI, not a claim
  # about it. It used to carry `owl:equivalentClass` back to the local class,
  # which asserted the two are the same set — almost never true, since a local
  # Person has an id, a tenant and domain rules `schema:Person` knows nothing
  # of. Worse, equivalence licenses substitution both ways, so a reasoner could
  # conclude things about schema.org's class from statements about ours.
  #
  # The honest relation is `rdfs:subClassOf`, and it is asserted once in the
  # ontology block rather than twice here. See `AshHateoas.Hydra.Ontology`.
  defp supported_classes(resource, type) do
    case AshHateoas.Resource.Info.semantic_type(resource) do
      nil ->
        [supported_class(resource, type)]

      semantic_type ->
        primary = supported_class(resource, type)
        companion = Map.put(primary, "@id", semantic_type)

        [primary, companion]
    end
  end

  @doc "Build one `hydra:Class` for a resource."
  @spec supported_class(module(), String.t()) :: map()
  def supported_class(resource, type) do
    %{
      "@id" => Context.class_iri(type),
      "@type" => "Class",
      "hydra:title" => type,
      "hydra:supportedProperty" => supported_properties(resource, type),
      "hydra:supportedOperation" => supported_operations(resource, type)
    }
    |> put_unless_nil("hydra:description", description(resource))
    |> put_unless_nil("ah:identity", identities(resource))
  end

  # Which properties identify a record, besides its primary key.
  #
  # A resource declares this — `identity :unique_name, [:name]` — and until now
  # it stayed on the Elixir side. Without it a client has no way to know what
  # names a record, so it is left guessing from convention: is the key `name`,
  # `title`, `slug`, `code`? A guess that is merely *usually* right is worse
  # than no answer, because it fails silently on the domain that names things
  # differently.
  #
  # It matters most to a client that edits: an update has to match the record
  # the author meant, and matching on a guessed key matches the wrong record or
  # none. `Ash.Changeset.manage_relationship/4` already keys on exactly these
  # (`use_identities`), so publishing them is what lets a client agree with the
  # server rather than coincide with it.
  #
  # ## Why an `ah:` term rather than a standard one
  #
  # No published vocabulary says "these properties are the natural key of this
  # class" without dragging something else along:
  #
  #   * SHACL has no key concept at all — it constrains values, not identity.
  #   * Hydra has none.
  #   * Dublin Core is descriptive: `dcterms:identifier` is an identifier's
  #     *value* on an instance (an ISBN), not which property keys a class.
  #   * `csvw:primaryKey` has exactly the right meaning but a domain of
  #     `csvw:Schema`/`csvw:Row`, so putting it on a `hydra:Class` misuses it.
  #   * `dash:PrimaryKeyConstraintComponent` implies a URI-construction policy
  #     (`dash:uriStart`) this says nothing about.
  #   * `owl:hasKey` states a nearby fact — no two named instances of a class
  #     coincide on these properties — but as a *reasoning axiom*: it licenses
  #     an inference engine to conclude two records are the same individual and
  #     merge them. A client needs "match the record with this name", which is
  #     nearly the opposite.
  #
  # So the term is declared in `AshHateoas.Hydra.Ontology` as an
  # `owl:AnnotationProperty`, deliberately **not** a subproperty of
  # `owl:hasKey`. It was one until this change, and the claim was unsound twice
  # over: `owl:hasKey` is a class axiom taking an `rdf:List`, so it cannot sit
  # on a property node at all; and since `ah:identity` names a *business* key, a
  # domain where two records legitimately share a name would have them merged
  # and their properties unioned — the corruption the term exists to prevent.
  #
  # What it actually means is "unique within its parent" — scoped uniqueness,
  # which OWL cannot express.
  #
  # A composite identity keys on several properties at once, so each entry is
  # itself a list.
  defp identities(resource) do
    type = AshHateoas.Resource.Info.type(resource)

    resource
    |> Ash.Resource.Info.identities()
    |> Enum.reject(&(&1.keys == [] or has_private_key?(resource, &1)))
    |> Enum.map(fn identity ->
      Enum.map(identity.keys, &%{"@id" => Context.property_iri(type, &1)})
    end)
    |> case do
      [] -> nil
      keys -> keys
    end
  rescue
    _ -> nil
  end

  # An identity over a private attribute is unusable by a client: the property
  # it names is never rendered, so nothing on the wire could carry the value.
  defp has_private_key?(resource, identity) do
    Enum.any?(identity.keys, fn key ->
      case Ash.Resource.Info.attribute(resource, key) do
        %{public?: true} -> false
        _ -> true
      end
    end)
  end

  @doc """
  The `hydra:SupportedProperty` list from a resource's public attributes, plus a
  `hydra:Link` property per to-many relationship the resource routes.
  """
  @spec supported_properties(module(), String.t()) :: [map()]
  def supported_properties(resource, type) do
    semantic = AshHateoas.Resource.Info.semantic_properties(resource)

    attribute_properties =
      resource
      |> public_attributes()
      |> Enum.map(fn attribute ->
        # A mapped attribute advertises the well-known property IRI directly, so a
        # client that knows the vocabulary reads the value as that property.
        property_id =
          Map.get(semantic, attribute.name) || Context.property_iri(type, attribute.name)

        wire = AshHateoas.TypeMapper.to_wire(attribute.type)

        %{
          "@type" => "SupportedProperty",
          # `hydra:property` ranges over rdf:Property — a reference to the
          # property. The value's type is a fact about the property, carried
          # alongside under a standard ontology term.
          "hydra:property" => %{"@id" => property_id},
          "hydra:title" => to_string(attribute.name),
          "hydra:required" => not Map.get(attribute, :allow_nil?, true),
          "hydra:readable" => true,
          "hydra:writeable" => Map.get(attribute, :writable?, true)
        }
        |> put_type_info(wire)
        |> put_unless_nil("hydra:description", Map.get(attribute, :description))
      end)

    attribute_properties ++ link_properties(resource, type)
  end

  # A relationship is advertised as a `hydra:Link` — its `hydra:property` is a
  # node typed `hydra:Link`, so a client knows the key on a record is a
  # followable link rather than a literal value.
  #
  # Both cardinalities are described. To-MANY comes from a routed `:related`
  # route (the link is to a collection). To-ONE has no route by design — a to-one
  # is served as an inline node reference rather than a collection route (see
  # `DeriveRelationshipRoutes`) — but it is still part of the class's shape, so
  # it belongs in the catalogue. Omitting it left roughly half the graph edges
  # undescribed, invisible to any client deriving structure from the
  # documentation.
  #
  # Each link carries `sh:class`: the IRI of the class it points AT. Without it
  # a link says only "this is followable", never "→ what", which is not enough
  # for a client to resolve the reference to a described class.
  defp link_properties(resource, type) do
    routed = MapSet.new(routes(resource), fn %Route{} = route -> route.relationship end)

    to_many =
      resource
      |> routes()
      |> Enum.filter(&(&1.type == :related))
      |> Enum.map(&link_property(resource, type, &1.relationship, "Collection"))

    # Public to-one relationships, which are never routed.
    to_one =
      resource
      |> Ash.Resource.Info.public_relationships()
      |> Enum.filter(&(&1.cardinality == :one and &1.name not in routed))
      |> Enum.map(&link_property(resource, type, &1.name, nil))

    to_many ++ to_one
  end

  # One `hydra:Link` property. `target_kind` is `"Collection"` for a to-many
  # link (it resolves to a `hydra:Collection` of the destination) and `nil` for
  # a to-one (it resolves to a single node of the destination class).
  defp link_property(resource, type, name, target_kind) do
    property =
      %{
        "@id" => Context.property_iri(type, name),
        "@type" => "hydra:Link"
      }
      |> put_unless_nil("sh:class", link_target_class(resource, name))

    %{
      "@type" => "SupportedProperty",
      "hydra:property" => property,
      "hydra:title" => to_string(name),
      "hydra:readable" => true,
      "hydra:writeable" => false
    }
    |> put_unless_nil("ah:targetKind", target_kind)
  end

  # The class IRI a relationship points at, from the destination's own declared
  # type. A destination without a type is not addressable as a node, so the link
  # is emitted without `sh:class` rather than with a bogus one — a consumer then
  # degrades to an untyped link instead of resolving to nothing.
  defp link_target_class(resource, name) do
    with %{destination: destination} <- Ash.Resource.Info.relationship(resource, name),
         destination_type when is_binary(destination_type) <-
           AshHateoas.Resource.Info.type(destination) do
      Context.class_iri(destination_type)
    else
      _ -> nil
    end
  end

  @doc """
  The `hydra:supportedOperation` list from a resource's derived routes.

  Actor-independent: it describes operation shape, not availability. Reads the
  route table directly rather than the gated backbone.
  """
  @spec supported_operations(module(), String.t()) :: [map()]
  def supported_operations(resource, type) do
    resource
    |> routes()
    |> Enum.reject(&(&1.type in [:related, :relationship]))
    |> Enum.map(fn %Route{} = route ->
      action = Ash.Resource.Info.action(resource, route.action)

      %{
        "@type" => "Operation",
        "hydra:method" => method(route, action) |> to_string() |> String.upcase(),
        # The action's own name. Hydra gives an operation no name of its own —
        # it describes *how* to invoke one, not what the domain calls it — so a
        # client is otherwise left with the HTTP method, and a class with two
        # POSTs offers two indistinguishable operations.
        #
        # It is the domain's word, and the only thing that can label a button:
        # `approve` and `archive` are what an author recognises, where "POST"
        # and "POST" are not. It also lets a client find an operation by name
        # rather than by guessing from a URL, which is what makes an affordance
        # addressable at all.
        "ah:action" => to_string(route.action)
      }
      |> put_unless_nil("hydra:title", action && Map.get(action, :description))
      |> put_shape(action, resource, type)
      |> put_possible_status(route, action, resource)
    end)
  end

  # The statuses an operation may return, derived from the gate chain — the
  # catalogue counterpart to the node's live gating. A resource with authorizers
  # can refuse with 403; a write can fail validation with 422; a member-targeted
  # operation can 404. Actor-independent: it lists what *could* happen, not what
  # will for a given request.
  defp put_possible_status(op, route, action, resource) do
    statuses =
      []
      |> maybe_status(authorized?(resource), 403, "Forbidden — the actor may not perform this.")
      |> maybe_status(write?(action), 422, "Unprocessable — the input failed validation.")
      |> maybe_status(member_route?(route), 404, "Not Found — no such record.")

    case statuses do
      [] -> op
      list -> Map.put(op, "hydra:possibleStatus", Enum.reverse(list))
    end
  end

  defp maybe_status(list, false, _code, _title), do: list

  defp maybe_status(list, true, code, title) do
    [%{"@type" => "Status", "hydra:statusCode" => code, "hydra:title" => title} | list]
  end

  defp authorized?(resource) do
    Ash.Resource.Info.authorizers(resource) != []
  rescue
    _ -> false
  end

  defp write?(%{type: type}) when type in [:create, :update, :destroy, :action], do: true
  defp write?(_action), do: false

  # A route addressing a specific record (`:id` in its path) can 404; a
  # collection-level route (create, index) cannot.
  defp member_route?(%Route{route: route}) when is_binary(route),
    do: String.contains?(route, ":id")

  defp member_route?(_route), do: false

  # Reuse the renderer's `expects`/`returns` derivation so the documentation
  # catalogue and the live per-node operations describe input/output identically.
  defp put_shape(op, nil, _resource, _type), do: op

  defp put_shape(op, action, resource, type) do
    rendered =
      AshHateoas.Descriptor.build(action, nil, resource)
      |> Renderer.operation(
        type: type,
        semantic_actions: AshHateoas.Resource.Info.semantic_actions(resource)
      )

    op
    |> put_unless_nil("hydra:expects", Map.get(rendered, "hydra:expects"))
    |> put_unless_nil("hydra:returns", Map.get(rendered, "hydra:returns"))
    |> put_unless_nil("schema:potentialAction", Map.get(rendered, "schema:potentialAction"))
  end

  defp method(%Route{method: method}, _action) when not is_nil(method), do: method
  defp method(%Route{type: :get}, _action), do: :get
  defp method(%Route{type: :index}, _action), do: :get
  defp method(%Route{type: :post}, _action), do: :post
  defp method(%Route{type: :patch}, _action), do: :patch
  defp method(%Route{type: :delete}, _action), do: :delete
  defp method(_route, %{type: :read}), do: :get
  defp method(_route, %{type: :create}), do: :post
  defp method(_route, %{type: :update}), do: :patch
  defp method(_route, %{type: :destroy}), do: :delete
  defp method(_route, _action), do: :post

  defp public_attributes(resource) do
    resource
    |> Ash.Resource.Info.public_attributes()
  rescue
    _ -> []
  end

  defp routes(resource) do
    AshHateoas.Resource.Info.routes(resource)
  rescue
    _ -> []
  end

  defp description(resource) do
    Ash.Resource.Info.description(resource)
  rescue
    _ -> nil
  end

  defp put_type_info(map, wire) do
    case TypeMapper.type_info(wire) do
      {:sh_datatype, iri} -> Map.put(map, "sh:datatype", iri)
      {:sh_node_kind, kind} -> Map.put(map, "sh:nodeKind", kind)
      {:rdfs_range, iri} -> Map.put(map, "rdfs:range", %{"@id" => iri})
      :union -> map
      :none -> map
    end
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
