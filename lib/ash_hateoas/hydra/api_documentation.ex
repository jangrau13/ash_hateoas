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

  alias AshHateoas.Hydra.{Context, Ontology, Renderer}
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
      "hydra:writable" => false,
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
  # about it. It carries no `owl:equivalentClass` back to the local class:
  # equivalence asserts the two are the same set, which is almost never true —
  # a local Person has an id, a tenant and domain rules `schema:Person` knows
  # nothing of — and it licenses substitution both ways, letting a reasoner
  # conclude things about schema.org's class from statements about ours.
  #
  # The relation that holds is `rdfs:subClassOf`, asserted once in the ontology
  # block rather than twice here. See `AshHateoas.Hydra.Ontology`.
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
  # `owl:hasKey`. Such a claim would be unsound twice over: `owl:hasKey` is a
  # class axiom taking an `rdf:List`, so it cannot sit on a property node at
  # all; and since `ah:identity` names a *business* key, a domain where two
  # records legitimately share a name would have them merged and their
  # properties unioned — the corruption the term exists to prevent.
  #
  # What it means is "unique within its parent" — scoped uniqueness, which OWL
  # cannot express.
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

        %{
          "@type" => "SupportedProperty",
          # `hydra:property` ranges over rdf:Property, so this is a reference to
          # the property — and only a reference.
          #
          # The value's type is a fact about the *property*, so it lives on the
          # property's own declaration in the ontology as `sh:datatype` /
          # `sh:nodeKind` / `rdfs:range` — stated once instead of at every site
          # the property is used. A consumer follows the `@id`.
          #
          # Note the same keys DO belong on an operation's **input** properties
          # (`Renderer.put_type_info/2`): an argument is not a property of any
          # class, so the ontology declares none for it, and omitting them
          # there would leave every input field untyped — collapsing boolean,
          # integer and reference alike to string.
          "hydra:property" => %{"@id" => property_id},
          "hydra:title" => to_string(attribute.name),
          "hydra:required" => not Map.get(attribute, :allow_nil?, true),
          "hydra:readable" => true,
          "hydra:writable" => Map.get(attribute, :writable?, true)
        }
        |> put_unless_nil("hydra:description", Map.get(attribute, :description))
      end)

    # A public calculation is part of the class's shape, and a **read-only** part:
    # it is derived from the record rather than stored, so `hydra:writable` is
    # false and no client should be told otherwise. Declaring it is what lets a
    # consumer know the property exists at all — the ontology and the node's
    # `@context` follow the same list.
    calculation_properties =
      resource
      |> Ash.Resource.Info.public_calculations()
      |> Enum.map(fn calculation ->
        property_id =
          Map.get(semantic, calculation.name) || Context.property_iri(type, calculation.name)

        %{
          "@type" => "SupportedProperty",
          "hydra:property" => %{"@id" => property_id},
          "hydra:title" => to_string(calculation.name),
          # Derived: it is computed when asked for, so it is never required on a
          # write and never absent because somebody failed to supply it.
          "hydra:required" => false,
          "hydra:readable" => true,
          "hydra:writable" => false
        }
        |> put_unless_nil("hydra:description", Map.get(calculation, :description))
      end)

    attribute_properties ++ calculation_properties ++ link_properties(resource, type)
  end

  # A relationship is advertised as a `hydra:Link` — its `hydra:property` is a
  # node typed `hydra:Link`, so a client knows the key on a record is a
  # followable link rather than a literal value.
  #
  # Both cardinalities are described. A to-MANY's link is an inline collection
  # carrying its members; a to-ONE is a node reference built from the local
  # foreign key. Either way it is part of the class's shape and belongs in the
  # catalogue — omitting the to-one would leave roughly half the graph edges
  # undescribed, invisible to any client deriving structure from the
  # documentation.
  #
  # Cardinality is read from the relationship, never from whether a route was
  # derived. A to-many used to have a `:related` route and the two agreed, so
  # the route stood in for the cardinality; with the per-relationship routes
  # gone that proxy would have silently dropped every to-many from the
  # documentation.
  #
  # What the link points AT is `rdfs:range` on the property's own declaration
  # in the ontology, stated once rather than restated at every site the
  # property appears.
  defp link_properties(resource, type) do
    {to_many, to_one} =
      resource
      |> Ash.Resource.Info.public_relationships()
      |> Enum.split_with(&(&1.cardinality == :many))

    to_many = Enum.map(to_many, &link_property(resource, type, &1.name))
    to_one = Enum.map(to_one, &link_property(resource, type, &1.name))

    to_many ++ to_one
  end

  # One `hydra:Link` property.
  #
  # Cardinality is not marked here: the property's `rdfs:range` in the ontology
  # already says it — a to-many ranges over a `hydra:Collection` subclass
  # carrying a `hydra:memberAssertion`, a to-one over the destination class
  # itself.
  defp link_property(resource, type, name) do
    property = %{
      "@id" => Context.property_iri(type, name),
      "@type" => "hydra:Link"
    }

    %{
      "@type" => "SupportedProperty",
      "hydra:property" => property,
      "hydra:title" => to_string(name),
      "hydra:readable" => true,
      "hydra:writable" => writable_link?(resource, name)
    }
  end

  # A link is writable when some write action can set it: the client names a
  # target (by IRI or by declared identity) and the server relates it.
  #
  # Two ways an action can. It may take the relationship as an **argument** —
  # `change manage_relationship(:author, ...)` — which is the author's own
  # handling. Or, for a `belongs_to`, it may **accept the foreign key**, which
  # is the attribute a resolved link writes.
  #
  # Saying `false` where a write is possible is what leaves a client guessing
  # which links it may set; saying `true` where none is would advertise an
  # affordance the write path refuses.
  defp writable_link?(resource, name) do
    case Ash.Resource.Info.relationship(resource, name) do
      nil ->
        false

      relationship ->
        resource
        |> Ash.Resource.Info.actions()
        |> Enum.filter(&(&1.type in [:create, :update]))
        |> Enum.any?(&manages?(&1, relationship))
    end
  rescue
    _ -> false
  end

  defp manages?(action, relationship) do
    argument?(action, relationship.name) or accepts_foreign_key?(action, relationship)
  end

  defp argument?(%{arguments: arguments}, name) when is_list(arguments),
    do: Enum.any?(arguments, &(&1.name == name))

  defp argument?(_action, _name), do: false

  defp accepts_foreign_key?(%{accept: accept}, %{type: :belongs_to} = relationship)
       when is_list(accept),
       do: relationship.source_attribute in accept

  defp accepts_foreign_key?(_action, _relationship), do: false

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
      |> put_shape(action, resource, type, route)
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
  defp put_shape(op, nil, _resource, _type, _route), do: op

  defp put_shape(op, action, resource, type, route) do
    # The route is passed, not `nil`, and that is what gives a query read a
    # usable `hydra:template`.
    #
    # A GET with arguments renders as a `hydra:IriTemplate`, whose whole purpose
    # is to tell a client the URL to build. Without the route, `href/2` had
    # nothing to work from and every template came out as a bare query
    # fragment — `{?label}` rather than `/domain/read_failure/invalid{?label}`.
    # A client expanding that gets `?label=x` with no path at all, so the one
    # thing an IriTemplate exists to say was the one thing missing.
    rendered =
      AshHateoas.Descriptor.build(action, route, resource)
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

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
