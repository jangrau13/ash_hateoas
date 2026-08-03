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
        # declared here and related to the nearest standard one.
        #
        # `owl:hasKey` states the same fact ("no two named instances of this
        # class coincide on these properties") but as a reasoning axiom: it
        # licenses an engine to conclude two records are the same individual.
        # Declaring `ah:identity` a subproperty gives that weaker inference to
        # anything reasoning over the document, while a client reads the
        # narrower, actionable term.
        # The value is a list of identities, each itself a list of properties,
        # since a composite key names several at once. That nesting is left as
        # plain JSON rather than declared with `@container`, which cannot
        # express a list of lists.
        "ah:identity" => %{"rdfs:subPropertyOf" => %{"@id" => "owl:hasKey"}},
        # Two operation roles schema.org cannot express, each related to the
        # nearest published term so a client that speaks only schema.org still
        # learns something true.
        #
        # `ah:SaveAction` — writing a whole document, rather than one record.
        # `schema:UpdateAction` describes the act correctly but is also what
        # this package infers for *any* PATCH, so declaring it would make a
        # document save indistinguishable from an ordinary record update. The
        # subclass says "this writes" to a generic reader and "this writes a
        # document" to one that knows the term.
        #
        # `ah:RunAction` — executing a resource. schema.org has no term for it:
        # `ControlAction` and `ActivateAction` are device control, and
        # `AchieveAction`'s subtypes are Win/Lose/Tie. `schema:Action` is the
        # only honest parent — it says an agent does something, which is all
        # that is shared.
        "ah:SaveAction" => %{"rdfs:subClassOf" => %{"@id" => "schema:UpdateAction"}},
        "ah:RunAction" => %{"rdfs:subClassOf" => %{"@id" => "schema:Action"}},
        # What a document action gives back: a verdict and, when it is negative,
        # one entry per problem. It is not the resource — a validate writes
        # nothing and has no record to return, and a save reports failures the
        # same way rather than returning the aggregate it did not write.
        #
        # Declared because the alternative is a client hardcoding the shape from
        # having read the source, which is what both consumers do today.
        "ah:ValidationReport" => %{"rdfs:subClassOf" => %{"@id" => "hydra:Resource"}},
        "ah:ValidationError" => %{"rdfs:subClassOf" => %{"@id" => "hydra:Resource"}},
        "rdfs" => "http://www.w3.org/2000/01/rdf-schema#"
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
