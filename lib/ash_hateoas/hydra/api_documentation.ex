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

  ## What an entry has to answer

  A client reading a `hydra:supportedOperation` should be able to **issue** it,
  and that takes four answers:

    * **where to send it** — `ah:template`, a `hydra:IriTemplate` for the route's
      own path. Every entry carries one. The catalogue describes a class, so
      there is no record to resolve an address against and the honest statement
      is how to build one; a node states the resolved address as `ah:href`
      instead. A sub-action is why it matters: a member URL can be reached by
      following links, but a sub-action's URL appeared in exactly one place —
      `ah:href` on an operation a node is offering — so an operation the current
      state does not offer had no URL in any document.
    * **what to send** — `hydra:expects`, the request body as a class.
    * **what comes back** — `hydra:returns`. A collection route returns a
      *collection*, so it names the resource's collection class rather than the
      resource: `GET /exam` answers with `hydra:member` and `hydra:totalItems`,
      and a client told to expect an Exam looks for the resource's properties on
      a node that has none of them.
    * **what may go wrong** — `hydra:possibleStatus`, which now also carries what
      goes *right*. The list used to be failures only, so every entry read as an
      operation that can only fail and a generated handler had to hardcode which
      status means success — the one thing a description of an operation should
      not leave to convention.

  See `documentation/change-request-callable-operations.md`.

  ## Catalogue vs. availability

  `supportedOperation` describes the operations a class *supports* — their
  method, expected input and returned type. It is actor-independent and asserts
  no availability: whether an operation may be invoked *now*, on *this* record,
  by *this* actor is answered by the per-node `hydra:operation` the backbone
  gates. The documentation is the stable catalogue; the node is the live offer.
  """

  alias AshHateoas.Hydra.{Context, Ontology, Renderer}
  alias AshHateoas.{Affordance, Descriptor, Index, Route}

  @doc """
  Build the full `ApiDocumentation` document for `domains`.

  ## Options

    * `:entrypoint` — the API base URL (`hydra:entrypoint`).
    * `:id` — the document's own `@id` (its URL, e.g. `/doc`).
    * `:prefix` — the mount prefix (and origin) every `ah:template` is built
      against, so a template is a URL a client can expand rather than a path
      fragment it has to know where to hang.
  """
  @spec build([module()], keyword()) :: map()
  def build(domains, opts \\ []) do
    classes =
      domains
      |> Index.build()
      |> Enum.sort_by(fn {type, _resource} -> type end)
      |> Enum.flat_map(fn {type, resource} -> supported_classes(resource, type, opts) end)

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
      "@included" =>
        Ontology.build(domains) ++ report_declarations ++ input_class_declarations(classes),
      "hydra:supportedClass" => classes ++ report
    }
    |> put_unless_nil("@id", Keyword.get(opts, :id))
    |> put_unless_nil("hydra:entrypoint", Keyword.get(opts, :entrypoint))
  end

  # One declaration per input class the operations reference.
  #
  # `hydra:expects` names `<Class>/<action>Input` and, until now, nothing
  # declared it — 55 referenced and 0 declared on the fixture domain. That is the
  # dangling reference `AshHateoas.Hydra.Ontology` exists to remove, in the one
  # place its resource walk cannot reach: an input class derives from an
  # *action*, not from a resource's attributes or relationships.
  #
  # Collected from the **built document** rather than derived a second time from
  # the route table. Which operations carry a `hydra:expects` is decided by
  # `Renderer.put_expects/3` — method, fields, GET and DELETE left alone — and
  # restating that rule here would be a second copy free to drift. Reading back
  # what was emitted cannot drift by construction.
  #
  # The class is declared and its **properties are not**, which is the same rule
  # the ontology already states for arguments: `approve` takes a `note`, and a
  # Document does not *have* a note, so an `rdfs:domain` for it would assert
  # something false. The input shape stays self-contained, carrying its type
  # information at the usage site.
  defp input_class_declarations(classes) do
    for class <- classes,
        operation <- class["hydra:supportedOperation"] || [],
        iri = get_in(operation, ["hydra:expects", "@id"]),
        is_binary(iri),
        uniq: true do
      %{
        "@id" => iri,
        "@type" => ["owl:Class", "hydra:Class"],
        "rdfs:label" => iri |> String.split("/") |> List.last(),
        "rdfs:comment" =>
          "The input one operation accepts. Not a class any record is an instance of."
      }
    end
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
  defp supported_classes(resource, type, opts) do
    member =
      case AshHateoas.Resource.Info.semantic_type(resource) do
        nil ->
          [supported_class(resource, type, opts)]

        semantic_type ->
          primary = supported_class(resource, type, opts)
          companion = Map.put(primary, "@id", semantic_type)

          [primary, companion]
      end

    member ++ collection_class(resource, type, opts)
  end

  # **The collection is a class of its own, and it is where a collection-level
  # operation belongs.**
  #
  # `hydra:supportedOperation` on a `hydra:Class` says: an instance of this class
  # supports this operation, invoked against that instance. That is Hydra's whole
  # model for where an operation attaches, and it is why `hydra:Operation` has no
  # target-URL property of its own.
  #
  # Every route used to hang off the one class a resource yields, and some of
  # those routes are not member routes. `vocab#Exam` advertised an operation
  # POSTed to `/exam` and another `GET` at `/exam` — you cannot POST to an exam
  # to create an exam, and listing exams is not something one exam does. In a
  # captured API that was 34 of 115 operations filed under a subject they are not
  # about.
  #
  # It is also where the doubling came from. One Ash `read` became two entries
  # under `vocab#Exam` because both its routes were forced under the member
  # class, and the two then had to be told apart by something — which is what
  # produced a class per route, and before that two entries a client could not
  # distinguish at all. The doubling was never a property of the action: it is two
  # different affordances, one on a record and one on a collection, filed under
  # one subject.
  #
  # A client gains the entry-point question — *how do I list these, how do I make
  # one* — answerable without holding an instance. Today that answer sat under a
  # class whose instances cannot give it.
  #
  # The class is the same `<Class>/Collection` that `hydra:returns` already names
  # on a collection route, minted by `Context.collection_class_iri/1` and declared
  # in `@included` by `AshHateoas.Hydra.Ontology` with the `hydra:memberAssertion`
  # that says what is inside it. Named as a return and never declared as a
  # supported class, it left a client told what comes back and not told what it
  # supports.
  defp collection_class(resource, type, opts) do
    case supported_operations(resource, type, Keyword.put(opts, :scope, :collection)) do
      [] ->
        []

      operations ->
        [
          %{
            "@id" => Context.collection_class_iri(type),
            "@type" => "Class",
            "hydra:title" => "#{type} collection",
            "hydra:description" =>
              "The collection of #{type} records: what may be done to the set rather than to one of them.",
            "hydra:supportedOperation" => operations
          }
        ]
    end
  end

  @doc "Build one `hydra:Class` for a resource."
  @spec supported_class(module(), String.t(), keyword()) :: map()
  def supported_class(resource, type, opts \\ []) do
    %{
      "@id" => Context.class_iri(type),
      "@type" => "Class",
      "hydra:title" => type,
      "hydra:supportedProperty" => supported_properties(resource, type),
      "hydra:supportedOperation" =>
        supported_operations(resource, type, Keyword.put(opts, :scope, :member))
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

  ## Options

    * `:scope` — `:member` for the operations invoked against one record,
      `:collection` for those invoked against the set, `:all` (the default) for
      both. The split is by the route's **path** rather than its kind: a route
      naming `:id` addresses a record, whatever verb it carries. Reading the kind
      held only while an action's type and its URL agreed, and they stopped
      agreeing when a named transition became a `POST`.
  """
  @spec supported_operations(module(), String.t(), keyword()) :: [map()]
  def supported_operations(resource, type, opts \\ []) do
    scope = Keyword.get(opts, :scope, :all)

    resource
    |> routes()
    |> Enum.reject(&Route.navigation?/1)
    |> Enum.filter(&in_scope?(&1, scope))
    |> Enum.map(fn %Route{} = route ->
      action = Ash.Resource.Info.action(resource, route.action)

      %{
        # **One class, and it is the node's.**
        #
        # Hydra gives an operation no identity of its own — `Operation` is
        # carried by every operation this package emits, so it separates none of
        # them. The action class is what does, and it is an IRI rather than the
        # bare `ah:action` string it replaces: dereferenceable, subclassable,
        # annotatable, and global where a local word is not. It is also the join
        # to the node — a node's operation carries this same list — which is why
        # both documents mint it through `Context.action_class_iri/2` rather
        # than writing it out twice, and why the join is an identity rather than
        # a walk up a subclass chain.
        #
        # A third element, a class per route, was minted for a while. It was
        # withdrawn: two routes onto one action really are the same action, and
        # what separates them is where the request goes and what comes back —
        # `ah:template` and `hydra:returns`, both added since. Minting a class to
        # distinguish two entries the document did not otherwise distinguish was
        # the wrong end of the problem.
        "@type" => ["Operation", Context.action_class_iri(type, route.action)],
        "hydra:method" => method(route, action) |> to_string() |> String.upcase(),
        "ah:template" => template(action, resource, type, route, opts)
      }
      |> put_unless_nil("hydra:title", action && Map.get(action, :description))
      |> put_shape(action, resource, type, route)
      |> put_collection_returns(route, type)
      |> put_possible_status(route, action, resource)
    end)
  end

  defp in_scope?(_route, :all), do: true
  defp in_scope?(route, :member), do: Route.member?(route)
  defp in_scope?(route, :collection), do: not Route.member?(route)

  # **Where the operation is sent**, as a template rather than an address.
  #
  # `%Route{}.route` is `/exam/:id` or `/exam` — a fact about the class, actor-
  # independent and state-independent, exactly what belongs in a catalogue. It
  # was the one thing an entry did not carry, so a client holding only the
  # documentation could see that a class supports nine operations and issue none
  # of them.
  #
  # The machinery is `Renderer.iri_template/2`, which already rewrites `:id` to
  # `{id}` and declares a path variable as required. It ran only for a GET whose
  # action has query fields; here it runs for every route.
  #
  # **Only a GET's fields become variables.** A write's fields are its request
  # body, described by `hydra:expects`, and putting them in the template would
  # tell a client to send a create's `title` as a query parameter.
  defp template(action, resource, type, route, opts) do
    action
    |> template_affordance(resource, route)
    |> Renderer.iri_template(type: type, prefix: Keyword.get(opts, :prefix))
  end

  # A route whose action cannot be resolved still has a path, and the path is the
  # part the client needs. Described with no variables beyond the ones in the path
  # itself rather than not described at all.
  defp template_affordance(nil, _resource, %Route{} = route),
    do: %Affordance{name: nil, href: route.route, method: :get, fields: []}

  defp template_affordance(action, resource, %Route{} = route) do
    descriptor = Descriptor.build(action, route, resource)

    case method(route, action) do
      :get -> descriptor
      _other -> %{descriptor | fields: []}
    end
  end

  # A collection route answers with a **collection**, and says what is in it.
  #
  # `Renderer.put_returns/3` names the resource's class for every operation
  # yielding a record and does not consult the route kind, so both routes onto a
  # primary read declared the same thing — and for `GET /exam` that was untrue:
  # `AshHateoas.Hydra.Collection.wrap/2` answers with `hydra:member` and
  # `hydra:totalItems`, which an Exam has neither of.
  #
  # `hydra:Collection` alone would be true and would not say *of what*, so this
  # names the resource's own collection class, declared in
  # `AshHateoas.Hydra.Ontology` with the `hydra:memberAssertion` that carries the
  # member class. The served collection carries the same assertion, so the two
  # documents state one fact rather than two that can drift.
  defp put_collection_returns(op, %Route{type: :index}, type),
    do: Map.put(op, "hydra:returns", %{"@id" => Context.collection_class_iri(type)})

  defp put_collection_returns(op, _route, _type), do: op

  # The statuses an operation may return: **what goes right first**, then the
  # gate chain.
  #
  # The list used to be failures only — 403 from the authorizers, 422 from a
  # write's validation, 404 from a member route — so a catalogue entry read as an
  # operation that can only fail, and the one status a caller most needs was the
  # one never stated. Hydra does not license that: an Operation "may document the
  # status codes that might be returned by the server using the `possibleStatus`
  # property", with no restriction to failures, and the spec adds that the list
  # "has not to be considered as an extensive list of all potentially returned
  # status codes; it is merely a hint".
  #
  # The cost of omitting it is not cosmetic. A client generating a request
  # handler from the catalogue has to hardcode which status means success, which
  # is the one thing a description of an operation should not leave to
  # convention.
  #
  # Still actor-independent: it lists what *could* happen, not what will for a
  # given request.
  defp put_possible_status(op, route, action, resource) do
    statuses =
      route
      |> success_statuses(action)
      |> maybe_status(authorized?(resource), 403, "Forbidden — the actor may not perform this.")
      |> maybe_status(write?(action), 422, "Unprocessable — the input failed validation.")
      |> maybe_status(member_route?(route), 404, "Not Found — no such record.")

    case statuses do
      [] -> op
      list -> Map.put(op, "hydra:possibleStatus", list)
    end
  end

  # What the plug actually sends, read off the route kind — which is already in
  # hand, and is the only thing that decides it. Each of these is one
  # `AshHateoas.Hydra.Plug` response clause, not a convention.
  #
  # A **destroy** is the case where two are possible, and both are listed rather
  # than one chosen: `respond_destroy/7` answers 200 with the destroyed record
  # when the data layer returns one and 204 with no body when it does not.
  # `possibleStatus` is a set of what may happen, so declaring both is the more
  # accurate document — and it is also what settles `hydra:returns` naming the
  # resource's class on a destroy. The class is what comes back *when a body
  # does*; the 204 is where "sometimes there is none" is stated. Naming
  # `owl:Nothing` alongside it would be an intersection with the empty class,
  # which is unsatisfiable and says the operation returns nothing, ever.
  defp success_statuses(%Route{type: :post}, action) do
    if create?(action) do
      [status(201, "Created — the new record is returned.")]
    else
      [status(200, "OK — the write succeeded.")]
    end
  end

  defp success_statuses(%Route{type: :delete}, _action) do
    [
      status(200, "OK — the destroyed record is returned."),
      status(204, "No Content — the destroy yielded no record, so no body is sent.")
    ]
  end

  defp success_statuses(%Route{type: :index}, _action),
    do: [status(200, "OK — the collection is returned.")]

  defp success_statuses(%Route{type: :patch}, _action),
    do: [status(200, "OK — the updated record is returned.")]

  defp success_statuses(%Route{type: :route}, _action),
    do: [status(200, "OK — the action ran.")]

  defp success_statuses(_route, _action), do: [status(200, "OK — the record is returned.")]

  defp create?(%{type: :create}), do: true
  defp create?(_action), do: false

  defp status(code, title),
    do: %{"@type" => "Status", "hydra:statusCode" => code, "hydra:title" => title}

  defp maybe_status(list, false, _code, _title), do: list
  defp maybe_status(list, true, code, title), do: list ++ [status(code, title)]

  defp authorized?(resource) do
    Ash.Resource.Info.authorizers(resource) != []
  rescue
    _ -> false
  end

  defp write?(%{type: type}) when type in [:create, :update, :destroy, :action], do: true
  defp write?(_action), do: false

  # A route addressing a specific record can 404; a collection-level route
  # (create, index) cannot. `AshHateoas.Route.member?/1` is the same predicate
  # that decides which class an operation is filed under — this is where it was
  # first written, and the two must not drift apart.
  defp member_route?(route), do: Route.member?(route)

  # Reuse the renderer's `expects`/`returns` derivation so the documentation
  # catalogue and the live per-node operations describe input/output identically.
  defp put_shape(op, nil, _resource, _type, _route), do: op

  defp put_shape(op, action, resource, type, route) do
    rendered =
      action
      |> Descriptor.build(route, resource)
      |> Renderer.operation(
        type: type,
        semantic_actions: AshHateoas.Resource.Info.semantic_actions(resource)
      )

    op
    |> put_unless_nil("hydra:expects", body(Map.get(rendered, "hydra:expects")))
    |> put_unless_nil("hydra:returns", Map.get(rendered, "hydra:returns"))
  end

  # **In the catalogue, `hydra:expects` is the request body and nothing else.**
  #
  # A node's GET affordance renders its query arguments as an `IriTemplate` under
  # `hydra:expects`, and that is unchanged — on a node the address is already
  # resolved as `ah:href`, so the template is genuinely about what to send. Here
  # it is not: `ah:template` states the whole address including the query
  # variables, so a copy under `hydra:expects` would be the identical node under
  # a second key, and a client would have to read the value's `@type` to learn
  # which question the key was answering.
  defp body(%{"@type" => "IriTemplate"}), do: nil
  defp body(expects), do: expects

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

  # Not `Ash.Resource.Info.public_attributes/1`: that includes the foreign keys
  # a public `belongs_to` generated, which the link already describes. See
  # `AshHateoas.Resource.Info.public_attributes/1` for why the key is not
  # surface and why the signal is the relationship rather than the name.
  defp public_attributes(resource) do
    AshHateoas.Resource.Info.public_attributes(resource)
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
