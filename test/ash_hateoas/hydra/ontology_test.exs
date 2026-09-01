defmodule AshHateoas.Hydra.OntologyTest do
  @moduledoc """
  The `@included` block declares the vocabulary the documentation references.

  Most assertions here read the emitted JSON, which is the convenient way to say
  "this node declares that superclass". The last section does **not**: it expands
  the document with a real processor (`AshHateoas.Test.JsonLd`), because a whole
  class of defect is invisible to the first kind and has shipped twice.

  A DL reasoner is still not a dependency, so "loads without an unsatisfiable
  class" remains recorded in `documentation/hydra-conformance-notes.md` rather
  than asserted.
  """

  use ExUnit.Case, async: true

  alias AshHateoas.Hydra.ApiDocumentation
  alias AshHateoas.Test.JsonLd

  @vocab "https://ash-hateoas.org/vocab#"

  defp included do
    ApiDocumentation.build([AshHateoas.Test.Domain])["@included"]
  end

  defp declared(id) do
    Enum.find(included(), &(&1["@id"] == id))
  end

  defp types(node), do: node |> Map.get("@type") |> List.wrap()

  describe "the ontology declares itself" do
    test "the block names the ontology every term points back at" do
      assert declared(@vocab)["@type"] == "owl:Ontology"
    end

    test "no term restates where it is defined" do
      # `X rdfs:isDefinedBy Y` earns its place where a term IRI does not say
      # where its definition lives: `http://purl.org/dc/terms/title` is a
      # **slash** IRI, and no mechanical rule takes it to
      # `http://purl.org/dc/terms/`.
      #
      # This package mints **hash** IRIs, so RDF's own rule already answers it —
      # the part before the fragment is the document. Every term carried the
      # triple anyway, all with the same value, and it was 232 of 237 nodes in a
      # captured document.
      carriers = Enum.filter(included(), &Map.has_key?(&1, "rdfs:isDefinedBy"))

      assert carriers == [],
             "#{length(carriers)} nodes restate their own namespace: " <>
               inspect(Enum.map(carriers, & &1["@id"]))
    end

    test "the rule it restated still answers the question" do
      # What a consumer does instead, and why dropping the triple loses nothing:
      # truncate at the fragment and the answer is the ontology node the same
      # document declares.
      recipe = declared("#{@vocab}Recipe")

      assert [namespace, _fragment] = String.split(recipe["@id"], "#", parts: 2)
      assert declared(namespace <> "#")["@type"] == "owl:Ontology"
    end
  end

  describe "classes" do
    test "a class is declared under both readings" do
      # `owl:Class` answers "what is this?"; `hydra:Class` answers "may a client
      # expect the API to describe it?". Neither implies the other — verified
      # against the vocabulary, where `hydra:Class` is `rdfs:subClassOf
      # rdfs:Class` and OWL appears nowhere in the specification at all.
      assert types(declared("#{@vocab}Recipe")) == ["owl:Class", "hydra:Class"]
    end

    test "a semantic type yields a subclass, never an equivalence" do
      person = declared("#{@vocab}Person")

      # Equivalence would assert the two are the same set and license
      # substitution in both directions, so a reasoner could conclude things
      # about schema.org's class from statements about ours. A local Person has
      # an id, a tenant and domain rules `schema:Person` knows nothing of.
      assert person["rdfs:subClassOf"] == %{"@id" => "https://schema.org/Person"}
      refute Map.has_key?(person, "owl:equivalentClass")
    end

    test "a class without a semantic type invents no superclass" do
      # Every OWL class is trivially a subclass of `owl:Thing`, so the triple
      # entails nothing; and `@type: owl:Class` already tells a consumer this is
      # a class. With nothing true to say, nothing is said.
      recipe = declared("#{@vocab}Recipe")
      refute Map.has_key?(recipe, "rdfs:subClassOf")
    end

    test "the borrowed Hydra terms are declared as OWL entities" do
      # OWL 2 §5.8.2 wants every IRI occurring in an axiom declared, and Hydra
      # declares none of its terms in OWL — it has no OWL layer. Without this
      # the class hierarchy is triples a reasoner may ignore.
      assert declared("hydra:Class")["@type"] == "owl:Class"
      assert declared("hydra:Link")["@type"] == "owl:Class"
    end
  end

  describe "properties" do
    test "a relationship is an object property that is also a link" do
      # Both types earn their place: the first says the values are individuals
      # rather than literals, the second that they are meant to be fetched. A
      # foreign key by id would be `owl:ObjectProperty` alone — a distinction
      # `@type: hydra:Link` on its own could not express.
      steps = declared("#{@vocab}recipe/steps")

      assert types(steps) == ["owl:ObjectProperty", "hydra:Link"]
      assert steps["rdfs:domain"] == %{"@id" => "#{@vocab}Recipe"}
    end

    test "a to-many ranges over a collection class, not over its members" do
      # The value of `recipe.steps` is a collection, not a Step — and
      # `rdfs:range` is an assertion about every value the property takes
      # (rdfs3). Naming `#Step` here would have a reasoner conclude the
      # collection *is* a Step.
      steps = declared("#{@vocab}recipe/steps")
      assert steps["rdfs:range"] == %{"@id" => "#{@vocab}RecipeSteps"}
    end

    test "a to-one ranges over the destination class directly" do
      document = declared("#{@vocab}comment/document")

      assert types(document) == ["owl:ObjectProperty", "hydra:Link"]
      assert document["rdfs:range"] == %{"@id" => "#{@vocab}Document"}
    end

    test "a scalar is a datatype property with an XSD range" do
      title = declared("#{@vocab}recipe/title")

      assert title["@type"] == "owl:DatatypeProperty"
      assert title["rdfs:range"] == %{"@id" => "xsd:string"}
      assert title["rdfs:domain"] == %{"@id" => "#{@vocab}Recipe"}
    end

    test "the member class is stated once, on the collection class" do
      # `sh:class` on a SupportedProperty says "a value *here* must be a Step",
      # restated wherever the property appears. The collection class says it
      # once, in the spec's own pattern for a strongly typed collection: every
      # member has `rdf:type #Step`.
      collection = declared("#{@vocab}RecipeSteps")

      assert collection["rdfs:subClassOf"] == %{"@id" => "hydra:Collection"}

      assert collection["hydra:memberAssertion"] == %{
               "hydra:property" => %{"@id" => "rdf:type"},
               "hydra:object" => %{"@id" => "#{@vocab}Step"}
             }
    end

    test "a member assertion uses exactly two of subject, property and object" do
      # The spec is normative here: "A memberAssertion MUST use two and only two
      # of the subject, property and object predicates." `hydra:subject` is the
      # third and stays absent — it names one specific parent record, which is
      # an instance-level fact and wrong on a class.
      assertion = declared("#{@vocab}RecipeSteps")["hydra:memberAssertion"]

      assert map_size(assertion) == 2
      refute Map.has_key?(assertion, "hydra:subject")
    end

    test "each to-many gets its own collection class" do
      # Named per owning property rather than per member class: two properties
      # may target the same class through different relationships, and a future
      # assertion could distinguish them. Both Article and Document hold
      # comments.
      assert declared("#{@vocab}ArticleComments")
      assert declared("#{@vocab}DocumentComments")

      for iri <- ["#{@vocab}ArticleComments", "#{@vocab}DocumentComments"] do
        assert declared(iri)["hydra:memberAssertion"]["hydra:object"] ==
                 %{"@id" => "#{@vocab}Comment"}
      end
    end

    test "a narrowed relationship asserts the class it narrows to" do
      # `Article has_many :reviews, Comment, filter: expr(kind == :review)`. The
      # filter states the real member class; without reading it the collection
      # can only report the destination, which every narrowing of one base
      # shares.
      assert declared("#{@vocab}ArticleReviews")["hydra:memberAssertion"] == %{
               "hydra:property" => %{"@id" => "rdf:type"},
               "hydra:object" => %{"@id" => "#{@vocab}Review"}
             }
    end

    test "two collections over one destination differ in what they assert" do
      # The defect this rule fixes, stated as the property that would catch it:
      # narrowed collections were byte-identical apart from `rdfs:label`, so a
      # client was told each holds a Comment — true of all of them, and
      # therefore distinguishing none. A label is not a claim.
      reviews = declared("#{@vocab}ArticleReviews")
      comments = declared("#{@vocab}ArticleComments")

      refute reviews["rdfs:label"] == comments["rdfs:label"]
      refute reviews["hydra:memberAssertion"] == comments["hydra:memberAssertion"]
    end

    test "a literal naming no declared class falls back to the destination" do
      # `filter: expr(kind == :reply)` pins the attribute, but nothing declares
      # a `reply` class — so asserting `#Reply` would mint an IRI the document
      # never defines, which is the defect this whole module exists to remove.
      # The destination is weaker and never wrong.
      assert declared("#{@vocab}ArticleReplies")["hydra:memberAssertion"]["hydra:object"] ==
               %{"@id" => "#{@vocab}Comment"}
    end

    test "a filter that pins nothing falls back to the destination" do
      # `filter: expr(score > 5)` constrains members without giving them a
      # common class. Only an equation to a single literal licenses the stronger
      # claim — the same rule `rdfs:range` follows, since rdfs3 makes a member
      # assertion an assertion rather than a hint.
      assert declared("#{@vocab}ArticleTopComments")["hydra:memberAssertion"]["hydra:object"] ==
               %{"@id" => "#{@vocab}Comment"}
    end
  end

  describe "the ah: vocabulary declares itself" do
    test "identity is an annotation, not a data property" do
      # Its subject is a *class* IRI and its value is metadata. Typed as an
      # object or datatype property it would assert a data fact about an entity
      # being used as a property — a pun with no upside.
      assert declared("ah:identity")["@type"] == "owl:AnnotationProperty"
    end

    test "targetKind is gone, replaced by two standard terms" do
      # It said "this property is to-many" in a minted term, while the member
      # class sat separately on `sh:class`. `rdfs:range` pointing at a
      # `hydra:Collection` subclass with a `hydra:memberAssertion` says both,
      # and says how they relate.
      refute declared("ah:targetKind")
      assert declared("#{@vocab}RecipeSteps")["rdfs:subClassOf"] == %{"@id" => "hydra:Collection"}
    end

    test "identity makes no owl:hasKey claim" do
      # `owl:hasKey` is a class axiom taking an `rdf:List`, so it cannot sit on
      # a property node. Worse, it licenses inferring `owl:sameAs` between
      # individuals sharing key values — and `ah:identity` names a *business*
      # key, so two records legitimately sharing a name would be merged and
      # their properties unioned. That is the corruption the term prevents.
      identity = declared("ah:identity")

      refute Map.has_key?(identity, "rdfs:subPropertyOf")
      refute identity["@type"] == "owl:hasKey"
    end

    test "the action roles are classes under their nearest published term" do
      assert declared("ah:SaveAction")["rdfs:subClassOf"] == %{"@id" => "schema:UpdateAction"}
      assert declared("ah:RunAction")["rdfs:subClassOf"] == %{"@id" => "schema:Action"}
    end

    test "every action a resource routes gets a declared class" do
      # An operation's `@type` references one of these, and this module exists
      # so that every IRI a document references is declared — so without them
      # its own invariant breaks on the very first operation.
      publish = declared("#{@vocab}Article/publishAction")

      assert publish["@type"] == "owl:Class"
      # The domain's own word, which is what an author reads on a button. It
      # moved here from `ah:action` on every operation: a label is a fact about
      # the class, so it is stated once against the class.
      assert publish["rdfs:label"] == "publish"
    end

    test "a declared semantic_action is the action class's superclass" do
      # What `schema:potentialAction` used to say per operation, said once and
      # said as an axiom — so the chain runs from the operation's class up into
      # schema.org's own hierarchy.
      assert declared("#{@vocab}Recipe/validateAction")["rdfs:subClassOf"] ==
               %{"@id" => "https://schema.org/CheckAction"}

      assert declared("#{@vocab}Recipe/saveAction")["rdfs:subClassOf"] ==
               %{"@id" => "#{@vocab}SaveAction"}
    end

    test "an action with no declared role has no superclass" do
      # There is deliberately no default. Every OWL class is trivially a
      # subclass of `owl:Thing`, and a subtype inferred from the HTTP method
      # would be a second spelling of `hydra:method`.
      refute Map.has_key?(declared("#{@vocab}Article/createAction"), "rdfs:subClassOf")
    end

    test "a route mints no class beneath its action" do
      # It was minted for a while and withdrawn. For an action with one route —
      # most of them — the subclass had exactly its parent's members, added no
      # property and constrained nothing: in a vocabulary, a node saying a thing
      # is itself. And the segment was an Ash route kind that spells like an HTTP
      # method, so `Article/readAction/get` read as "reading an article is a kind
      # of GET" — the inference `renderer.ex` refuses to draw when it declines to
      # derive `schema:ReadAction` from a GET.
      refute declared("#{@vocab}Article/readAction/get")
      refute declared("#{@vocab}Article/readAction/index")

      # Swept, not sampled: nothing anywhere is named `<something>Action/<word>`.
      leftovers = Enum.filter(included(), &(&1["@id"] =~ ~r{Action/[a-z_]+$}))

      assert leftovers == [], inspect(Enum.map(leftovers, & &1["@id"]))
    end

    test "the two routes onto one read name one class" do
      # Which is correct — they invoke the same action. What separates them is
      # where the request goes and what comes back, and the catalogue states
      # both: see `api_documentation_test.exs`.
      classes = ApiDocumentation.build([AshHateoas.Test.Domain])["hydra:supportedClass"]

      # One is filed under `Article`, the other under `Article/Collection` — a
      # read at `/articles` is not something one article does. Both name the same
      # action class, which is the point.
      reads =
        for class <- classes,
            class["@id"] in ["#{@vocab}Article", "#{@vocab}Article/Collection"],
            op <- class["hydra:supportedOperation"] || [],
            "#{@vocab}Article/readAction" in op["@type"],
            do: op

      assert length(reads) == 2
      assert reads |> Enum.map(& &1["@type"]) |> Enum.uniq() |> length() == 1
    end

    test "every class an operation's @type names is declared" do
      # The invariant, swept rather than sampled: a class referenced and never
      # declared is the defect this module removes.
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])
      declared_ids = MapSet.new(doc["@included"], & &1["@id"])

      referenced =
        for class <- doc["hydra:supportedClass"],
            operation <- List.wrap(class["hydra:supportedOperation"]),
            iri <- List.wrap(operation["@type"]),
            String.starts_with?(iri, @vocab),
            do: iri

      assert referenced != [], "no operation named a class; the sweep would assert nothing"

      undeclared = referenced |> Enum.uniq() |> Enum.reject(&MapSet.member?(declared_ids, &1))

      assert undeclared == [], "operation classes used but not declared: #{inspect(undeclared)}"
    end

    test "href is an object property from an Operation to the resource it acts on" do
      # Hydra gives `Operation` no target-URL property, so a named sub-action's
      # own URL has nowhere standard to go. An **object** property, because the
      # value is the resource the request is sent to — a reasoner should read an
      # edge to it, not a note about the operation node.
      href = declared("ah:href")

      assert href["@type"] == "owl:ObjectProperty"
      assert href["rdfs:domain"] == %{"@id" => "hydra:Operation"}
      assert href["rdfs:range"] == %{"@id" => "hydra:Resource"}
    end

    test "the entities ah:href's axioms mention are themselves declared" do
      # OWL 2 §5.8.2 wants every IRI occurring in an axiom declared, and Hydra
      # has no OWL layer to do it — so a domain of `hydra:Operation` obliges us.
      assert declared("hydra:Operation")["@type"] == "owl:Class"
      assert declared("hydra:Resource")["@type"] == "owl:Class"
    end

    test "template is href's catalogue-side twin, and ranges over an IriTemplate" do
      # A node states the address it resolved; the documentation describes a
      # class, where there is no record to resolve against and the honest
      # statement is how to build one. An object property for the same reason
      # `ah:href` is one: the value is a resource — a template node with its own
      # mappings — rather than a note about the operation.
      template = declared("ah:template")

      assert template["@type"] == "owl:ObjectProperty"
      assert template["rdfs:domain"] == %{"@id" => "hydra:Operation"}
      assert template["rdfs:range"] == %{"@id" => "hydra:IriTemplate"}

      # And the entities that axiom mentions, by the same rule as above.
      assert declared("hydra:IriTemplate")["@type"] == "owl:Class"
    end
  end

  describe "a resource's own collection class" do
    test "a resource served at a collection URL has one" do
      # `GET /articles` answers with a `hydra:Collection`, and the catalogue
      # entry for that route names this class. Reached from the resource, where
      # `collection_class/3` is reached from a to-many relationship — which is
      # why `#{@vocab}CourseExams` existed and `#{@vocab}Article/Collection` did
      # not, though both describe a collection served at a URL.
      collection = declared("#{@vocab}Article/Collection")

      assert types(collection) == ["owl:Class", "hydra:Class"]
      assert collection["rdfs:subClassOf"] == %{"@id" => "hydra:Collection"}

      assert collection["hydra:memberAssertion"] == %{
               "hydra:property" => %{"@id" => "rdf:type"},
               "hydra:object" => %{"@id" => "#{@vocab}Article"}
             }
    end

    test "hydra:Collection itself is declared" do
      # It has been the superclass of every to-many's collection class from the
      # start and was never declared — the gap this module exists to close, in
      # the one place the module was not looking at itself.
      assert declared("hydra:Collection")["@type"] == "owl:Class"
    end

    test "one is minted exactly where a collection route is served" do
      # Both directions, because either alone is satisfiable by a wrong answer: a
      # class nothing references is noise, and a route whose `hydra:returns`
      # names an undeclared class is the dangling IRI this module exists to
      # remove. Every resource in the fixture domain happens to have an `:index`
      # route today, so a one-directional test on the absent case would assert
      # nothing at all.
      expected =
        for {type, resource} <- AshHateoas.Index.build([AshHateoas.Test.Domain]),
            Enum.any?(AshHateoas.Resource.Info.routes(resource), &(&1.type == :index)),
            do: AshHateoas.Hydra.Context.collection_class_iri(type)

      minted =
        included()
        |> Enum.map(& &1["@id"])
        |> Enum.filter(&String.ends_with?(&1, "/Collection"))

      assert expected != []
      assert Enum.sort(minted) == Enum.sort(expected)
    end

    test "every collection class the catalogue returns is declared here" do
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])
      declared_ids = MapSet.new(doc["@included"], & &1["@id"])

      returned =
        for class <- doc["hydra:supportedClass"],
            op <- class["hydra:supportedOperation"] || [],
            iri = op["hydra:returns"]["@id"],
            String.ends_with?(iri, "/Collection"),
            do: iri

      assert returned != []
      assert Enum.reject(returned, &MapSet.member?(declared_ids, &1)) == []
    end
  end

  describe "no referenced class property dangles" do
    test "every property used by a supportedClass is declared" do
      # The defect this module exists to remove. An operation's *arguments* are
      # excluded deliberately — an argument is not a property of a class, and
      # asserting `rdfs:domain` for one would state something false.
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])
      declared_ids = MapSet.new(doc["@included"], &String.replace(&1["@id"], "ah:", @vocab))

      used =
        for class <- doc["hydra:supportedClass"],
            property <- List.wrap(class["hydra:supportedProperty"]),
            id = property_id(property),
            String.starts_with?(id, @vocab),
            do: id

      assert used != [], "expected the documentation to reference some property IRIs"

      dangling = Enum.reject(used, &MapSet.member?(declared_ids, &1))
      assert dangling == [], "undeclared property IRIs: #{inspect(Enum.uniq(dangling))}"
    end

    defp property_id(%{"hydra:property" => %{"@id" => id}}), do: id
    defp property_id(%{"hydra:property" => id}) when is_binary(id), do: id
    defp property_id(_property), do: nil

    test "the report classes' own properties are declared too" do
      # They derive from no resource — no table, no identity, no routes — so the
      # resource walk never reaches them. Without their own declarations they
      # would be seven referenced-and-undeclared IRIs, the exact defect.
      assert declared("#{@vocab}validationReport/valid?")["rdfs:range"] ==
               %{"@id" => "xsd:boolean"}

      assert declared("#{@vocab}validationError/message")["rdfs:range"] ==
               %{"@id" => "xsd:string"}

      assert declared("#{@vocab}validationError/index")["rdfs:range"] ==
               %{"@id" => "xsd:integer"}
    end

    test "the report vocabulary is absent when nothing returns one" do
      # A class nothing references is noise, and so are its properties. They
      # appear together or not at all.
      included = ApiDocumentation.build([AshHateoas.Test.SilentDomain])["@included"]
      ids = MapSet.new(included, & &1["@id"])

      refute MapSet.member?(ids, "#{@vocab}validationReport/valid?")
      refute MapSet.member?(ids, "ah:ValidationReport")
    end
  end

  describe "a union range" do
    test "carries owl:Class and an rdf:List" do
      # Two traps, both of which fail a validator rather than degrade quietly.
      # The OWL 2 RDF mapping emits `ObjectUnionOf` as two triples, so the blank
      # node must carry `rdf:type owl:Class`; and `owl:unionOf` takes an
      # `rdf:List`, where a plain JSON-LD array has unordered-set semantics and
      # expands to independent triples rather than a first/rest chain.
      range = AshHateoas.Hydra.Ontology.union_range(["#{@vocab}Stock", "#{@vocab}Flow"])

      assert range["@type"] == "owl:Class"

      assert range["owl:unionOf"]["@list"] == [
               %{"@id" => "#{@vocab}Stock"},
               %{"@id" => "#{@vocab}Flow"}
             ]
    end
  end

  describe "the ah: vocabulary stays small" do
    test "every ah: term emitted is one of a known, declared few" do
      # A minted term is a maintenance debt: it must be declared, documented and
      # understood by every consumer. The whole point of this stage is that 88
      # IRIs accumulated because nothing counted them. This is the counter.
      #
      # Adding a term is allowed — extending this list is the deliberate act
      # that makes it so. Silently growing the vocabulary is not.
      known = ~w(
        ah:action
        ah:href
        ah:template
        ah:identity
        ah:SaveAction
        ah:RunAction
        ah:ValidationReport
        ah:ValidationError
        ah:Script
        ah:scriptLanguage
      )

      doc = ApiDocumentation.build([AshHateoas.Test.Domain])
      found = doc |> ah_terms() |> Enum.sort() |> Enum.uniq()

      assert found -- known == [],
             "undeclared ah: terms reached the wire: #{inspect(found -- known)}"
    end

    test "every ah: term used is declared in the ontology" do
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])
      declared_ids = MapSet.new(doc["@included"], & &1["@id"])

      undeclared =
        doc
        |> ah_terms()
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(declared_ids, &1))

      assert undeclared == [], "ah: terms used but not declared: #{inspect(undeclared)}"
    end

    # Every `ah:`-prefixed key, plus every `ah:`-prefixed value (a term used as
    # a `@type` or an `@id` rather than as a key).
    defp ah_terms(node) when is_map(node) do
      Enum.flat_map(node, fn {key, value} ->
        prefixed(key) ++ prefixed(value) ++ ah_terms(value)
      end)
    end

    defp ah_terms(list) when is_list(list), do: Enum.flat_map(list, &ah_terms/1)
    defp ah_terms(_other), do: []

    defp prefixed(value) when is_binary(value) do
      if String.starts_with?(value, "ah:"), do: [value], else: []
    end

    defp prefixed(_value), do: []
  end

  describe "the context carries no axioms" do
    test "no ah: term is defined with an rdfs: predicate" do
      # A `@context` maps terms to IRIs, and its object form admits JSON-LD
      # keywords only. An entry like
      # `"ah:SaveAction" => %{"rdfs:subClassOf" => …}` is an invalid term
      # definition, and a conformant processor rejects the **whole document**
      # rather than skipping it, so the ApiDocumentation would fail to expand
      # entirely. Invisible to a test asserting on raw JSON, where the entry
      # looks fine — hence this check.
      terms = Enum.find(AshHateoas.Hydra.Context.context(), &is_map/1)

      for {term, definition} <- terms, is_map(definition) do
        bad = for {k, _v} <- definition, not String.starts_with?(k, "@"), do: k

        assert bad == [],
               "#{term} carries non-keyword #{inspect(bad)} — invalid term definition"
      end
    end

    test "every prefix an emitted term uses is bound" do
      # An unbound prefix is *silently dropped* by a JSON-LD processor, so the
      # declarations would vanish with no error at all.
      terms = Enum.find(AshHateoas.Hydra.Context.context(), &is_map/1)

      for prefix <- ~w(ah owl rdf rdfs xsd schema sh jsonschema) do
        assert Map.has_key?(terms, prefix), "the #{prefix}: prefix is not bound"
      end
    end
  end

  describe "the ontology survives a real processor" do
    # Everything above reads the JSON. These read the graph, and the difference
    # is not academic: the two defects this package has shipped in this area —
    # four malformed `@context` term definitions, and record nodes binding no
    # terms — were both invisible to key-based assertions and both obvious after
    # one expansion.

    test "the document expands" do
      # The whole-document check the malformed term definitions failed for the
      # entire life of the package, while every assertion above passed.
      assert [_ | _] = JsonLd.expand(document())
    end

    test "expanding is idempotent" do
      # Catches `@list` coercion errors: a bare array where an `rdf:List` is
      # required expands to different, wrong triples — independent
      # `rdf:first`/`rdf:rest` statements instead of a chain. `owl:unionOf` and
      # `sh:in` both depend on this.
      once = JsonLd.expand(document())

      assert JsonLd.expand(%{"@context" => document()["@context"], "@graph" => once}) == once
    end

    test "every declared class really is typed owl:Class in the graph" do
      # The assertion above reads `"@type" => ["owl:Class", "hydra:Class"]` from
      # the JSON. That is a *string* until a processor resolves the `owl:`
      # prefix — and an unbound prefix is dropped in silence, taking the entire
      # OWL layer with it while the JSON still reads correctly.
      types =
        document()
        |> JsonLd.nodes()
        |> Enum.filter(&(&1["@id"] == "#{@vocab}Recipe"))
        |> Enum.flat_map(&List.wrap(&1["@type"]))

      assert "http://www.w3.org/2002/07/owl#Class" in types
      assert "http://www.w3.org/ns/hydra/core#Class" in types
    end

    test "a declared property carries a resolved domain and range" do
      # The JSON says `"rdfs:range" => %{"@id" => "xsd:string"}`. Both of those
      # are *strings* until a processor resolves the prefixes — and an unbound
      # prefix is dropped in silence, so this is what proves the declaration
      # became a triple rather than merely reading like one.
      # The same IRI also appears as a bare `{"@id"}` reference wherever the
      # property is *used* — that is the point of declaring it once. Take the
      # node that carries the declaration.
      property =
        document()
        |> JsonLd.nodes()
        |> Enum.find(&(&1["@id"] == "#{@vocab}recipe/title" and map_size(&1) > 1))

      assert JsonLd.values(property, "http://www.w3.org/2000/01/rdf-schema#domain") ==
               ["#{@vocab}Recipe"]

      assert JsonLd.values(property, "http://www.w3.org/2000/01/rdf-schema#range") ==
               ["http://www.w3.org/2001/XMLSchema#string"]
    end

    test "narrowed collections differ as triples, not merely as labels" do
      # The comparison nobody made. Read as JSON, two narrowings of one
      # destination were byte-identical apart from `rdfs:label` — and a label is
      # an annotation a reasoner ignores as logical content, so on the graph the
      # two collections said *exactly* the same thing about their members.
      #
      # Asserted here rather than only above because that is where the failure
      # lived: the raw JSON differed (by the label), so a key-based comparison
      # could pass while the claim being made was identical.
      nodes = JsonLd.nodes(document())

      # The member assertion is a blank node — it has no `@id`, so its object
      # sits one level down rather than being reachable as a value. And the
      # collection IRI appears twice: once as a bare reference from the property
      # that ranges on it, once carrying the declaration. Take the second, the
      # same way the `recipe/title` test above does.
      member_of = fn iri ->
        nodes
        |> Enum.find(&(&1["@id"] == iri and map_size(&1) > 1))
        |> Map.fetch!("http://www.w3.org/ns/hydra/core#memberAssertion")
        |> Enum.flat_map(&JsonLd.values(&1, "http://www.w3.org/ns/hydra/core#object"))
      end

      assert member_of.("#{@vocab}ArticleReviews") == ["#{@vocab}Review"]
      assert member_of.("#{@vocab}ArticleComments") == ["#{@vocab}Comment"]
    end

    test "no CLASS property the documentation references is undeclared" do
      # The dangling-IRI check, made on the graph rather than the JSON: it is
      # what proves the declarations actually became triples.
      #
      # Scoped to `supportedClass` deliberately. An operation's **input**
      # properties are minted under our vocab and declared nowhere, and that is
      # the standing decision from the ontology work: an argument is not a
      # property of any class — `approve` takes a `note`, a Document does not
      # *have* one — so there is nothing true to declare about it. Those keep
      # their `sh:datatype` for exactly this reason. Measured: every undeclared
      # property IRI in the document sits under `hydra:expects`.
      nodes = JsonLd.nodes(document())

      declared =
        nodes
        |> Enum.filter(&(&1["@id"] && String.starts_with?(&1["@id"], @vocab) && &1["@type"]))
        |> MapSet.new(& &1["@id"])

      referenced =
        document()
        |> Map.get("hydra:supportedClass")
        |> List.wrap()
        |> Enum.flat_map(&List.wrap(&1["hydra:supportedProperty"]))
        |> Enum.map(&get_in(&1, ["hydra:property", "@id"]))
        |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, @vocab)))
        |> MapSet.new()

      assert MapSet.size(referenced) > 0, "found no class properties to check"

      dangling = MapSet.difference(referenced, declared)

      assert MapSet.size(dangling) == 0,
             "referenced by a supportedClass but never declared: #{inspect(MapSet.to_list(dangling))}"
    end
  end

  defp document, do: ApiDocumentation.build([AshHateoas.Test.Domain])
end
