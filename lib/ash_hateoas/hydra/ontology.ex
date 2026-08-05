defmodule AshHateoas.Hydra.Ontology do
  @moduledoc """
  Declares the vocabulary the `ApiDocumentation` uses.

  The documentation mints a property IRI for every attribute and relationship
  (`…#article/author`, `…#comment/body`) and, until this module, said nothing
  about any of them. Every occurrence was a *reference*: a client could see that
  `article/author` was used, and had nowhere to learn what it was.

  This module emits the missing half — one declaration per class and per
  property, carried in the same document under `@included`, so one fetch still
  gets everything.

  ## Two vocabularies, two questions

  Each term ends up with two types, and they answer different questions:

    * **What is this?** — `owl:Class`, `owl:ObjectProperty`,
      `owl:DatatypeProperty`. The ontology reading.
    * **What may a client do with it?** — `hydra:Class`, `hydra:Link`. The
      transport reading.

  Neither implies the other. Verified against the vocabulary published at
  `http://www.w3.org/ns/hydra/core`: `hydra:Class` is `rdfs:subClassOf
  rdfs:Class` — never `owl:Class` — and `hydra:supportedClass` has a hard
  `rdfs:range rdfs:Class`, so Hydra is fully satisfied with no OWL involved.
  The specification mentions OWL nowhere at all. That silence is why the OWL
  types have to be stated here rather than inferred: without `owl:Class` a
  reasoner may ignore our `rdfs:subClassOf` axioms entirely (OWL 2 §5.8.2).

  Typing a class both ways is *punning* — the IRI is a class under one reading
  and an individual under the other. OWL 2 §5.8.1 permits it (it forbids
  class/datatype punning, not class/individual), and it is the price of serving
  both readers from one document.

  Properties need no such caveat: `hydra:Link rdfs:subClassOf rdf:Property` and
  `owl:ObjectProperty rdfs:subClassOf rdf:Property`, so both readings agree the
  IRI is a property.

  ## `rdfs:range` is an assertion, not a hint

  RDFS entailment rule **rdfs3** says that given `P rdfs:range C` and `x P y`,
  a reasoner infers `y rdf:type C`. That is not advisory, and RDF has no
  negation to contradict it — so a range may only be emitted where the claim is
  guaranteed. An Ash relationship qualifies: the destination resource is known
  and every value really is one.

  An external `ResourceLink` does not. Its target lives on a host we do not
  control, so `rdfs:range` would assert that somebody else's resource is an
  instance of our class. That case uses `schema:rangeIncludes`, which is
  explicitly non-entailing and means what is actually meant: *expect this*.

  ## Why `@included` rather than `rdfs:isDefinedBy`

  `@included` (JSON-LD 1.1) is the term for secondary node objects inside
  another node object: their triples land in the default graph and nothing is
  asserted about the containing node.

  Hanging the declarations off the ApiDocumentation with `rdfs:isDefinedBy`
  would say the *documentation is defined by* the Flow class — backwards, and
  an annotation property a DL reasoner ignores as logical content besides. The
  term is still used, pointed the right way: each declared term names the
  ontology that defines it. `owl:imports` is also wrong, since it requires a
  separately dereferenceable document and would cost the one-fetch property.

  ## What is deliberately *not* declared

  An operation's input fields. A write's `hydra:expects` is a `hydra:Class` per
  action (`…#Document/approveInput`) whose supported properties are the
  action's *arguments* — `note`, `notify`, `signing_key`. Those IRIs are
  referenced and not declared here, and that is the intended state:

    * An argument is not a property of any class. `approve` takes a `note`; a
      Document does not *have* a note. Declaring `…#document/note` with
      `rdfs:domain …#Document` would assert exactly the thing that is false,
      and under rdfs3 a reasoner would then type every value it saw.
    * The input class is per-action and exists only to describe one call, so
      there is no persistent class for such a property to belong to.

  So the input shape stays self-contained, carrying its own type information at
  the usage site. The rule this module follows is narrower than "declare every
  IRI": declare every property that is a property *of a class*.

  One known wrinkle, not yet resolved: an argument that happens to name an
  attribute with a `semantic_property` mapping gets the unmapped
  `…#person/additional_name` on the input class, where the class property
  correctly emits `schema:additionalName`. The two paths should agree, and the
  input path is the one that is wrong.

  > #### Verifying this output {: .warning}
  >
  > `@included` is JSON-LD **1.1**. The OWL API (and therefore `robot`) ships a
  > 1.0 parser that **silently ignores it** — `robot reason` exits 0 having
  > loaded no declarations at all. Expand to N-Quads with a 1.1 processor
  > first, then reason over that. An exit code alone is a false pass.
  """

  alias AshHateoas.Hydra.Context
  alias AshHateoas.Index

  @doc """
  The `@included` block for `domains`: the ontology node, the borrowed Hydra
  terms, this package's own `ah:` terms, and one declaration per class and
  property the documentation references.
  """
  @spec build([module()]) :: [map()]
  def build(domains) do
    resources =
      domains
      |> Index.build()
      |> Enum.sort_by(fn {type, _resource} -> type end)

    ontology_node() ++
      borrowed_terms() ++
      ah_terms() ++
      Enum.flat_map(resources, fn {type, resource} -> class_node(resource, type) end) ++
      Enum.flat_map(resources, fn {type, resource} -> property_nodes(resource, type) end)
  end

  # The ontology every declared term points back at with `rdfs:isDefinedBy`.
  defp ontology_node do
    [%{"@id" => Context.vocab_iri(""), "@type" => "owl:Ontology"}]
  end

  # `hydra:Class` and `hydra:Link` are used as types on our own terms, and OWL 2
  # §5.8.2 wants every IRI occurring in an axiom declared. Hydra does not
  # declare them as OWL entities — it has no OWL layer at all — so we do it
  # here, for the document to be self-contained.
  #
  # This asserts nothing about Hydra that Hydra denies: a `hydra:Class` really
  # is a class, and `hydra:Link` really is a property class. It only states it
  # in the formalism a reasoner reads.
  defp borrowed_terms do
    [
      %{"@id" => "hydra:Class", "@type" => "owl:Class"},
      %{"@id" => "hydra:Link", "@type" => "owl:Class"}
    ]
  end

  # This package's own vocabulary, which had the same defect it diagnoses: the
  # terms appeared in the `@context` with a subclass hint each, and none was
  # declared.
  defp ah_terms do
    [
      # An annotation — and deliberately **not** `rdfs:subPropertyOf
      # owl:hasKey`, which the `@context` claimed until now. Two reasons, both
      # fatal:
      #
      #   1. Wrong subject. `owl:hasKey` is a *class* axiom taking a class
      #      expression and an `rdf:List` of properties. It cannot sit on a
      #      property node, and a nested JSON array is not an `rdf:List`.
      #   2. Wrong semantics. `owl:hasKey` licenses a reasoner to infer
      #      `owl:sameAs` between individuals sharing key values. `ah:identity`
      #      names a *business* key, and a domain where two records legitimately
      #      share a name would see them merged and their properties unioned —
      #      exactly the corruption the term exists to prevent.
      #
      # `ah:identity` means "unique within its parent", which is scoped
      # uniqueness — something OWL cannot express. If global uniqueness is ever
      # genuinely true, emit `owl:hasKey` on *that class* deliberately.
      %{
        "@id" => "ah:identity",
        "@type" => "owl:AnnotationProperty",
        "rdfs:isDefinedBy" => %{"@id" => Context.vocab_iri("")}
      },
      %{
        "@id" => "ah:action",
        "@type" => "owl:AnnotationProperty",
        "rdfs:isDefinedBy" => %{"@id" => Context.vocab_iri("")}
      },
      # Two operation roles schema.org cannot express, each related to the
      # nearest published term so a client that speaks only schema.org still
      # learns something true.
      #
      # `ah:SaveAction` — writing a whole document rather than one record.
      # `schema:UpdateAction` describes the act correctly but is also what this
      # package infers for *any* PATCH, so declaring it outright would make a
      # document save indistinguishable from an ordinary record update. The
      # subclass says "this writes" to a generic reader and "this writes a
      # document" to one that knows the term.
      #
      # `ah:RunAction` — executing a resource. schema.org has no term for it:
      # `ControlAction` and `ActivateAction` are device control, and
      # `AchieveAction`'s subtypes are Win/Lose/Tie. `schema:Action` is the only
      # honest parent — an agent does something, which is all that is shared.
      %{
        "@id" => "ah:SaveAction",
        "@type" => "owl:Class",
        "rdfs:subClassOf" => %{"@id" => "schema:UpdateAction"},
        "rdfs:isDefinedBy" => %{"@id" => Context.vocab_iri("")}
      },
      %{
        "@id" => "ah:RunAction",
        "@type" => "owl:Class",
        "rdfs:subClassOf" => %{"@id" => "schema:Action"},
        "rdfs:isDefinedBy" => %{"@id" => Context.vocab_iri("")}
      },
      # A **datatype**, not a class: the values are literals — source code is
      # text — so what needs saying is which strings, not which resources.
      # `rdfs:Datatype` restricting `xsd:string` is how OWL says that, and it is
      # what an attribute typed `AshHateoas.Type.Lua` ranges on instead of
      # `xsd:string`.
      #
      # `xsd:string` is true of a script and useless: it tells a consumer the
      # value is text, so a client renders a formula as prose. It would have to
      # *guess* that this particular string contains references — and a guess
      # that is wrong on a `description` full of brackets is worse than no
      # guess at all. The narrower datatype is the statement that replaces it.
      #
      # `ah:scriptLanguage` says which language, because "it is code" is not
      # actionable on its own: a client that wants to highlight, parse or
      # complete needs to know what grammar it is reading.
      %{
        "@id" => "ah:Script",
        "@type" => "rdfs:Datatype",
        "owl:onDatatype" => %{"@id" => "xsd:string"},
        "rdfs:label" => "Script",
        "rdfs:comment" => "A string whose value is source code in a stated language.",
        "rdfs:isDefinedBy" => %{"@id" => Context.vocab_iri("")}
      },
      %{
        "@id" => "ah:scriptLanguage",
        "@type" => "owl:AnnotationProperty",
        "rdfs:label" => "scriptLanguage",
        "rdfs:comment" => "The language a script property's values are written in.",
        "rdfs:isDefinedBy" => %{"@id" => Context.vocab_iri("")}
      },
      %{"@id" => "hydra:Resource", "@type" => "owl:Class"}
    ]
  end

  # A class, declared once.
  #
  # `rdfs:subClassOf` appears only when a `semantic_type` supplies one. There is
  # deliberately no `owl:Thing` default: every OWL class is trivially a subclass
  # of `owl:Thing`, so the triple entails nothing, and `@type: owl:Class`
  # already tells a consumer this is a class.
  #
  # Note this is `rdfs:subClassOf`, where the documentation emitted
  # `owl:equivalentClass`. Equivalence says the two are the *same set*, which is
  # almost never true — a local Person has an id, a tenant and domain rules
  # `schema:Person` knows nothing of — and it licenses inference in both
  # directions, so a reasoner could conclude things about schema.org's class
  # from statements about ours.
  defp class_node(resource, type) do
    node =
      %{
        "@id" => Context.class_iri(type),
        "@type" => ["owl:Class", "hydra:Class"],
        "rdfs:isDefinedBy" => %{"@id" => Context.vocab_iri("")}
      }
      |> put_unless_nil("rdfs:label", type)
      |> put_subclass_of(AshHateoas.Resource.Info.semantic_type(resource))

    [node]
  end

  defp put_subclass_of(node, nil), do: node

  defp put_subclass_of(node, semantic_type),
    do: Map.put(node, "rdfs:subClassOf", %{"@id" => semantic_type})

  # Every property IRI the documentation references, declared.
  #
  # The traversal deliberately mirrors `ApiDocumentation.supported_properties/2`
  # — same attributes, same relationships, same filters — because a property
  # declared here but not used there is noise, and one used there but not
  # declared here is the defect this module exists to remove.
  defp property_nodes(resource, type) do
    attribute_nodes(resource, type) ++
      calculation_nodes(resource, type) ++ relationship_nodes(resource, type)
  end

  # A public calculation mints a property IRI exactly as an attribute does, so it
  # must be declared here or it dangles — the defect this module exists to
  # remove, reached by a property kind the walk did not visit.
  #
  # `attribute_type/1` applies unchanged: it reads `:type`, which a calculation
  # carries too, so a derived string is an `owl:DatatypeProperty` with an `xsd`
  # range like any other. That it is *computed* is a storage fact, and the
  # ontology describes meaning rather than storage.
  defp calculation_nodes(resource, type) do
    semantic = AshHateoas.Resource.Info.semantic_properties(resource)

    resource
    |> Ash.Resource.Info.public_calculations()
    |> Enum.reject(&Map.has_key?(semantic, &1.name))
    |> Enum.map(fn calculation ->
      %{
        "@id" => Context.property_iri(type, calculation.name),
        "rdfs:domain" => %{"@id" => Context.class_iri(type)},
        "rdfs:isDefinedBy" => %{"@id" => Context.vocab_iri("")}
      }
      |> Map.merge(attribute_type(calculation))
      |> put_unless_nil("rdfs:label", to_string(calculation.name))
      |> put_unless_nil("rdfs:comment", Map.get(calculation, :description))
    end)
  end

  defp attribute_nodes(resource, type) do
    semantic = AshHateoas.Resource.Info.semantic_properties(resource)

    resource
    |> public_attributes()
    |> Enum.reject(&Map.has_key?(semantic, &1.name))
    |> Enum.map(fn attribute ->
      %{
        "@id" => Context.property_iri(type, attribute.name),
        "rdfs:domain" => %{"@id" => Context.class_iri(type)},
        "rdfs:isDefinedBy" => %{"@id" => Context.vocab_iri("")}
      }
      |> Map.merge(attribute_type(attribute))
      |> put_unless_nil("rdfs:label", to_string(attribute.name))
      |> put_unless_nil("rdfs:comment", Map.get(attribute, :description))
    end)
  end

  # A mapped attribute advertises a well-known property IRI (`schema:name`)
  # rather than one of ours, and that term is somebody else's to define. We
  # reference it; declaring it would be minting a claim about a vocabulary we do
  # not own — the same overreach as `owl:equivalentClass`, one level down.

  # An external `ResourceLink` is an object property, but its range is an
  # *expectation* rather than a guarantee, so it gets no `rdfs:range` at all.
  # See the rdfs3 note in the moduledoc: asserting a range here would type
  # another service's resources as ours.
  defp attribute_type(%{type: type} = attribute) do
    wire = AshHateoas.TypeMapper.to_wire(type)

    cond do
      resource_link?(attribute) ->
        %{"@type" => ["owl:ObjectProperty", "hydra:Link"]}

      # A script is a datatype property like any other — its values are
      # literals. What differs is the range: `ah:Script` rather than
      # `xsd:string`, plus the language, so a consumer learns the value is
      # source code *and* what grammar to read it with. Both are declared in
      # `ah_terms/0`.
      script?(attribute) ->
        %{
          "@type" => "owl:DatatypeProperty",
          "rdfs:range" => %{"@id" => "ah:Script"},
          "ah:scriptLanguage" => script_language(attribute)
        }

      wire == "union" ->
        # A union's arms are datatypes as often as not, and OWL keeps object
        # and datatype properties strictly apart (§5.8.1 forbids punning
        # *between* them). Declaring one arbitrarily would be a guess a
        # reasoner then treats as fact, so the property is declared as a bare
        # `rdf:Property` and the arms are left to `schema:rangeIncludes` on the
        # usage site, which is non-entailing.
        %{"@type" => "rdf:Property"}

      true ->
        %{"@type" => "owl:DatatypeProperty"}
        |> put_unless_nil("rdfs:range", datatype_range(wire))
    end
  end

  # Asks the *type* what language it is, rather than matching the module name,
  # so a second script type needs no edit here.
  defp script?(%{type: type}), do: not is_nil(script_language(%{type: type}))

  defp script_language(%{type: type}) do
    if is_atom(type) and not is_nil(type) and function_exported?(type, :script_language, 0) do
      type.script_language()
    end
  rescue
    _ -> nil
  end

  defp resource_link?(%{type: type}) do
    type == AshHateoas.Type.ResourceLink or
      (is_atom(type) and function_exported?(type, :subtype_of, 0) and
         type.subtype_of() == :string and
         to_string(type) =~ "ResourceLink")
  rescue
    _ -> false
  end

  defp datatype_range(wire) do
    case AshHateoas.Hydra.TypeMapper.type_info(wire) do
      {:sh_datatype, iri} -> %{"@id" => iri}
      {:rdfs_range, iri} -> %{"@id" => iri}
      _ -> nil
    end
  end

  # A relationship: an object property, and dereferenceable.
  #
  # Both types earn their place. `owl:ObjectProperty` says the values are
  # individuals rather than literals — the ontology question. `hydra:Link` says
  # the value is *meant to be fetched* — the transport question. Both are
  # needed: a foreign key by id would be `owl:ObjectProperty` alone, and
  # `hydra:Link` alone would not say the values are individuals.
  #
  # The target is `rdfs:range`, not a per-usage `sh:class`. The range is a fact
  # about the property and belongs on it; restating the same target at every
  # site the property appears is a shape that permits drift.
  # Cardinality comes from the relationship, not from whether a route was
  # derived for it. Those agreed while every to-many had a `:related` route, and
  # reading the route was a proxy for reading the relationship — so when the
  # per-relationship routes went, every to-many would have silently stopped
  # being declared, taking its collection class with it. Ash already states the
  # cardinality; ask it.
  defp relationship_nodes(resource, type) do
    {to_many, to_one} =
      resource
      |> Ash.Resource.Info.public_relationships()
      |> Enum.split_with(&(&1.cardinality == :many))

    to_many = Enum.map(to_many, & &1.name)
    to_one = Enum.map(to_one, & &1.name)

    properties =
      Enum.map(to_many ++ to_one, fn name ->
        %{
          "@id" => Context.property_iri(type, name),
          "@type" => ["owl:ObjectProperty", "hydra:Link"],
          "rdfs:domain" => %{"@id" => Context.class_iri(type)},
          "rdfs:isDefinedBy" => %{"@id" => Context.vocab_iri("")}
        }
        |> put_unless_nil("rdfs:range", relationship_range(resource, name, name in to_many))
        |> put_unless_nil("rdfs:label", to_string(name))
      end)

    properties ++ Enum.flat_map(to_many, &collection_class(resource, type, &1))
  end

  # The class a relationship points at.
  #
  # For a to-one that is the destination class directly. For a to-many it is the
  # property's own **collection class** — because the value of `article.comments`
  # is a `hydra:Collection`, not a Comment, and `rdfs:range` is an assertion
  # about every value the property takes (rdfs3). Naming the member class here
  # would assert that the collection *is* a Comment, which is false and would be
  # materialised by any RDFS reasoner.
  #
  # A destination carrying no type is not addressable as a node, so the property
  # is declared without a range rather than with a bogus one — a consumer
  # degrades to an untyped-but-followable link instead of resolving to nothing.
  defp relationship_range(resource, name, many?) do
    with %{destination: destination} <- Ash.Resource.Info.relationship(resource, name),
         destination_type when is_binary(destination_type) <-
           AshHateoas.Resource.Info.type(destination) do
      if many? do
        %{"@id" => collection_class_iri(resource, name)}
      else
        %{"@id" => Context.class_iri(destination_type)}
      end
    else
      _ -> nil
    end
  end

  # A to-many's collection class: a `hydra:Collection` subclass that says what
  # its members are.
  #
  # This is the spec's own pattern for a strongly typed collection, given at the
  # API-documentation level:
  #
  #     "api:UserCollection": {
  #       "subClassOf": "Collection",
  #       "memberAssertion": {"property": "rdf:type", "object": "api:User"}}
  #
  # — "clients would understand that all members of collections which are
  # instances of api:UserCollections would in fact have rdf:type api:User".
  #
  # Two standard terms rather than a minted one, and they say strictly more
  # than a `targetKind: "Collection"` marker would: they state the relation
  # between the collection and its member class rather than leaving the two
  # facts side by side.
  #
  # Note the member class cannot simply be the property's `rdfs:range`: the
  # value is the collection, so a range naming the member would assert the
  # collection is one of its own members.
  #
  # The spec's normative constraint — "a memberAssertion MUST use two and only
  # two of the subject, property and object predicates" — is met by the
  # property/object pair. `hydra:subject` is the third and is deliberately
  # absent; it would name one specific parent record, which is an instance-level
  # fact and wrong on a class.
  defp collection_class(resource, type, name) do
    case Ash.Resource.Info.relationship(resource, name) do
      %{destination: destination} = relationship ->
        case member_class(relationship, destination) do
          member when is_binary(member) ->
            [
              %{
                "@id" => collection_class_iri(resource, name),
                "@type" => ["owl:Class", "hydra:Class"],
                "rdfs:subClassOf" => %{"@id" => "hydra:Collection"},
                "hydra:memberAssertion" => %{
                  "hydra:property" => %{"@id" => "rdf:type"},
                  "hydra:object" => %{"@id" => Context.class_iri(member)}
                },
                "rdfs:label" => "#{type}/#{name} collection",
                "rdfs:isDefinedBy" => %{"@id" => Context.vocab_iri("")}
              }
            ]

          _ ->
            []
        end

      _ ->
        []
    end
  end

  # What a to-many's members actually are — which is not always its destination.
  #
  # A relationship may be *narrowed* by a filter, and then the destination is a
  # base class the members merely belong to rather than the class they have:
  #
  #     has_many :draft_posts, Post do
  #       filter(expr(status == :draft))    # ← every member is a DraftPost
  #     end
  #
  # Read only the destination and every narrowing of one base reports that base,
  # so the collections are byte-identical apart from an `rdfs:label` — and a
  # label is not a claim. A client is told each collection holds a Post, which
  # is true of all of them and therefore distinguishes none.
  #
  # The narrowed class is asserted only where it is **guaranteed**, the same rule
  # `rdfs:range` follows (rdfs3, above):
  #
  #   * the filter must pin an attribute to a single literal — `==` against a
  #     bare value. Anything else (a range, an `or`, a reference to another
  #     field) leaves members the emitter cannot vouch for, so it falls back;
  #   * a class of that name must exist in the destination's own domain, which
  #     is the set the ontology declares beside it. A literal naming nothing
  #     declared would mint a dangling IRI — the defect this module was written
  #     to remove.
  #
  # The fallback is the destination: weaker, never wrong. And the narrowed claim
  # is strictly stronger rather than different — every member really is one of
  # the narrowed class — so a consumer that only knew the base class still reads
  # a true statement through the subclass.
  #
  # Nothing here learns any consumer's vocabulary. It reads "a filter equates an
  # attribute to a literal, and a class of that name is declared", which is a
  # statement about Ash and OWL.
  defp member_class(%{filter: filter}, destination) do
    with literal when not is_nil(literal) <- pinned_literal(filter),
         module when not is_nil(module) <- declared_sibling(destination, literal) do
      AshHateoas.Resource.Info.type(module)
    else
      _ -> AshHateoas.Resource.Info.type(destination)
    end
  end

  defp member_class(_relationship, destination),
    do: AshHateoas.Resource.Info.type(destination)

  # The value a filter pins an attribute to, or `nil` if it pins none.
  #
  # Matched against the unparsed `expr/1` AST — a `has_many`'s filter is stored
  # as written, not as a built expression — so this is one shape rather than the
  # whole of `Ash.Filter`. Deliberately narrow: an unrecognised filter falls
  # back rather than being approximated.
  defp pinned_literal(%Ash.Query.Call{name: :==, args: [%Ash.Query.Ref{}, literal]})
       when is_atom(literal) or is_binary(literal),
       do: to_string(literal)

  defp pinned_literal(%Ash.Query.Call{name: :==, args: [literal, %Ash.Query.Ref{}]})
       when is_atom(literal) or is_binary(literal),
       do: to_string(literal)

  defp pinned_literal(_filter), do: nil

  # A resource in the destination's own domain whose type is this literal.
  #
  # The domain is the right scope because it is what `Index.build/1` walks to
  # decide which classes are declared, so a hit here is a class the same
  # document declares.
  defp declared_sibling(destination, literal) do
    case Ash.Resource.Info.domain(destination) do
      nil ->
        nil

      domain ->
        domain
        |> Ash.Domain.Info.resources()
        |> Enum.find(&(AshHateoas.Resource.Info.type(&1) == literal))
    end
  end

  # Named per owning property rather than per member class, because two
  # properties may target the same class through different relationships and a
  # future member assertion (a filter, a subject) could distinguish them.
  defp collection_class_iri(resource, name) do
    type = AshHateoas.Resource.Info.type(resource)
    Context.vocab_iri("#{Macro.camelize(to_string(type))}#{Macro.camelize(to_string(name))}")
  end

  @doc """
  Declarations for the two report classes and their properties.

  `ValidationReport` and `ValidationError` describe what a document action gives
  back: a verdict and, when it is negative, one entry per problem. Not the
  resource — a validate writes nothing and has no record to return, and a save
  reports failures the same way rather than returning the aggregate it did not
  write. They are declared because the alternative is a client hardcoding the
  shape from having read the source, which is what both consumers did.

  They derive from no resource — no table, no identity, no routes — so the
  resource walk above reaches neither them nor their properties.

  Called by `AshHateoas.Hydra.ApiDocumentation` only when something actually
  returns a report. A class nothing references is noise, and so are its
  properties, so the whole group appears together or not at all.
  """
  @spec report_properties() :: [map()]
  def report_properties do
    report = Context.vocab_iri("ValidationReport")
    error = Context.vocab_iri("ValidationError")

    [
      %{
        "@id" => "ah:ValidationReport",
        "@type" => ["owl:Class", "hydra:Class"],
        "rdfs:subClassOf" => %{"@id" => "hydra:Resource"},
        "rdfs:isDefinedBy" => %{"@id" => Context.vocab_iri("")}
      },
      %{
        "@id" => "ah:ValidationError",
        "@type" => ["owl:Class", "hydra:Class"],
        "rdfs:subClassOf" => %{"@id" => "hydra:Resource"},
        "rdfs:isDefinedBy" => %{"@id" => Context.vocab_iri("")}
      },
      datatype_property("validationReport", "valid?", report, "xsd:boolean"),
      # An array of report entries. `rdfs:range` names the container, and
      # `sh:class` names what goes in it — the member class is not something
      # `rdfs:range` can express here, since the property's values are arrays
      # rather than errors.
      %{
        "@id" => Context.property_iri("validationReport", "errors"),
        "@type" => "owl:ObjectProperty",
        "rdfs:domain" => %{"@id" => report},
        "rdfs:range" => %{"@id" => "jsonschema:ArraySchema"},
        "rdfs:isDefinedBy" => %{"@id" => Context.vocab_iri("")}
      },
      datatype_property("validationError", "index", error, "xsd:integer"),
      datatype_property("validationError", "kind", error, "xsd:string"),
      datatype_property("validationError", "name", error, "xsd:string"),
      datatype_property("validationError", "field", error, "xsd:string"),
      datatype_property("validationError", "message", error, "xsd:string")
    ]
  end

  defp datatype_property(owner, name, domain, range) do
    %{
      "@id" => Context.property_iri(owner, name),
      "@type" => "owl:DatatypeProperty",
      "rdfs:domain" => %{"@id" => domain},
      "rdfs:range" => %{"@id" => range},
      "rdfs:label" => name,
      "rdfs:isDefinedBy" => %{"@id" => Context.vocab_iri("")}
    }
  end

  @doc """
  A polymorphic range: `owl:Class` with `owl:unionOf`.

  Two traps here, both of which fail a validator rather than degrade quietly.
  The OWL 2 RDF mapping emits `ObjectUnionOf` as **two** triples, so the blank
  node must carry `rdf:type owl:Class` — without it an OWL parser rejects the
  node. And `owl:unionOf` takes an **`rdf:List`**, whereas a plain JSON-LD array
  has unordered-set semantics and expands to independent triples rather than an
  `rdf:first`/`rdf:rest` chain, so `@list` coercion is required.

  Nothing in this package emits a union range today: with a base table, a
  reference has a single class range and needs none. It is here because
  `ash_hateoas` is generic and some domain will have a genuinely polymorphic
  property.

  Where the union is an *expectation* rather than a guarantee, prefer
  `schema:rangeIncludes` repeated per class — no blank node, no list, no
  entailment. That is what schema.org itself does for this problem.
  """
  @spec union_range([String.t()]) :: map()
  def union_range(class_iris) when is_list(class_iris) do
    %{
      "@type" => "owl:Class",
      "owl:unionOf" => %{"@list" => Enum.map(class_iris, &%{"@id" => &1})}
    }
  end

  defp public_attributes(resource) do
    Ash.Resource.Info.public_attributes(resource)
  rescue
    _ -> []
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
