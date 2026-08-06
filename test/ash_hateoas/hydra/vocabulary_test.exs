defmodule AshHateoas.Hydra.VocabularyTest do
  @moduledoc """
  An API's classes belong to that API's namespace.

  ## The defect this exists for

  The vocabulary namespace was a module constant, so **every** API built on this
  library minted its classes under one namespace. Measured when it was found:
  two services in one system, each declaring a `user` and an `api_key`, both
  emitted `…/vocab#User` — one IRI standing for two unrelated classes, in a
  system whose whole premise is that an IRI names one thing. `AshHateoas.Hydra.Context`'s own moduledoc calls that "unambiguous
  grounding", and it was the one thing the shared constant could not give.

  It was invisible from inside any single service: read one API's document and
  the IRIs look perfectly well-formed. Only two documents side by side show it,
  which is why nothing caught it.

  ## What must NOT move, and why each is a separate assertion

  Localising is a rewrite over a whole document, so the risk runs the other way:
  rewriting too much is as wrong as rewriting too little, and quieter.

    * **`ah:` is the library's own** — `ah:Script`, `ah:identity`,
      `ah:targetKind` — and is deliberately shared by every implementation, so a
      client that learns those terms once understands every API this library
      serves. The `@context` is the one place that namespace appears as a
      *value* rather than as the head of an IRI, so a naive rewrite repoints the
      prefix itself and silently moves every library term into the API's
      namespace. That is a real bug this caught, not a hypothetical.
    * **A semantic type is somebody else's IRI.** `https://schema.org/Person`
      identifies schema.org's class, and an API asserting its local `Person` is
      a subclass of it is making a claim *about* that class. Moving it would
      make the claim about a different class — one that does not exist.
    * **`sh:`, `xsd:`, `owl:`, `rdfs:`** likewise: standard vocabularies whose
      IRIs are fixed by their publishers.
  """

  use ExUnit.Case, async: true

  alias AshHateoas.Hydra.Context

  @library "https://ash-hateoas.org/vocab#"
  @origin "https://sim.example.org"
  @local "https://sim.example.org/vocab#"

  describe "where a namespace comes from" do
    test "an API is named after where it is served" do
      assert Context.api_vocab(@origin) == @local
    end

    test "a trailing slash does not produce a doubled one" do
      # The origin arrives from configuration or from a request, and both spell
      # it either way.
      assert Context.api_vocab("#{@origin}/") == @local
    end

    test "with no origin the library namespace stands" do
      # Not a failure state: a document built outside a request has no origin to
      # be named after, and the library namespace is the honest answer rather
      # than a guess at one.
      assert Context.api_vocab(nil) == @library
      assert Context.api_vocab("") == @library
    end
  end

  describe "what localising moves" do
    test "a class IRI becomes this API's" do
      assert Context.localise(%{"@id" => "#{@library}Stock"}, @origin) == %{
               "@id" => "#{@local}Stock"
             }
    end

    test "a property IRI moves with its class" do
      assert Context.localise(%{"p" => "#{@library}stock/name"}, @origin) == %{
               "p" => "#{@local}stock/name"
             }
    end

    test "it reaches every depth, in keys as well as values" do
      # A document nests: a class holds properties, a property holds a range, an
      # operation holds an expects. A rewrite that stopped at the top level
      # would move some IRIs and leave others, which is worse than moving none —
      # the document would then name two namespaces for one vocabulary.
      document = %{
        "a" => [%{"b" => %{"c" => "#{@library}Deep"}}],
        "#{@library}key" => "value"
      }

      assert Context.localise(document, @origin) == %{
               "a" => [%{"b" => %{"c" => "#{@local}Deep"}}],
               "#{@local}key" => "value"
             }
    end

    test "with no origin nothing moves at all" do
      document = %{"@id" => "#{@library}Stock"}

      assert Context.localise(document, nil) == document
    end
  end

  describe "what localising must not move" do
    test "the ah: prefix still points at the library" do
      # The trap, and it was hit: `"ah" => "https://ash-hateoas.org/vocab#"` is
      # a *value* in the context, so a rewrite over the whole document repoints
      # the prefix — and every `ah:Script` in the document then resolves into
      # this API's namespace instead of the library's. Nothing in the JSON looks
      # wrong afterwards.
      document = %{"@context" => Context.context(), "@id" => "#{@library}Stock"}

      localised = Context.localise(document, @origin)

      assert Enum.find_value(localised["@context"], &(is_map(&1) && &1["ah"])) == @library
      assert localised["@id"] == "#{@local}Stock"
    end

    test "a semantic type keeps the publisher's IRI" do
      # `schema:Person` identifies schema.org's class. An API declaring its own
      # `Person` a subclass of it is making a claim about *that* class, so
      # moving the IRI would make the claim about one that does not exist.
      document = %{"@type" => ["#{@library}Person", "https://schema.org/Person"]}

      assert Context.localise(document, @origin) == %{
               "@type" => ["#{@local}Person", "https://schema.org/Person"]
             }
    end

    test "a subclass axiom still names the well-known class" do
      document = %{"rdfs:subClassOf" => %{"@id" => "https://schema.org/Person"}}

      assert Context.localise(document, @origin) == document
    end

    test "standard vocabularies are untouched" do
      # Fixed by their publishers; an API does not get to rename them.
      document = %{
        "sh" => "sh:IRI",
        "xsd" => "xsd:string",
        "owl" => "http://www.w3.org/2002/07/owl#Class",
        "hydra" => "http://www.w3.org/ns/hydra/core#Collection"
      }

      assert Context.localise(document, @origin) == document
    end

    test "a string that merely mentions the namespace mid-way is left alone" do
      # Only the *head* of an IRI is matched, so prose or a value that happens
      # to contain the namespace is not silently edited. A description is not an
      # identifier.
      document = %{"comment" => "see #{@library}Stock for the shape"}

      assert Context.localise(document, @origin) == document
    end
  end

  describe "a consumer can resolve what it is given" do
    test "the document declares its own namespace" do
      # An IRI a client cannot resolve is one it cannot use. The declaration is
      # what lets a client name this API's vocabulary without knowing where the
      # API is deployed — the JSON-LD spelling of a SPARQL `PREFIX`.
      localised = Context.localise(%{"@context" => Context.context()}, @origin)

      assert Enum.find_value(localised["@context"], &(is_map(&1) && &1["vocab"])) == @local
    end

    test "a document with no context is still localised" do
      # Not every emitted body carries one, and an IRI in such a body is no less
      # this API's.
      assert Context.localise(%{"@id" => "#{@library}Stock"}, @origin) == %{
               "@id" => "#{@local}Stock"
             }
    end
  end
end
