defmodule AshHateoas.Hydra.ApiDocumentationTest do
  @moduledoc """
  The ApiDocumentation derives entirely from resource introspection + routes.
  """

  use ExUnit.Case, async: true

  alias AshHateoas.Hydra.ApiDocumentation

  test "builds an ApiDocumentation with entrypoint and a supportedClass per resource" do
    doc =
      ApiDocumentation.build([AshHateoas.Test.Domain],
        entrypoint: "/api",
        id: "/api/doc"
      )

    assert doc["@type"] == "ApiDocumentation"
    assert doc["hydra:entrypoint"] == "/api"
    assert doc["@id"] == "/api/doc"
    assert is_list(doc["hydra:supportedClass"])
    assert doc["@context"] |> List.first() == "http://www.w3.org/ns/hydra/context.jsonld"
  end

  test "the document class carries supportedProperty and supportedOperation" do
    doc = ApiDocumentation.build([AshHateoas.Test.Domain])

    document =
      Enum.find(
        doc["hydra:supportedClass"],
        &(&1["@id"] == "https://ash-hateoas.org/vocab#Document")
      )

    assert document, "expected a Document class in supportedClass"
    assert document["@type"] == "Class"

    prop_ids =
      document["hydra:supportedProperty"]
      |> Enum.map(& &1["hydra:property"]["@id"])

    assert "https://ash-hateoas.org/vocab#document/title" in prop_ids

    methods =
      document["hydra:supportedOperation"]
      |> Enum.map(& &1["hydra:method"])
      |> Enum.uniq()

    # Derived from the routed actions: read/create/update/approve/...
    assert "GET" in methods
    assert "POST" in methods
    assert "PATCH" in methods

    # a non-GET operation names what it returns (the resource's own class)
    write = Enum.find(document["hydra:supportedOperation"], &(&1["hydra:method"] == "POST"))
    assert write["hydra:returns"] == %{"@id" => "https://ash-hateoas.org/vocab#Document"}
  end

  test "a semantic type yields a companion supportedClass keyed by the schema.org IRI" do
    doc = ApiDocumentation.build([AshHateoas.Test.Domain])
    classes = doc["hydra:supportedClass"]

    vocab =
      Enum.find(classes, &(&1["@id"] == "https://ash-hateoas.org/vocab#Person"))

    companion =
      Enum.find(classes, &(&1["@id"] == "https://schema.org/Person"))

    # both the vocab# class and its schema.org companion are present, so a node
    # dual-typed [vocab#Person, schema:Person] resolves to a class under either.
    assert vocab, "expected the vocab# Person class"
    assert companion, "expected a schema.org Person companion class"

    # Neither claims equivalence. The companion is a *description* keyed by the
    # well-known IRI so a client indexing by it finds a described class — not an
    # assertion that the two classes are the same set, which is what
    # `owl:equivalentClass` meant and which is almost never true.
    refute Map.has_key?(vocab, "owl:equivalentClass")
    refute Map.has_key?(companion, "owl:equivalentClass")

    # The relation is stated once, in the ontology, and only in the direction
    # that holds: a local Person is a schema.org Person.
    declared =
      Enum.find(doc["@included"], &(&1["@id"] == "https://ash-hateoas.org/vocab#Person"))

    assert declared["rdfs:subClassOf"] == %{"@id" => "https://schema.org/Person"}

    # the companion is fully described, not a stub — it carries the operations
    assert is_list(companion["hydra:supportedOperation"])
    assert companion["hydra:supportedProperty"] == vocab["hydra:supportedProperty"]
  end

  test "a resource without a semantic type yields exactly one supportedClass entry" do
    doc = ApiDocumentation.build([AshHateoas.Test.Domain])

    document_entries =
      Enum.filter(
        doc["hydra:supportedClass"],
        &(&1["@id"] == "https://ash-hateoas.org/vocab#Document")
      )

    assert length(document_entries) == 1
  end

  test "a to-many relationship is advertised as a hydra:Link supported property" do
    doc = ApiDocumentation.build([AshHateoas.Test.Domain])

    article =
      Enum.find(
        doc["hydra:supportedClass"],
        &(&1["@id"] == "https://ash-hateoas.org/vocab#Article")
      )

    link =
      Enum.find(
        article["hydra:supportedProperty"],
        &(&1["hydra:property"]["@id"] == "https://ash-hateoas.org/vocab#article/comments")
      )

    assert link, "expected a comments link property"
    # the property node is typed hydra:Link, so a client knows the key is a link
    assert link["hydra:property"]["@type"] == "hydra:Link"
    assert link["hydra:readable"] == true
    assert link["hydra:writable"] == false
  end

  describe "the affordance chain" do
    test "a writable link leads to the operations of the class it points at" do
      # What a client has to be able to do from the catalogue alone: holding a
      # Comment's create operation, discover that `document` is a link, that it
      # points at Document, and what may be done to a Document — so "the target
      # does not exist yet" has an answer that is itself an affordance.
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])

      classes = Map.new(doc["hydra:supportedClass"], &{&1["@id"], &1})
      properties = Map.new(doc["@included"], &{&1["@id"], &1})

      comment = classes["https://ash-hateoas.org/vocab#Comment"]

      # 1. the link property is on the class, typed and writable
      link =
        Enum.find(
          comment["hydra:supportedProperty"],
          &(&1["hydra:property"]["@id"] == "https://ash-hateoas.org/vocab#comment/document")
        )

      assert link["hydra:property"]["@type"] == "hydra:Link"
      assert link["hydra:writable"] == true

      # 2. the ontology says where it points
      property = properties[link["hydra:property"]["@id"]]
      assert "hydra:Link" in List.wrap(property["@type"])
      range = property["rdfs:range"]["@id"]
      assert range == "https://ash-hateoas.org/vocab#Document"

      # 3. the range class advertises its own operations — the chain closes,
      #    and it closes for every verb, not only create.
      target = classes[range]

      methods =
        target["hydra:supportedOperation"]
        |> Enum.map(& &1["hydra:method"])
        |> Enum.uniq()

      for verb <- ["GET", "POST", "PATCH", "DELETE"] do
        assert verb in methods, "expected the target class to advertise #{verb}"
      end
    end

    test "a write operation expects the LINK, never the foreign key" do
      # The catalogue has to describe the shape the write path actually takes.
      # Advertising `document_id: xsd:string` would tell a client to send a raw
      # id — the one thing the wire format does not carry.
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])

      comment =
        Enum.find(
          doc["hydra:supportedClass"],
          &(&1["@id"] == "https://ash-hateoas.org/vocab#Comment")
        )

      create = Enum.find(comment["hydra:supportedOperation"], &(&1["hydra:method"] == "POST"))
      expected = create["hydra:expects"]["hydra:supportedProperty"]
      titles = Enum.map(expected, & &1["hydra:title"])

      assert "document" in titles
      refute "document_id" in titles

      link = Enum.find(expected, &(&1["hydra:title"] == "document"))

      # Typed as an IRI: the client sends a node reference.
      assert link["sh:nodeKind"] == "sh:IRI"
      refute Map.has_key?(link, "sh:datatype")

      # And it is the same property the ontology declares, so the chain from
      # this input to the target class's operations is one lookup.
      assert link["hydra:property"]["@id"] == "https://ash-hateoas.org/vocab#comment/document"
    end

    test "a link a client cannot set is not advertised as writable" do
      # The other half: `writable` is a claim about this API's write path, so a
      # relationship no action manages must say so.
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])

      article =
        Enum.find(
          doc["hydra:supportedClass"],
          &(&1["@id"] == "https://ash-hateoas.org/vocab#Article")
        )

      link =
        Enum.find(
          article["hydra:supportedProperty"],
          &(&1["hydra:property"]["@id"] == "https://ash-hateoas.org/vocab#article/comments")
        )

      assert link["hydra:writable"] == false
    end
  end

  test "a link names the class it points at" do
    doc = ApiDocumentation.build([AshHateoas.Test.Domain])

    article =
      Enum.find(
        doc["hydra:supportedClass"],
        &(&1["@id"] == "https://ash-hateoas.org/vocab#Article")
      )

    link =
      Enum.find(
        article["hydra:supportedProperty"],
        &(&1["hydra:property"]["@id"] == "https://ash-hateoas.org/vocab#article/comments")
      )

    # Without a target class a link says only "followable", never "-> what",
    # which is not enough for a client to resolve the reference to a described
    # class. `article.comments` points at Comment — said once, on the property's
    # own declaration, rather than restated at every usage as `sh:class`.
    refute Map.has_key?(link["hydra:property"], "sh:class")

    # Cardinality is no longer marked here either. `ah:targetKind: "Collection"` said
    # in a minted term what the ontology's `rdfs:range` now says with two
    # standard ones: the property ranges over a `hydra:Collection` subclass
    # whose `hydra:memberAssertion` names the member class.
    refute Map.has_key?(link, "ah:targetKind")

    range =
      doc["@included"]
      |> Enum.find(&(&1["@id"] == "https://ash-hateoas.org/vocab#article/comments"))
      |> get_in(["rdfs:range", "@id"])

    assert range == "https://ash-hateoas.org/vocab#ArticleComments"
  end

  test "a to-one relationship is advertised as a hydra:Link supported property" do
    doc = ApiDocumentation.build([AshHateoas.Test.Domain])

    comment =
      Enum.find(
        doc["hydra:supportedClass"],
        &(&1["@id"] == "https://ash-hateoas.org/vocab#Comment")
      )

    link =
      Enum.find(
        comment["hydra:supportedProperty"],
        &(&1["hydra:property"]["@id"] == "https://ash-hateoas.org/vocab#comment/document")
      )

    # `Comment belongs_to :document` carries no route by design — a to-one is an
    # inline node reference, not a collection route — but it is still part of the
    # class's shape. Leaving it out left roughly half the graph edges undescribed
    # and invisible to any client deriving structure from the documentation.
    assert link, "expected a document link property for the belongs_to"
    assert link["hydra:property"]["@type"] == "hydra:Link"

    # The target is the property's declared range, not a per-usage constraint.
    refute Map.has_key?(link["hydra:property"], "sh:class")

    declared =
      Enum.find(doc["@included"], &(&1["@id"] == "https://ash-hateoas.org/vocab#comment/document"))

    assert declared["rdfs:range"] == %{"@id" => "https://ash-hateoas.org/vocab#Document"}

    # A to-one resolves to a single node, so it carries no collection marker.
    refute Map.has_key?(link, "ah:targetKind")
  end

  test "the raw foreign-key attribute stays alongside the link" do
    doc = ApiDocumentation.build([AshHateoas.Test.Domain])

    comment =
      Enum.find(
        doc["hydra:supportedClass"],
        &(&1["@id"] == "https://ash-hateoas.org/vocab#Comment")
      )

    titles = Enum.map(comment["hydra:supportedProperty"], & &1["hydra:title"])

    # The link is added, not substituted: `document_id` is a real writable
    # attribute a client still needs in order to set the relationship.
    assert "document_id" in titles
    assert "document" in titles
  end

  describe "ah:action" do
    test "an operation carries the action's own name" do
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])

      article =
        Enum.find(
          doc["hydra:supportedClass"],
          &(&1["@id"] == "https://ash-hateoas.org/vocab#Article")
        )

      names = Enum.map(article["hydra:supportedOperation"], & &1["ah:action"])

      # Hydra gives an operation no name of its own — it describes *how* to
      # invoke one, not what the domain calls it. `publish` is the only thing
      # that can label a button; "POST" cannot.
      assert "publish" in names
      assert "read" in names
    end

    test "two operations sharing a method are distinguishable" do
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])

      recipe =
        Enum.find(
          doc["hydra:supportedClass"],
          &(&1["@id"] == "https://ash-hateoas.org/vocab#Recipe")
        )

      posts =
        recipe["hydra:supportedOperation"]
        |> Enum.filter(&(&1["hydra:method"] == "POST"))
        |> Enum.map(& &1["ah:action"])

      # Three POSTs — create, validate and save. Without a name a client sees
      # three identical offers and cannot tell which one saves a document.
      assert "create" in posts
      assert "validate" in posts
      assert "save" in posts
      assert length(Enum.uniq(posts)) == length(posts)
    end
  end

  describe "the document operations declare what they are for" do
    defp recipe_operation(action) do
      [AshHateoas.Test.Domain]
      |> ApiDocumentation.build()
      |> Map.fetch!("hydra:supportedClass")
      |> Enum.find(&(&1["@id"] == "https://ash-hateoas.org/vocab#Recipe"))
      |> Map.fetch!("hydra:supportedOperation")
      |> Enum.find(&(&1["ah:action"] == action))
    end

    test "validate is a CheckAction, not a create" do
      # Both document operations are POSTs, so the type inferred from the method
      # is `CreateAction` for each — which says checking a document creates
      # something. Declaring the role is what lets a client tell them apart
      # without matching the string "validate", which is a naming convention
      # rather than anything the API states.
      assert recipe_operation("validate")["schema:potentialAction"]["@type"] ==
               "https://schema.org/CheckAction"
    end

    test "save is distinguishable from an ordinary record update" do
      # Not `schema:UpdateAction`, though that reads right in isolation: it is
      # already what any PATCH infers, so declaring it would make a document
      # save indistinguishable from updating one record. A term is only worth
      # declaring if it says something the inference does not.
      assert recipe_operation("save")["schema:potentialAction"]["@type"] ==
               "https://ash-hateoas.org/vocab#SaveAction"

      refute recipe_operation("save")["schema:potentialAction"]["@type"] ==
               recipe_operation("update")["schema:potentialAction"]["@type"]
    end

    test "the vocabulary relates both new terms to the nearest published one" do
      # So a client speaking only schema.org still learns something true: that
      # a save writes, and that a run is an action an agent performs.
      #
      # The axioms live in the ontology block, not in the `@context`. They were
      # in the context until the ontology work, as
      # `"ah:SaveAction" => %{"rdfs:subClassOf" => …}`, and that is an **invalid
      # term definition**: a context maps terms to IRIs and its object form
      # admits only JSON-LD keywords, so a conformant processor rejects the
      # whole document rather than skipping the entry. Every emitted
      # ApiDocumentation failed to expand.
      terms = Enum.find(AshHateoas.Hydra.Context.context(), &is_map/1)
      refute Map.has_key?(terms, "ah:SaveAction")
      refute Map.has_key?(terms, "ah:RunAction")

      included = ApiDocumentation.build([AshHateoas.Test.Domain])["@included"]
      declared = fn id -> Enum.find(included, &(&1["@id"] == id)) end

      assert declared.("ah:SaveAction")["rdfs:subClassOf"] == %{"@id" => "schema:UpdateAction"}
      assert declared.("ah:RunAction")["rdfs:subClassOf"] == %{"@id" => "schema:Action"}

      # And declared as classes, so the subclass axioms are load-bearing rather
      # than decorative — OWL 2 §5.8.2.
      assert declared.("ah:SaveAction")["@type"] == "owl:Class"
      assert declared.("ah:RunAction")["@type"] == "owl:Class"
    end

    test "the POSTs are told apart by role, not only by name" do
      types =
        for action <- ["create", "validate", "save", "cook"],
            do: recipe_operation(action)["schema:potentialAction"]["@type"]

      assert length(Enum.uniq(types)) == 4
    end

    test "an execute action carries a role schema.org has no term for" do
      # schema.org has nothing meaning "run this": `ControlAction` and
      # `ActivateAction` are device control, and `AchieveAction`'s subtypes are
      # Win/Lose/Tie. So the role is named in this package's vocabulary.
      #
      # Nothing about it is special-cased — `semantic_action` passes an absolute
      # IRI through verbatim, which is what makes a vocabulary this package does
      # not own expressible at all.
      assert recipe_operation("cook")["schema:potentialAction"]["@type"] ==
               "https://ash-hateoas.org/vocab#RunAction"
    end

    test "a resource declaring its own semantic_action keeps it" do
      # Generated as a default, like the actions themselves.
      assert %{validate: iri} =
               AshHateoas.Resource.Info.semantic_actions(AshHateoas.Test.Recipe)

      assert iri == "https://schema.org/CheckAction"
    end
  end

  describe "a document action returns a verdict, not the resource" do
    defp recipe_returns(action) do
      recipe_operation(action)["hydra:returns"]["@id"]
    end

    defp report_class do
      [AshHateoas.Test.Domain]
      |> ApiDocumentation.build()
      |> Map.get("hydra:supportedClass")
      |> Enum.find(&(&1["@id"] == "https://ash-hateoas.org/vocab#ValidationReport"))
    end

    test "validate and save return a ValidationReport" do
      # They return `%{"valid?" => …, "errors" => […]}`. Naming the resource's
      # own class was wrong twice: a validate writes nothing and has no record
      # to give back, and a save reports failures the same way rather than
      # returning an aggregate it did not write.
      assert recipe_returns("validate") == "https://ash-hateoas.org/vocab#ValidationReport"
      assert recipe_returns("save") == "https://ash-hateoas.org/vocab#ValidationReport"
    end

    test "an ordinary action still returns the resource's class" do
      assert recipe_returns("create") == "https://ash-hateoas.org/vocab#Recipe"
      assert recipe_returns("update") == "https://ash-hateoas.org/vocab#Recipe"
      assert recipe_returns("cook") == "https://ash-hateoas.org/vocab#Recipe"
    end

    test "the class it names is described, not merely referenced" do
      # The defect this whole part exists to remove: an IRI that is referenced
      # and never declared. Naming a return class the document does not describe
      # would repeat it.
      report = report_class()

      assert report
      assert report["@type"] == "Class"

      titles = Enum.map(report["hydra:supportedProperty"], & &1["hydra:title"])
      assert Enum.sort(titles) == ["errors", "valid?"]
    end

    test "its properties carry ranges, so a client need not guess" do
      report = report_class()

      ranges =
        Map.new(report["hydra:supportedProperty"], fn property ->
          {property["hydra:title"], property["rdfs:range"]["@id"]}
        end)

      assert ranges["valid?"] == "xsd:boolean"
      assert ranges["errors"] == "jsonschema:ArraySchema"
    end

    test "a domain with no document action does not carry the term" do
      # A class nothing references is noise, so the term is emitted only where
      # something returns it. `SilentDomain` carries no DslRoot.
      classes =
        [AshHateoas.Test.SilentDomain]
        |> ApiDocumentation.build()
        |> Map.get("hydra:supportedClass")
        |> Enum.map(& &1["@id"])

      refute "https://ash-hateoas.org/vocab#ValidationReport" in classes
    end

    test "the error entry is described too" do
      # `rdfs:range` alone says "an array" and stops. Without this, the entry
      # shape lives only in prose — which is what a client would then hardcode.
      error =
        [AshHateoas.Test.Domain]
        |> ApiDocumentation.build()
        |> Map.get("hydra:supportedClass")
        |> Enum.find(&(&1["@id"] == "https://ash-hateoas.org/vocab#ValidationError"))

      assert error

      titles = Enum.map(error["hydra:supportedProperty"], & &1["hydra:title"])
      assert Enum.sort(titles) == ["field", "index", "kind", "message", "name"]
    end

    test "errors names its member class, not merely 'an array'" do
      errors =
        report_class()["hydra:supportedProperty"]
        |> Enum.find(&(&1["hydra:title"] == "errors"))

      assert errors["sh:class"]["@id"] == "https://ash-hateoas.org/vocab#ValidationError"
    end
  end

  describe "a document names the classes it holds" do
    defp document_property(action) do
      [AshHateoas.Test.Domain]
      |> ApiDocumentation.build()
      |> Map.fetch!("hydra:supportedClass")
      |> Enum.find(&(&1["@id"] == "https://ash-hateoas.org/vocab#Recipe"))
      |> Map.fetch!("hydra:supportedOperation")
      |> Enum.find(&(&1["ah:action"] == action))
      |> get_in(["hydra:expects", "hydra:supportedProperty"])
      |> Enum.find(&(&1["hydra:title"] == "document"))
    end

    # The classes a property constrains its values to, however they are spelled.
    # One class is a plain `sh:class`; several are an `sh:or` over shapes, since
    # repeating `sh:class` means a value must be all of them at once.
    defp constrained_classes(property) do
      case property do
        %{"sh:class" => %{"@id" => iri}} -> [iri]
        %{"sh:or" => %{"@list" => shapes}} -> Enum.map(shapes, & &1["sh:class"]["@id"])
        _ -> []
      end
    end

    test "the element classes are named, not left as 'an array of something'" do
      # Without this the wire says `jsonschema:ArraySchema` and nothing more, and
      # the only statement of what an element looks like is English prose in a
      # description — which a client cannot construct a call from.
      iris = "save" |> document_property() |> constrained_classes()

      assert "https://ash-hateoas.org/vocab#Step" in iris
      assert "https://ash-hateoas.org/vocab#Ingredient" in iris
      assert "https://ash-hateoas.org/vocab#Technique" in iris
    end

    test "a choice of classes is a disjunction, not a conjunction" do
      # `sh:class` constrains **each value node**, so repeating it says every
      # element must be a Step *and* an Ingredient *and* a Technique at once —
      # which nothing satisfies, so a valid document fails. Confirmed against a
      # SHACL processor: an element typed `Step` conforms only under `sh:or`.
      property = document_property("save")

      refute Map.has_key?(property, "sh:class"),
             "a choice must not be spelled as repeated sh:class — that is a conjunction"

      # `sh:or` takes an rdf:List of **shapes**, so each member is a shape
      # carrying `sh:class` rather than a bare class IRI. `@list` is required:
      # a plain array is an unordered set, not the first/rest chain SHACL wants.
      assert %{"sh:or" => %{"@list" => [_ | _] = shapes}} = property

      for shape <- shapes do
        assert %{"sh:class" => %{"@id" => _}} = shape
      end
    end

    test "a single class stays a plain sh:class" do
      # No disjunction to express, so no `sh:or` — one class is exactly what
      # `sh:class` says, and wrapping it would be noise.
      errors =
        [AshHateoas.Test.Domain]
        |> ApiDocumentation.build()
        |> Map.get("@included")
        |> Enum.find(&(&1["@id"] == "https://ash-hateoas.org/vocab#validationReport/errors"))

      assert errors
    end

    test "each named class is described in full elsewhere in the same document" do
      # The point of linking rather than inlining: the description is already
      # there, and a copy could drift from it.
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])
      described = MapSet.new(doc["hydra:supportedClass"], & &1["@id"])

      for iri <- "save" |> document_property() |> constrained_classes() do
        assert iri in described, "#{iri} is named but never described"
      end
    end

    test "it names what a save accepts, not every relationship" do
      # Describing a different set would advertise a document the API rejects.
      managed =
        AshHateoas.Test.Recipe
        |> AshHateoas.RootActions.managed_relationships()
        |> Enum.map(& &1.destination)

      assert length(constrained_classes(document_property("save"))) == length(managed)
    end

    test "a non-public relationship's class is not named" do
      # `public?` means "appears in public interfaces" and defaults to false.
      # `Recipe.audits` is private, so a client must not be told it may write
      # `recipe_audit` elements — and since `on_missing/2` destroys what an
      # owned `has_many` omits, being told so would let a document delete rows
      # it was never shown.
      iris = "save" |> document_property() |> constrained_classes()

      refute "https://ash-hateoas.org/vocab#RecipeAudit" in iris
    end

    test "validate describes the same document as save" do
      # They take the same argument; a client checking against one and saving
      # against the other must not find them disagreeing.
      assert constrained_classes(document_property("validate")) ==
               constrained_classes(document_property("save"))
    end

    test "the classes are named as links, so nothing new is needed" do
      # A client that can follow a link property can read this unchanged.
      assert %{"rdfs:range" => %{"@id" => "jsonschema:ArraySchema"}} = document_property("save")
    end
  end

  describe "ah:identity" do
    test "a declared identity names the properties that key the class" do
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])

      ingredient =
        Enum.find(
          doc["hydra:supportedClass"],
          &(&1["@id"] == "https://ash-hateoas.org/vocab#Ingredient")
        )

      # `identity :unique_name, [:name]`. Without this on the wire a client has
      # no way to know what names a record, and is left guessing from
      # convention — is the key `name`, `title`, `slug`? A guess that is merely
      # usually right fails silently on the domain that names things
      # differently.
      assert ingredient["ah:identity"] == [
               [%{"@id" => "https://ash-hateoas.org/vocab#ingredient/name"}]
             ]
    end

    test "a resource with no declared identity carries no key" do
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])

      comment =
        Enum.find(
          doc["hydra:supportedClass"],
          &(&1["@id"] == "https://ash-hateoas.org/vocab#Comment")
        )

      # Absent rather than guessed. A client then knows it cannot match this
      # class by a natural key, instead of matching the wrong record.
      refute Map.has_key?(comment, "ah:identity")
    end

    test "the term is declared, and is deliberately not a subproperty of owl:hasKey" do
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])
      terms = Enum.find(doc["@context"], &is_map/1)

      # It was one until the ontology work, and the claim was unsound twice
      # over. `owl:hasKey` is a *class* axiom taking a class expression and an
      # `rdf:List` of properties, so it cannot sit on a property node at all.
      # And it licenses a reasoner to infer `owl:sameAs` between individuals
      # sharing key values — for a business key like a name, that merges two
      # legitimately distinct records and unions their properties, which is the
      # corruption the term exists to prevent.
      refute get_in(terms, ["ah:identity", "rdfs:subPropertyOf"])
      assert terms["rdfs"] == "http://www.w3.org/2000/01/rdf-schema#"

      # Declared as what it is: an annotation. Its value is metadata about a
      # class, not a fact about an individual.
      identity =
        Enum.find(doc["@included"], &(&1["@id"] == "ah:identity"))

      assert identity["@type"] == "owl:AnnotationProperty"
    end
  end

  test "operations advertise their possibleStatus from the gate chain" do
    doc = ApiDocumentation.build([AshHateoas.Test.Domain])

    document =
      Enum.find(
        doc["hydra:supportedClass"],
        &(&1["@id"] == "https://ash-hateoas.org/vocab#Document")
      )

    # Document has authorizers -> a PATCH can 403, can fail validation (422),
    # and targets a member (404).
    patch =
      Enum.find(document["hydra:supportedOperation"], &(&1["hydra:method"] == "PATCH"))

    codes = patch["hydra:possibleStatus"] |> Enum.map(& &1["hydra:statusCode"])
    assert 403 in codes
    assert 422 in codes
    assert 404 in codes

    assert Enum.all?(patch["hydra:possibleStatus"], &(&1["@type"] == "Status"))
  end

  test "a supported property references the property and carries the datatype separately" do
    doc = ApiDocumentation.build([AshHateoas.Test.Domain])

    document =
      Enum.find(
        doc["hydra:supportedClass"],
        &(&1["@id"] == "https://ash-hateoas.org/vocab#Document")
      )

    title =
      Enum.find(
        document["hydra:supportedProperty"],
        &(&1["hydra:property"]["@id"] == "https://ash-hateoas.org/vocab#document/title")
      )

    # `hydra:property` ranges over `rdf:Property`, so the value is a bare
    # reference to the property — and now *only* that.
    assert title["hydra:property"] == %{"@id" => "https://ash-hateoas.org/vocab#document/title"}

    # The datatype is a fact about the property, so it is declared once on the
    # property itself and a consumer follows the `@id` — rather than restated
    # at every site the property appears.
    refute Map.has_key?(title, "sh:datatype")

    declared =
      Enum.find(doc["@included"], &(&1["@id"] == "https://ash-hateoas.org/vocab#document/title"))

    assert declared["@type"] == "owl:DatatypeProperty"
    assert declared["rdfs:range"] == %{"@id" => "xsd:string"}
  end

  test "an operation's input still carries its own datatype" do
    doc = ApiDocumentation.build([AshHateoas.Test.Domain])

    document =
      Enum.find(
        doc["hydra:supportedClass"],
        &(&1["@id"] == "https://ash-hateoas.org/vocab#Document")
      )

    input =
      document["hydra:supportedOperation"]
      |> Enum.find(&(&1["hydra:method"] == "POST"))
      |> get_in(["hydra:expects", "hydra:supportedProperty"])
      |> Enum.find(&(&1["hydra:title"] == "title"))

    # An argument is not a property of a class — `approve` takes a `note`, but a
    # Document does not have one — so the ontology declares none, and there is
    # no declaration for a consumer to follow. The key must stay here.
    #
    # Measured rather than assumed: stripping these collapses boolean, integer
    # and ref to string, which is exactly the bug that typed every MCP field
    # `"string"`.
    assert input["sh:datatype"] == "xsd:string"
  end

  test "the whole document is JSON-encodable" do
    doc = ApiDocumentation.build([AshHateoas.Test.Domain], entrypoint: "/api")
    assert {:ok, _} = Jason.encode(doc)
  end

  describe "every IriTemplate names a URL a client can build" do
    # An `IriTemplate` exists to say *which URL to construct*. Every one the
    # documentation emitted said only how to spell the query string — the
    # operations are built from the route table, and the route was not passed
    # to the descriptor, so `href` was `nil` and the template collapsed to a
    # bare `{?label}`.
    #
    # The unit tests could not catch it: they hand the renderer an affordance
    # with an href already set, which is exactly the input the documentation
    # was failing to produce. So the assertion belongs here, on the document.

    defp templates do
      collect = fn collect, node, acc ->
        cond do
          is_map(node) ->
            acc = if node["@type"] == "IriTemplate", do: [node | acc], else: acc
            Enum.reduce(Map.values(node), acc, &collect.(collect, &1, &2))

          is_list(node) ->
            Enum.reduce(node, acc, &collect.(collect, &1, &2))

          true ->
            acc
        end
      end

      collect.(collect, ApiDocumentation.build([AshHateoas.Test.Domain]), [])
    end

    test "the fixture domain emits some, so this asserts on something" do
      assert templates() != []
    end

    test "none is a bare query fragment" do
      bare = for t <- templates(), String.starts_with?(t["hydra:template"], "{"), do: t

      assert bare == [],
             """
             a template with no path expands to a query string alone:

             #{Enum.map_join(bare, "\n", &"  #{&1["hydra:template"]}")}
             """
    end

    test "none leaves a router placeholder in the path" do
      # `:id` is Plug's spelling. A client expanding this gets a literal `:id`
      # in the URL — confirmed against a URI Template expander.
      leaked = for t <- templates(), String.contains?(t["hydra:template"], ":"), do: t

      assert leaked == [],
             """
             a router placeholder survived into a template:

             #{Enum.map_join(leaked, "\n", &"  #{&1["hydra:template"]}")}
             """
    end

    test "every variable in a template is described in its mapping" do
      # A variable the mapping does not name leaves a client to guess what goes
      # there — which is the one thing the template exists to prevent.
      for template <- templates() do
        declared = MapSet.new(template["hydra:mapping"], & &1["hydra:variable"])

        used =
          ~r/\{[?&]?([a-zA-Z_][a-zA-Z0-9_,]*)\}/
          |> Regex.scan(template["hydra:template"], capture: :all_but_first)
          |> List.flatten()
          |> Enum.flat_map(&String.split(&1, ","))
          |> MapSet.new()

        undescribed = MapSet.difference(used, declared)

        assert MapSet.size(undescribed) == 0,
               "#{template["hydra:template"]} uses #{inspect(MapSet.to_list(undescribed))}, " <>
                 "which its mapping does not describe"
      end
    end
  end

  describe "the document states each fact once" do
    # `schema:target` would carry a `urlTemplate`, an `httpMethod` and a
    # `contentType`, and all three are already stated: the URL by the `@id` of
    # the node the operation hangs on (Hydra's own rule — an operation is
    # invoked against its node, which is why `hydra:Operation` has no
    # target-URL property), the method by `hydra:method` on the operation
    # itself, and the content type by the API rather than by one operation.
    #
    # It was also wrong for as long as it existed. schema.org defines
    # `urlTemplate` as *"an url template (RFC6570)"*, and RFC 6570 gives `:` no
    # meaning — so the Plug-spelled `/orders/:id/ship` expanded to **zero**
    # variables and handed back a literal `:id`. Verified against a real
    # expander. Rather than teach a redundant statement to spell itself
    # correctly, the statement went.
    #
    # A **declared** `semantic_action` still emits `schema:potentialAction`,
    # since an operation's role is the one thing Hydra cannot express. What no
    # longer appears is a subtype *inferred* from the method: 139 of 146 were
    # `hydra:method` said twice.
    #
    # Asserted document-wide, because both failures were categorical — every
    # template wrong at once, every operation redundant at once — and an
    # example-based test passes happily while a whole category rots.

    defp nodes_with(doc, key) do
      collect = fn collect, node, acc ->
        cond do
          is_map(node) ->
            acc = if Map.has_key?(node, key), do: [node | acc], else: acc
            Enum.reduce(Map.values(node), acc, &collect.(collect, &1, &2))

          is_list(node) ->
            Enum.reduce(node, acc, &collect.(collect, &1, &2))

          true ->
            acc
        end
      end

      collect.(collect, doc, [])
    end

    test "no operation carries a schema:target" do
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])

      assert nodes_with(doc, "schema:target") == [],
             "schema:target restates @id, hydra:method and the API's content type"
    end

    test "no schema:urlTemplate survives anywhere" do
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])

      assert nodes_with(doc, "schema:urlTemplate") == [],
             "the URL is the operation's node @id, stated once"
    end

    test "a potentialAction appears only where a role was declared" do
      # `hydra:method` is on the same node, so an inferred subtype adds nothing.
      # The survivors are the roles a domain declared with `semantic_action` —
      # including two this library names itself, for roles no published
      # vocabulary carries.
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])

      types =
        doc
        |> nodes_with("schema:potentialAction")
        |> Enum.map(& &1["schema:potentialAction"]["@type"])
        |> Enum.uniq()
        |> Enum.sort()

      assert types != [], "the fixture declares semantic_actions; none reached the wire"

      inferred = ["schema:ReadAction", "schema:CreateAction", "schema:UpdateAction", "schema:DeleteAction"]

      assert Enum.filter(types, &(&1 in inferred)) == [],
             "a method-inferred subtype reached the wire: #{inspect(types)}"
    end
  end

  describe "every IriTemplate variable is described exactly once" do
    test "a path segment sharing a name with an argument is not mapped twice" do
      # `/multi_read/{id}/by_id{?id}` has a path `:id` and a query argument also
      # named `id`. Both were mapped, one claiming required and one not — two
      # statements about one variable, which is worse than either alone.
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])

      for template <- templates() do
        vars = Enum.map(template["hydra:mapping"], & &1["hydra:variable"])

        assert vars == Enum.uniq(vars),
               "#{template["hydra:template"]} maps #{inspect(vars -- Enum.uniq(vars))} more than once"
      end

      _ = doc
    end
  end
end
