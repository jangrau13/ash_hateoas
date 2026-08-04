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

    test "each declared term names the ontology that defines it" do
      # `X rdfs:isDefinedBy Y` means *Y defines X*. Hanging the declarations off
      # the ApiDocumentation would have said the documentation is defined by the
      # Recipe class — backwards. Pointed this way it is true.
      recipe = declared("#{@vocab}Recipe")
      assert recipe["rdfs:isDefinedBy"] == %{"@id" => @vocab}
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
        ah:identity
        ah:SaveAction
        ah:RunAction
        ah:ValidationReport
        ah:ValidationError
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
