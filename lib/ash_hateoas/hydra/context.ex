defmodule AshHateoas.Hydra.Context do
  @moduledoc """
  Hydra / JSON-LD constants and the `@context` this package emits.

  Every Hydra term (`Operation`, `Collection`, `member`, …) resolves to the
  Hydra namespace through the referenced context, so a generic client knows
  `member` means `http://www.w3.org/ns/hydra/core#member` regardless of which
  API served it. That unambiguous grounding is what lets Hydra clients be
  generic.

  The emitted context references the canonical Hydra context and inline-extends
  it with this package's own vocabulary (`ah:`) and the standard prefixes
  `xsd:`, `owl:`, `schema:`, `odrl:`, `sh:`, `jsonschema:`. Every
  such term is emitted **prefixed** on the wire, so no per-term aliases are
  declared — only the prefixes. Bare tokens are used solely for `@type` *values*
  the Hydra context already resolves (`Operation`, `Collection`, …).
  """

  @namespace "http://www.w3.org/ns/hydra/core#"
  @hydra_context_url "http://www.w3.org/ns/hydra/context.jsonld"
  @content_type "application/ld+json"
  @vocab "https://ash-hateoas.org/vocab#"
  @rel_base "https://ash-hateoas.org/rels"

  @doc "The Hydra core namespace IRI."
  @spec namespace() :: String.t()
  def namespace, do: @namespace

  @doc "The media type Hydra documents are served as."
  @spec content_type() :: String.t()
  def content_type, do: @content_type

  @doc "The IRI of the API-documentation link relation, for the `Link` header."
  @spec api_documentation_rel() :: String.t()
  def api_documentation_rel, do: @namespace <> "apiDocumentation"

  @doc """
  The `@context` value embedded in every emitted document.

  References the canonical Hydra context and layers this package's own vocab on
  top, so both Hydra core terms and the extension terms resolve.
  """
  @spec context() :: [String.t() | map()]
  def context do
    [
      @hydra_context_url,
      %{
        "ah" => @vocab,
        "xsd" => "http://www.w3.org/2001/XMLSchema#",
        "owl" => "http://www.w3.org/2002/07/owl#",
        "schema" => "https://schema.org/",
        "odrl" => "http://www.w3.org/ns/odrl/2/",
        "sh" => "http://www.w3.org/ns/shacl#",
        "jsonschema" => "https://www.w3.org/2019/wot/json-schema#",
        # `ah:identity` names the properties that key a class — what a client
        # matches on when it edits an existing record. No published vocabulary
        # says that without dragging something else along, so the term is
        # declared in `AshHateoas.Hydra.Ontology` as an annotation property.
        #
        # It used to be declared here as `rdfs:subPropertyOf owl:hasKey`, and
        # that was unsound twice over. `owl:hasKey` is a *class* axiom, taking a
        # class expression and an `rdf:List` of properties — it cannot sit on a
        # property node, and the nested-array value here is not an `rdf:List`
        # anyway. And it licenses a reasoner to infer `owl:sameAs` between
        # individuals sharing key values, which for a *business* key like a name
        # means two legitimately distinct records get merged and their
        # properties unioned. That is the data corruption the term exists to
        # prevent, arrived at by declaring the term.
        #
        # The value is a list of identities, each itself a list of properties,
        # since a composite key names several at once. That nesting is left as
        # plain JSON rather than declared with `@container`, which cannot
        # express a list of lists.
        #
        # ## Why no `ah:` term is defined here any more
        #
        # This map used to carry four entries of the form
        #
        #     "ah:SaveAction" => %{"rdfs:subClassOf" => %{"@id" => "schema:UpdateAction"}}
        #
        # — `ah:SaveAction`, `ah:RunAction`, `ah:ValidationReport` and
        # `ah:ValidationError`, each stating a superclass. They looked harmless
        # and they broke the entire document.
        #
        # A `@context` maps *terms to IRIs*. A term definition's value may be a
        # string, or an object built from JSON-LD keywords (`@id`, `@type`,
        # `@container`, …) — it may **not** carry arbitrary RDF. `rdfs:subClassOf`
        # is not a keyword, so each of these is an **invalid term definition**,
        # and a conformant JSON-LD 1.1 processor does not skip it: it raises and
        # refuses the whole document. Verified with `pyld` — every emitted
        # ApiDocumentation failed to expand, so nothing downstream of an
        # expansion step ever saw a single triple.
        #
        # It went unseen because every test asserted on the raw JSON, where the
        # entries look fine and the keys are present. That is exactly why the
        # ontology's own tests assert on expanded N-Quads instead.
        #
        # The axioms themselves were worth stating; only the location was wrong.
        # They now live in `AshHateoas.Hydra.Ontology`, in the `@included` block,
        # where a superclass is an ordinary triple rather than a malformed
        # mapping.
        "rdfs" => "http://www.w3.org/2000/01/rdf-schema#",
        # Needed by the ontology block: a union-typed property is declared a
        # bare `rdf:Property`, since OWL keeps object and datatype properties
        # strictly apart and picking one would be a guess. An unbound prefix is
        # *silently dropped* by a JSON-LD processor, so this binding is what
        # keeps those declarations from vanishing without an error.
        "rdf" => "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
      }
      |> put_semantic_vocab()
    ]
  end

  # Declare the configured semantic-vocabulary prefix (schema.org by default),
  # so a customer's own ontology base compacts under their chosen prefix. The
  # built-in `schema` binding above is always kept, so a resource may still write
  # absolute schema.org IRIs even when the default vocab is something else.
  defp put_semantic_vocab(terms) do
    prefix = AshHateoas.SemanticVocab.prefix()
    Map.put_new(terms, prefix, AshHateoas.SemanticVocab.base())
  end

  @doc """
  The `@context` for a resource node, extended with its `semantic_property`
  mappings.

  Each mapped attribute's flat key is bound to its well-known property IRI, so a
  client reading the node sees the value as that property (e.g.
  `"additional_name"` resolving to `https://schema.org/additionalName`). With no
  mappings this is the base `context/0`.
  """
  @spec context_for(%{atom() => String.t()}) :: [String.t() | map()]
  def context_for(semantic_properties) when map_size(semantic_properties) == 0, do: context()

  def context_for(semantic_properties) do
    terms = Map.new(semantic_properties, fn {attribute, iri} -> {to_string(attribute), iri} end)

    context() ++ [terms]
  end

  @doc """
  The vocabulary IRI for a term (`"ah:…"` expands to the vocab namespace).

      iex> AshHateoas.Hydra.Context.vocab_iri("multiStep")
      "https://ash-hateoas.org/vocab#multiStep"
  """
  @spec vocab_iri(atom() | String.t()) :: String.t()
  def vocab_iri(segment), do: @vocab <> to_string(segment)

  @doc """
  The class IRI for a resource type string.

      iex> AshHateoas.Hydra.Context.class_iri("document")
      "https://ash-hateoas.org/vocab#Document"
  """
  @spec class_iri(String.t()) :: String.t()
  def class_iri(type) when is_binary(type) do
    @vocab <> Macro.camelize(type)
  end

  @doc """
  A node's `@type` value: the resource's own class IRI, plus any declared
  well-known (e.g. schema.org) type.

  With no semantic type it is a single class IRI string; with one it is a list
  `[class_iri, semantic_type]`, so a JSON-LD client sees the node as being both.

      iex> AshHateoas.Hydra.Context.node_type("document", nil)
      "https://ash-hateoas.org/vocab#Document"

      iex> AshHateoas.Hydra.Context.node_type("person", "https://schema.org/Person")
      ["https://ash-hateoas.org/vocab#Person", "https://schema.org/Person"]
  """
  @spec node_type(String.t(), String.t() | nil) :: String.t() | [String.t()]
  def node_type(type, nil), do: class_iri(type)
  def node_type(type, semantic_type), do: [class_iri(type), semantic_type]

  @doc """
  The property IRI for a type + field name.

      iex> AshHateoas.Hydra.Context.property_iri("document", :title)
      "https://ash-hateoas.org/vocab#document/title"
  """
  @spec property_iri(String.t(), atom() | String.t()) :: String.t()
  def property_iri(type, field) when is_binary(type) do
    @vocab <> type <> "/" <> to_string(field)
  end

  @doc """
  The relation-type IRI for an action name.

  A stable, dereferenceable relation type for an affordance, so the relation is
  unambiguous when a link is lifted out of its document.

      iex> AshHateoas.Hydra.Context.rel_iri(:approve)
      "https://ash-hateoas.org/rels/approve"
  """
  @spec rel_iri(atom() | String.t()) :: String.t()
  def rel_iri(action_name), do: "#{@rel_base}/#{action_name}"
end
