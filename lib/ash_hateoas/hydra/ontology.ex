defmodule AshHateoas.Hydra.Ontology do
  @moduledoc """
  Declares the vocabulary the `ApiDocumentation` uses.

  The documentation mints a property IRI for every attribute and relationship
  (`…#flow/model`, `…#converter/name`) and, until this module, said nothing
  about any of them. Every occurrence was a *reference*: a client could see that
  `flow/model` was used, and had nowhere to learn what it was.

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
      # An annotation, not a fact about an individual. Its subject is a
      # *property* IRI and its value is metadata ("Collection"). Typed as an
      # object or datatype property it would assert a data fact about an entity
      # being used as a property — a pun with no upside. Annotation properties
      # are exempt from that machinery; that is what they are for.
      %{
        "@id" => "ah:targetKind",
        "@type" => "owl:AnnotationProperty",
        "rdfs:isDefinedBy" => %{"@id" => Context.vocab_iri("")}
      },
      # Likewise an annotation — and deliberately **not** `rdfs:subPropertyOf
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
      # What a document action gives back: a verdict and, when it is negative,
      # one entry per problem. It is not the resource — a validate writes
      # nothing and has no record to return, and a save reports failures the
      # same way rather than returning the aggregate it did not write.
      #
      # Declared because the alternative is a client hardcoding the shape from
      # having read the source, which is what both consumers did.
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
      # `hydra:Resource` is the superclass those two name, and OWL 2 §5.8.2 wants
      # every IRI in an axiom declared.
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
    attribute_nodes(resource, type) ++ relationship_nodes(resource, type)
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
  # the value is *meant to be fetched* — the transport question. A foreign key
  # by id would be `owl:ObjectProperty` alone, a distinction the old encoding
  # (`@type: hydra:Link` and nothing else) could not express.
  #
  # `rdfs:range` replaces the per-usage `sh:class`. The range is a fact about
  # the property and belongs on it; `sh:class` restated the same target at every
  # site it appeared, which is a shape that permits drift.
  defp relationship_nodes(resource, type) do
    routed = MapSet.new(routes(resource), & &1.relationship)

    to_many =
      resource
      |> routes()
      |> Enum.filter(&(&1.type == :related))
      |> Enum.map(& &1.relationship)

    to_one =
      resource
      |> Ash.Resource.Info.public_relationships()
      |> Enum.filter(&(&1.cardinality == :one and &1.name not in routed))
      |> Enum.map(& &1.name)

    Enum.map(to_many ++ to_one, fn name ->
      %{
        "@id" => Context.property_iri(type, name),
        "@type" => ["owl:ObjectProperty", "hydra:Link"],
        "rdfs:domain" => %{"@id" => Context.class_iri(type)},
        "rdfs:isDefinedBy" => %{"@id" => Context.vocab_iri("")}
      }
      |> put_unless_nil("rdfs:range", relationship_range(resource, name))
      |> put_unless_nil("rdfs:label", to_string(name))
    end)
  end

  # The class a relationship points at. A destination carrying no type is not
  # addressable as a node, so the property is declared without a range rather
  # than with a bogus one — a consumer degrades to an untyped-but-followable
  # link instead of resolving to nothing.
  defp relationship_range(resource, name) do
    with %{destination: destination} <- Ash.Resource.Info.relationship(resource, name),
         destination_type when is_binary(destination_type) <-
           AshHateoas.Resource.Info.type(destination) do
      %{"@id" => Context.class_iri(destination_type)}
    else
      _ -> nil
    end
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

  defp routes(resource) do
    AshHateoas.Resource.Info.routes(resource)
  rescue
    _ -> []
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
