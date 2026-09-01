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

      # A create is invoked at the collection URL, so it is filed under the
      # collection class — you cannot POST to a comment to create a comment.
      comment =
        Enum.find(
          doc["hydra:supportedClass"],
          &(&1["@id"] == "https://ash-hateoas.org/vocab#Comment/Collection")
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
      Enum.find(
        doc["@included"],
        &(&1["@id"] == "https://ash-hateoas.org/vocab#comment/document")
      )

    assert declared["rdfs:range"] == %{"@id" => "https://ash-hateoas.org/vocab#Document"}

    # A to-one resolves to a single node, so it carries no collection marker.
    refute Map.has_key?(link, "ah:targetKind")
  end

  test "the link replaces the raw foreign key rather than joining it" do
    doc = ApiDocumentation.build([AshHateoas.Test.Domain])

    comment =
      Enum.find(
        doc["hydra:supportedClass"],
        &(&1["@id"] == "https://ash-hateoas.org/vocab#Comment")
      )

    titles = Enum.map(comment["hydra:supportedProperty"], & &1["hydra:title"])

    # This asserted the opposite until the write path caught up, on the reading
    # that `document_id` was "a real writable attribute a client still needs in
    # order to set the relationship". It is not: the create and update inputs
    # advertise `document`, and `AshHateoas.Hydra.LinkInput` resolves an IRI or
    # a declared identity back to the key. So the key was the one shape the
    # write path would refuse, published as though it were the way in.
    assert "document" in titles
    refute "document_id" in titles
  end

  describe "an operation's identity" do
    defp class_of(type_name) do
      [AshHateoas.Test.Domain]
      |> ApiDocumentation.build()
      |> Map.fetch!("hydra:supportedClass")
      |> Enum.find(&(&1["@id"] == "https://ash-hateoas.org/vocab#" <> type_name))
    end

    # Everything the catalogue says about a type, across **both** classes it now
    # yields. An operation invoked at `/article` is filed under
    # `Article/Collection`, not under `Article`, so a test asking "what does this
    # API support for articles?" has to read both — which is what a client does
    # too.
    defp everything_about(type_name) do
      [AshHateoas.Test.Domain]
      |> ApiDocumentation.build()
      |> Map.fetch!("hydra:supportedClass")
      |> Enum.filter(fn class ->
        class["@id"] in [
          "https://ash-hateoas.org/vocab#" <> type_name,
          "https://ash-hateoas.org/vocab#" <> type_name <> "/Collection"
        ]
      end)
      |> Enum.flat_map(&(&1["hydra:supportedOperation"] || []))
    end

    test "an operation is identified by a class IRI, not a bare name" do
      article = class_of("Article")
      types = Enum.map(everything_about("Article"), & &1["@type"])

      # Hydra gives an operation no identity of its own — `Operation` is carried
      # by every one of them, so it separates none. What separates them used to
      # be `ah:action`, a bare string: undereferenceable, unsubclassable, and
      # meaningless to a consumer that has not read this API's documentation.
      assert ["Operation" | _] = hd(types)

      classes = Enum.map(types, &Enum.at(&1, 1))
      assert "https://ash-hateoas.org/vocab#Article/publishAction" in classes
      assert "https://ash-hateoas.org/vocab#Article/readAction" in classes

      refute Enum.any?(everything_about("Article"), &Map.has_key?(&1, "ah:action"))
    end

    test "two operations sharing a method are distinguishable" do
      posts =
        everything_about("Recipe")
        |> Enum.filter(&(&1["hydra:method"] == "POST"))
        |> Enum.map(&Enum.at(&1["@type"], 1))

      # Three POSTs — create, validate and save. Without an identity a client
      # sees three identical offers and cannot tell which one saves a document.
      assert "https://ash-hateoas.org/vocab#Recipe/createAction" in posts
      assert "https://ash-hateoas.org/vocab#Recipe/validateAction" in posts
      assert "https://ash-hateoas.org/vocab#Recipe/saveAction" in posts
      assert length(Enum.uniq(posts)) == length(posts)
    end

    test "two routes onto one action share its class, and are told apart by what they do" do
      # The standard case: a primary read reached both at `/:id` and at the
      # collection. They invoke the **same action**, so one class is the correct
      # answer — and a subclass per route was minted here for a while on the
      # grounds that the two entries were otherwise indistinguishable. That was
      # the wrong end of the problem: they were indistinguishable because the
      # catalogue stated no address and declared the same return class for both.
      #
      # Now it states both, and they differ in the two things a client acts on.
      reads = Enum.filter(everything_about("Article"), &(Enum.at(&1["@type"], 1) =~ "readAction"))

      assert length(reads) == 2
      assert reads |> Enum.map(&Enum.at(&1["@type"], 1)) |> Enum.uniq() |> length() == 1

      member = Enum.find(reads, &(&1["ah:template"]["hydra:template"] =~ "{id}"))
      collection = Enum.find(reads, &(not (&1["ah:template"]["hydra:template"] =~ "{id}")))

      assert member["ah:template"]["hydra:template"] == "/articles/{id}"
      assert collection["ah:template"]["hydra:template"] == "/articles"

      assert member["hydra:returns"]["@id"] == "https://ash-hateoas.org/vocab#Article"

      assert collection["hydra:returns"]["@id"] ==
               "https://ash-hateoas.org/vocab#Article/Collection"

      # And only the member route can 404, which is what it always was.
      codes = fn op ->
        Enum.map(List.wrap(op["hydra:possibleStatus"]), & &1["hydra:statusCode"])
      end

      assert 404 in codes.(member)
      refute 404 in codes.(collection)
    end

    test "the catalogue's @type is the list a node carries, so the join is an identity" do
      # A node's operation is `["Operation", <action class>]`. The catalogue used
      # to add a third element, so joining the two documents meant reading a
      # prefix of one list rather than comparing them.
      for op <- everything_about("Article") do
        assert [hydra, action] = op["@type"]

        assert hydra == "Operation"
        assert String.starts_with?(action, "https://ash-hateoas.org/vocab#Article/")
        assert String.ends_with?(action, "Action")
      end
    end

    test "a route mints no class of its own" do
      # An action with one route — most of them — got a subclass with exactly its
      # parent's members, adding no property and constraining nothing: a
      # vocabulary node saying a thing is itself. And the segment was a
      # `%Route{}.type`, which spells like an HTTP method, so
      # `Article/publishAction/patch` read as "publishing is a kind of PATCH" —
      # the inference this package refuses to draw when it declines to derive
      # `schema:ReadAction` from a GET.
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])

      referenced =
        for class <- doc["hydra:supportedClass"],
            op <- class["hydra:supportedOperation"] || [],
            iri <- op["@type"],
            iri != "Operation",
            do: iri

      assert referenced != []

      assert Enum.reject(referenced, &String.ends_with?(&1, "Action")) == [],
             "an operation names a class that is not an action class"

      refute Enum.any?(doc["@included"], &(&1["@id"] =~ ~r{Action/[a-z_]+$})),
             "a route class survives in the vocabulary"
    end
  end

  describe "the document operations declare what they are for" do
    defp recipe_operation(action) do
      iri = AshHateoas.Hydra.Context.action_class_iri("recipe", action)

      Enum.find(everything_about("Recipe"), &(iri in &1["@type"]))
    end

    # The declared role of an operation, read the way a consumer reads it: the
    # operation names its class, and the ontology says what that class is a
    # subclass of. One hop, and the axiom is stated once for the whole API
    # rather than repeated on every offer of the operation.
    defp declared_role(action) do
      iri = AshHateoas.Hydra.Context.action_class_iri("recipe", action)

      [AshHateoas.Test.Domain]
      |> ApiDocumentation.build()
      |> Map.fetch!("@included")
      |> Enum.find(%{}, &(&1["@id"] == iri))
      |> Map.get("rdfs:subClassOf")
      |> then(&(&1 && &1["@id"]))
    end

    test "validate is a CheckAction, not a create" do
      # Both document operations are POSTs, so a type inferred from the method
      # would be `CreateAction` for each — which says checking a document
      # creates something. Declaring the role is what lets a client tell them
      # apart without matching the string "validate", which is a naming
      # convention rather than anything the API states.
      assert declared_role("validate") == "https://schema.org/CheckAction"
    end

    test "save is distinguishable from an ordinary record update" do
      # Not `schema:UpdateAction`, though that reads right in isolation: it is
      # what any PATCH would infer, so declaring it would make a document save
      # indistinguishable from updating one record. A term is only worth
      # declaring if it says something the inference does not.
      assert declared_role("save") == "https://ash-hateoas.org/vocab#SaveAction"

      refute declared_role("save") == declared_role("update")
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

    test "the POSTs are told apart by their own class, and by role where declared" do
      classes =
        for action <- ["create", "validate", "save", "cook"],
            do: Enum.at(recipe_operation(action)["@type"], 1)

      assert length(Enum.uniq(classes)) == 4

      # Three of the four also declare a role, and `create` deliberately does
      # not — no published term separates it from what POST already implies.
      roles = for action <- ["validate", "save", "cook"], do: declared_role(action)

      assert length(Enum.uniq(roles)) == 3
      assert declared_role("create") == nil
    end

    test "an execute action carries a role schema.org has no term for" do
      # schema.org has nothing meaning "run this": `ControlAction` and
      # `ActivateAction` are device control, and `AchieveAction`'s subtypes are
      # Win/Lose/Tie. So the role is named in this package's vocabulary.
      #
      # Nothing about it is special-cased — `semantic_action` passes an absolute
      # IRI through verbatim, which is what makes a vocabulary this package does
      # not own expressible at all.
      assert declared_role("cook") == "https://ash-hateoas.org/vocab#RunAction"
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
      |> Enum.find(&(AshHateoas.Hydra.Context.action_class_iri("recipe", action) in &1["@type"]))
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

    test "the root's own class is named too, because a save accepts it" do
      # A document carries the root's attributes as an element whose kind is the
      # root's type — there is no other route for them, since the root has no
      # update affordance of its own. `AshHateoas.RootActions` accepts that
      # element, so omitting the class here would advertise a set smaller than
      # the one a save takes, and a client comparing the two would conclude that
      # sending the root is an error.
      iris = "save" |> document_property() |> constrained_classes()

      assert "https://ash-hateoas.org/vocab#Recipe" in iris
    end

    test "every kind a save accepts is advertised, and no others" do
      # The property that matters, stated as an equality rather than a list of
      # IRIs: the two sets are computed from different code — one from the
      # rendered wire, one from the resource — so they can only agree if the
      # advertisement tracks the acceptance. Adding an element relationship or
      # changing the root's type keeps this passing with no edit here; letting
      # the two drift apart fails it.
      advertised =
        "save"
        |> document_property()
        |> constrained_classes()
        |> Enum.map(&(&1 |> String.split("#") |> List.last()))
        |> MapSet.new()

      accepted =
        AshHateoas.Test.Recipe
        |> AshHateoas.RootActions.managed_relationships()
        |> Enum.map(& &1.destination)
        |> Enum.map(&AshHateoas.Resource.Info.type/1)
        |> then(&[AshHateoas.Resource.Info.type(AshHateoas.Test.Recipe) | &1])
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&Macro.camelize/1)
        |> MapSet.new()

      assert MapSet.equal?(advertised, accepted),
             """
             the advertised element classes and the kinds a save accepts have drifted.
               only advertised: #{inspect(MapSet.difference(advertised, accepted) |> MapSet.to_list())}
               only accepted:   #{inspect(MapSet.difference(accepted, advertised) |> MapSet.to_list())}
             """
    end

    test "a class states the type a document must name it by" do
      # **The class IRI is not that name, and cannot be turned back into it.**
      # `Macro.camelize` is lossy — `mixing_bowl` becomes `MixingBowl`, and
      # `mixingbowl` and `Mixing_Bowl` would too — so a consumer that derives
      # the document's `kind` from the IRI is right only where the type was one
      # lower-case word. Measured on a live API whose types all carry a prefix:
      # every element of a 214-element save rejected as an unknown kind.
      #
      # `hydra:title` is what a client reads instead, so removing it or
      # "tidying" it to the camelized name would silently break every consumer
      # whose types are more than one word.
      classes =
        [AshHateoas.Test.Domain]
        |> ApiDocumentation.build()
        |> Map.fetch!("hydra:supportedClass")
        |> Map.new(&{&1["@id"], &1["hydra:title"]})

      assert classes["https://ash-hateoas.org/vocab#MixingBowl"] == "mixing_bowl"
      assert classes["https://ash-hateoas.org/vocab#Step"] == "step"
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
      # The managed destinations, plus the root itself — which a save also
      # accepts, and which is the one class here that is not a relationship.
      managed =
        AshHateoas.Test.Recipe
        |> AshHateoas.RootActions.managed_relationships()
        |> Enum.map(& &1.destination)

      assert length(constrained_classes(document_property("save"))) == length(managed) + 1
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

    documents =
      Enum.find(
        doc["hydra:supportedClass"],
        &(&1["@id"] == "https://ash-hateoas.org/vocab#Document/Collection")
      )

    input =
      documents["hydra:supportedOperation"]
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

  describe "an entry says where it is sent" do
    # The catalogue's half of the CR the flat-operations change opened. A node
    # states the address it resolved as `ah:href`; the documentation describes a
    # class, so there is no record to resolve against and the honest statement is
    # the template. Before this, an entry carried `@type`, `hydra:method`, a
    # shape and a status list — none of which is a URL — so a client holding only
    # the documentation could see that a class supports nine operations and issue
    # none of them.

    # Both classes a type yields. An operation invoked at `/article` is filed
    # under `Article/Collection`; one invoked at `/article/{id}` under `Article`.
    # A client asking "what may I do with articles?" reads both, and so does
    # this.
    defp catalogue(type_name, opts \\ []) do
      classes =
        [AshHateoas.Test.Domain]
        |> ApiDocumentation.build(opts)
        |> Map.fetch!("hydra:supportedClass")

      for class <- classes,
          class["@id"] in [
            "https://ash-hateoas.org/vocab#" <> type_name,
            "https://ash-hateoas.org/vocab#" <> type_name <> "/Collection"
          ],
          operation <- class["hydra:supportedOperation"] || [],
          do: operation
    end

    # An entry by the action it exposes — the identity a node carries too.
    #
    # A primary read has two, and they are picked apart by the address they
    # state, which is what the catalogue now says and what a client would use.
    defp entries(class, action, opts) do
      iri = "https://ash-hateoas.org/vocab#" <> class <> "/" <> to_string(action) <> "Action"

      Enum.filter(catalogue(class, opts), &(iri in &1["@type"]))
    end

    defp entry(class, action, opts \\ []) do
      case entries(class, action, opts) do
        [op] -> op
        ops -> flunk("#{class}/#{action} has #{length(ops)} entries; name the route you mean")
      end
    end

    defp member_entry(class, action, opts \\ []) do
      Enum.find(entries(class, action, opts), &(&1["ah:template"]["hydra:template"] =~ "{id}"))
    end

    defp collection_entry(class, action, opts \\ []) do
      Enum.find(
        entries(class, action, opts),
        &(not (&1["ah:template"]["hydra:template"] =~ "{id}"))
      )
    end

    test "every supported operation carries one, for every class" do
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])

      missing =
        for class <- doc["hydra:supportedClass"],
            op <- class["hydra:supportedOperation"] || [],
            is_nil(op["ah:template"]),
            do: "#{class["@id"]} #{op["hydra:method"]}"

      assert missing == [],
             """
             #{length(missing)} catalogue entries state no address:

             #{Enum.join(missing, "\n")}

             An entry a client cannot issue describes an operation it cannot
             reach, which is the whole of what a catalogue is for.
             """
    end

    test "a member route's template carries the id as a required variable" do
      template = member_entry("Article", :read)["ah:template"]

      assert template["@type"] == "IriTemplate"
      assert template["hydra:template"] == "/articles/{id}"

      assert [%{"hydra:variable" => "id", "hydra:required" => true}] = template["hydra:mapping"]
    end

    test "a collection route's template is a constant, and still a template" do
      # It needs no variables, and staying an `IriTemplate` is what keeps a
      # client reading one key the same way for every operation rather than
      # branching on a second shape.
      template =
        collection_entry("Article", :read)["ah:template"]

      assert template["@type"] == "IriTemplate"
      assert template["hydra:template"] == "/articles"

      # Absent rather than empty: an empty JSON-LD array states nothing, so the
      # key would be in the JSON and gone from the graph.
      refute Map.has_key?(template, "hydra:mapping")
    end

    test "a sub-action's URL is in the catalogue even when no node is offering it" do
      # The case that motivated this. A member URL can be reached by following
      # links — an entry point lists collections, a collection lists members with
      # full `@id`s, a node states its own. A sub-action's URL appeared in
      # exactly one place, `ah:href` on an operation a node is *currently*
      # offering, so an operation the record's state gates off had no URL in any
      # document at all.
      template =
        entry("Article", :publish)["ah:template"]

      assert template["hydra:template"] == "/articles/{id}/publish"
    end

    test "the prefix the API is mounted at is part of the template" do
      # A route is stored as the mount path plus the path. Without the prefix a
      # client has to know where the API hangs to use the template — which is
      # exactly the knowledge the documentation exists to remove.
      template =
        member_entry("Article", :read, prefix: "https://api.example.org")["ah:template"]

      assert template["hydra:template"] == "https://api.example.org/articles/{id}"
    end

    test "a write's body fields are not query variables" do
      # `iri_template/2` puts every field of the affordance in the query suffix,
      # which is right for a GET and wrong for anything else: a create's `title`
      # is the request body, and advertising it as `?title=` would describe a
      # call the write path does not accept.
      create = entry("Article", :create)

      assert create["ah:template"]["hydra:template"] == "/articles"
      refute create["ah:template"]["hydra:template"] =~ "title"

      # And the fields really are described — under `hydra:expects`, where a body
      # belongs.
      titles =
        create["hydra:expects"]["hydra:supportedProperty"] |> Enum.map(& &1["hydra:title"])

      assert "title" in titles
    end

    test "a query read's variables are in the template, and hydra:expects is left to the body" do
      # On a node, a GET's arguments render as an `IriTemplate` under
      # `hydra:expects` — the address is already resolved there, so the template
      # is genuinely about what to send. Here it is not: `ah:template` states the
      # whole address including the query variables, so a copy under
      # `hydra:expects` would be the identical node under a second key and a
      # client would read the value's `@type` to learn which question the key was
      # answering.
      invalid =
        Enum.find(
          catalogue("ReadFailure"),
          &(&1["ah:template"]["hydra:template"] =~ "invalid")
        )

      assert invalid["ah:template"]["hydra:template"] == "/domain/read_failure/invalid{?label}"
      assert [%{"hydra:variable" => "label"}] = invalid["ah:template"]["hydra:mapping"]

      refute Map.has_key?(invalid, "hydra:expects")
    end
  end

  describe "a collection route says it returns a collection" do
    test "the two routes onto one read no longer claim the same return type" do
      # The plainly wrong statement of the three. `Renderer.put_returns/3` names
      # the resource's class for every operation yielding a record and does not
      # consult the route kind, so `GET /articles` declared an Article — and
      # `Collection.wrap/2` answers with `hydra:member` and `hydra:totalItems`,
      # which an Article has neither of. A client believing the declaration looks
      # for the resource's properties on a node that has none of them.
      member = member_entry("Article", :read)
      collection = collection_entry("Article", :read)

      assert member["hydra:returns"] == %{"@id" => "https://ash-hateoas.org/vocab#Article"}

      assert collection["hydra:returns"] == %{
               "@id" => "https://ash-hateoas.org/vocab#Article/Collection"
             }
    end

    test "the returned class says what is in it" do
      # `hydra:Collection` alone would be true and would not say *of what*. The
      # class is declared with the spec's own pattern for a strongly typed
      # collection, so a client following `hydra:returns` learns both.
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])

      declared =
        Enum.find(
          doc["@included"],
          &(&1["@id"] == "https://ash-hateoas.org/vocab#Article/Collection")
        )

      assert declared["rdfs:subClassOf"] == %{"@id" => "hydra:Collection"}

      assert declared["hydra:memberAssertion"] == %{
               "hydra:property" => %{"@id" => "rdf:type"},
               "hydra:object" => %{"@id" => "https://ash-hateoas.org/vocab#Article"}
             }
    end

    test "every returned class is one the document declares" do
      # The invariant the ontology exists to keep, checked from the side that
      # references it: a `hydra:returns` naming a class nothing declares is a
      # dangling IRI a client resolves to nothing.
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])

      declared =
        MapSet.new(doc["@included"], & &1["@id"])
        |> MapSet.union(MapSet.new(doc["hydra:supportedClass"], & &1["@id"]))

      returned =
        for class <- doc["hydra:supportedClass"],
            op <- class["hydra:supportedOperation"] || [],
            iri = op["hydra:returns"]["@id"],
            # `owl:Nothing` is OWL's, not ours.
            iri != "owl:Nothing",
            do: iri

      assert returned != []
      assert Enum.reject(returned, &MapSet.member?(declared, &1)) == []
    end
  end

  describe "an entry says what going right looks like" do
    defp codes(op), do: Enum.map(op["hydra:possibleStatus"] || [], & &1["hydra:statusCode"])

    test "every entry declares a success status" do
      # The list used to be built from three calls and all three were errors, so
      # a catalogue entry read as an operation that can only fail. A client
      # generating a request handler from it had to hardcode which status meant
      # success, which is the one thing a description of an operation should not
      # leave to convention.
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])

      failing_only =
        for class <- doc["hydra:supportedClass"],
            op <- class["hydra:supportedOperation"] || [],
            Enum.all?(codes(op), &(&1 >= 400)),
            do: "#{class["@id"]} #{op["hydra:method"]}"

      assert failing_only == [],
             """
             #{length(failing_only)} entries declare only failures:

             #{Enum.join(failing_only, "\n")}
             """
    end

    test "a create is 201, a read and an update are 200" do
      assert 201 in codes(entry("Article", :create))
      refute 200 in codes(entry("Article", :create))

      assert 200 in codes(member_entry("Article", :read))
      assert 200 in codes(entry("Article", :update))
    end

    test "a destroy declares both 200 and 204" do
      # `respond_destroy/7` answers 200 with the destroyed record when the data
      # layer returns one and 204 with no body when it does not. `possibleStatus`
      # is a set of what may happen, so declaring both is the more accurate
      # document than declaring either alone — and it is where "sometimes there
      # is no body" is stated, which is what lets `hydra:returns` keep naming the
      # class that comes back when one does.
      destroy = entry("Review", :destroy)

      assert 200 in codes(destroy)
      assert 204 in codes(destroy)
      assert destroy["hydra:returns"] == %{"@id" => "https://ash-hateoas.org/vocab#Review"}
    end

    test "the success status comes first, and the gate chain still follows" do
      # Order is not semantics — `possibleStatus` is a set — but a client reading
      # the list to a human shows it in document order, and the outcome the
      # operation is *for* belongs at the top.
      patch = entry("Document", :update)

      assert [200 | rest] = codes(patch)
      assert 403 in rest
      assert 422 in rest
      assert 404 in rest
    end

    test "every declared status is a Status node with a title" do
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])

      for class <- doc["hydra:supportedClass"],
          op <- class["hydra:supportedOperation"] || [],
          status <- op["hydra:possibleStatus"] || [] do
        assert status["@type"] == "Status"
        assert is_integer(status["hydra:statusCode"])
        assert is_binary(status["hydra:title"])
      end
    end
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
        # `hydra:mapping` is absent when a template has no variables — a
        # constant collection URL — rather than present and empty, since an
        # empty JSON-LD array states nothing and the key would expand away.
        declared = MapSet.new(template["hydra:mapping"] || [], & &1["hydra:variable"])

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
    # `schema:potentialAction` is gone entirely. A declared `semantic_action`
    # is still the one thing Hydra cannot express, but it is now an
    # `rdfs:subClassOf` on the operation's own class in the ontology, which
    # states it once for the API rather than repeating it on every offer — and
    # says the operation **is** that kind of action rather than *has* one.
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

    test "no schema:potentialAction survives anywhere" do
      # It said the operation *has* an action. The class in `@type` says it
      # **is** one, which is the accurate reading for a node that is the offer
      # to act — and `potentialAction` is defined with domain `Thing` and range
      # `Action`, making an `Operation` an awkward subject for it.
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])

      assert nodes_with(doc, "schema:potentialAction") == [],
             "the role is an axiom on the operation's class, not a key on the operation"
    end

    test "a declared role is still reachable, as a superclass" do
      # What replaced it, and the reason removing the key loses nothing: the
      # roles a domain declared with `semantic_action` — including two this
      # library names itself, for roles no published vocabulary carries — are
      # superclasses of the operation classes.
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])

      # The minted action classes, and only those: `<Class>/<action>Action`.
      # `ah:SaveAction` and `ah:RunAction` also end in "Action" and are the
      # library's own *roles*, so including them would count a role's own
      # parent as though a minted class had declared it.
      roles =
        doc["@included"]
        |> Enum.filter(fn node ->
          is_binary(node["@id"]) and String.ends_with?(node["@id"], "Action") and
            String.contains?(node["@id"], "/")
        end)
        |> Enum.flat_map(&List.wrap(&1["rdfs:subClassOf"]))
        |> Enum.map(& &1["@id"])
        |> Enum.uniq()

      assert "https://schema.org/CheckAction" in roles
      assert "https://ash-hateoas.org/vocab#SaveAction" in roles

      # And still no subtype inferred from an HTTP method: that would be a
      # second spelling of `hydra:method`, and two spellings can disagree.
      inferred = [
        "schema:ReadAction",
        "schema:CreateAction",
        "schema:UpdateAction",
        "schema:DeleteAction",
        "https://schema.org/ReadAction",
        "https://schema.org/CreateAction",
        "https://schema.org/DeleteAction"
      ]

      assert Enum.filter(roles, &(&1 in inferred)) == [],
             "a method-inferred subtype reached the wire: #{inspect(roles)}"
    end
  end

  describe "every IriTemplate variable is described exactly once" do
    test "a path segment sharing a name with an argument is not mapped twice" do
      # `/multi_read/{id}/by_id{?id}` has a path `:id` and a query argument also
      # named `id`. Both were mapped, one claiming required and one not — two
      # statements about one variable, which is worse than either alone.
      doc = ApiDocumentation.build([AshHateoas.Test.Domain])

      for template <- templates() do
        vars = Enum.map(template["hydra:mapping"] || [], & &1["hydra:variable"])

        assert vars == Enum.uniq(vars),
               "#{template["hydra:template"]} maps #{inspect(vars -- Enum.uniq(vars))} more than once"
      end

      _ = doc
    end
  end
end
