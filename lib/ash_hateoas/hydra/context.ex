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
        # ## Why this map declares prefixes and nothing else
        #
        # A `@context` maps *terms to IRIs*. A term definition's value may be a
        # string, or an object built from JSON-LD keywords (`@id`, `@type`,
        # `@container`, …) — it may **not** carry arbitrary RDF. An entry like
        #
        #     "ah:SaveAction" => %{"rdfs:subClassOf" => %{"@id" => "schema:UpdateAction"}}
        #
        # is an **invalid term definition**, and a conformant JSON-LD 1.1
        # processor does not skip it: it raises and refuses the whole document,
        # so nothing downstream of an expansion step sees a single triple. The
        # raw JSON looks fine either way, which is why the ontology's tests
        # assert on expanded N-Quads rather than on keys.
        #
        # Class and property axioms belong in `AshHateoas.Hydra.Ontology`, in
        # the `@included` block, where a superclass is an ordinary triple. That
        # is also where `ah:identity` — the properties that key a class, which a
        # client matches on when editing an existing record — is declared, as an
        # annotation property.
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
  The `@context` for a record node: the base context plus a term binding for
  every key the node emits.

  A node's keys are flat — `"title"`, `"comments"` — while the ontology declares
  `vocab#article/title` and `vocab#article/comments`. Something has to join the
  two, and that is what this does: each key is bound to the property IRI the
  ApiDocumentation declares for it, so a node's data expands to the very
  properties the ontology describes.

  ## Why every key, not only the mapped ones

  Binding only `semantic_property` mappings would leave instance data and
  vocabulary unable to meet, and it would fail in two ways a reader of the raw
  JSON cannot see — the document looks identical either way:

  - An **unbound** key is *silently dropped*. A JSON-LD processor discards what
    it cannot resolve, so every relationship link on every record node would
    produce zero triples.
  - A key the referenced Hydra context happens to define is **captured**.
    `title` and `name` are Hydra terms, so a record's own `name` would expand
    to `hydra:name` — "the name of the link" — a wrong triple a reasoner will
    consume, which is worse than a drop.

  The `@context` array is ordered and later entries win, so these bindings
  override the Hydra context for the node's own keys while leaving the Hydra
  terms the node genuinely uses (`hydra:operation`, `hydra:collection`, already
  prefixed) untouched.

  ## The IRIs are the documentation's, by construction

  The selection rules mirror `Ontology.property_nodes/2` exactly — same
  attributes, same relationships, and the same `semantic || property_iri` rule
  `ApiDocumentation.supported_properties/2` applies. A key bound here to an IRI
  the ontology does not declare would be a dangling reference, which is the
  defect that module exists to remove; `ontology_test.exs` asserts the two agree.
  """
  @spec context_for(module() | %{atom() => String.t()}) :: [String.t() | map()]
  def context_for(resource) when is_atom(resource) and not is_nil(resource) do
    case node_terms(resource) do
      terms when map_size(terms) == 0 -> context()
      terms -> context() ++ [terms]
    end
  end

  def context_for(semantic_properties) when map_size(semantic_properties) == 0, do: context()

  def context_for(semantic_properties) do
    terms = Map.new(semantic_properties, fn {attribute, iri} -> {to_string(attribute), iri} end)

    context() ++ [terms]
  end

  @doc """
  Adds `@base` to a context, so relative `@id`s resolve against this API.

  A node may legitimately carry a relative `@id`, since `base_url` is optional
  and a deployment behind a proxy may prefer them. But a relative IRI has to
  resolve against *something*, and with no `@base` declared a processor falls
  back to the document's own location. For a document parsed from a string that
  is the last remote context it loaded, which here is Hydra's:

      "@id": "/articles/1"  →  http://www.w3.org/articles/1

  Every record in the API then has an identity under **`w3.org`** — not merely
  wrong but wrong in a way that collides with everyone else's records resolved
  the same way. It is invisible in the JSON, where the `@id` reads exactly as
  intended, and it is why `AshHateoas.Test.JsonLd` exists.

  Declaring `@base` states what the author meant. With `base_url` configured the
  `@id`s are already absolute and this changes nothing — `@base` only ever
  applies to relative IRIs.
  """
  @spec put_base([String.t() | map()], String.t() | nil) :: [String.t() | map()]
  def put_base(context, nil), do: context
  def put_base(context, ""), do: context

  def put_base(context, base) when is_binary(base) do
    context ++ [%{"@base" => String.trim_trailing(base, "/") <> "/"}]
  end

  @doc """
  The term bindings for a resource's node keys: flat key → property IRI.

  Public because a node needs them wherever it appears — read on its own, as a
  collection member, or reached through an expanded link — and they must be
  identical, since one record cannot expand to different triples depending on
  how it was reached.
  """
  @spec node_terms(module()) :: %{String.t() => String.t()}
  def node_terms(resource) do
    with type when is_binary(type) <- AshHateoas.Resource.Info.type(resource) do
      semantic = AshHateoas.Resource.Info.semantic_properties(resource)

      attribute_terms(resource, type, semantic)
      |> Map.merge(calculation_terms(resource, type, semantic))
      |> Map.merge(relationship_terms(resource, type))
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  # A mapped attribute binds to the well-known IRI it declares, matching what the
  # documentation advertises for it; everything else binds to ours.
  defp attribute_terms(resource, type, semantic) do
    resource
    |> AshHateoas.Resource.Info.public_attributes()
    |> Map.new(fn attribute ->
      {to_string(attribute.name),
       Map.get(semantic, attribute.name) || property_iri(type, attribute.name)}
    end)
  rescue
    _ -> %{}
  end

  # A public calculation is a node key too, so it needs a term like any other.
  # Without one the key is *silently dropped* on expansion — the defect stage 2
  # found for relationship links, one property kind further along: present in
  # the JSON, absent from the graph, and identical to the naked eye.
  defp calculation_terms(resource, type, semantic) do
    resource
    |> Ash.Resource.Info.public_calculations()
    |> Map.new(fn calculation ->
      {to_string(calculation.name),
       Map.get(semantic, calculation.name) || property_iri(type, calculation.name)}
    end)
  rescue
    _ -> %{}
  end

  # Every public relationship is a node key — a to-many as its related
  # collection link, a to-one as a node reference (or an expanded node when
  # loaded) — so every one gets a term.
  defp relationship_terms(resource, type) do
    resource
    |> Ash.Resource.Info.public_relationships()
    |> Map.new(&{to_string(&1.name), property_iri(type, &1.name)})
  rescue
    _ -> %{}
  end

  @doc """
  This API's own vocabulary namespace, derived from where it is served.

  **A class belongs to the API that describes it, not to this library.** The
  namespace used to be a module constant, so every API built on this package
  minted its classes under one namespace — and a collision was not
  hypothetical: two services in one system, each declaring a `user` and an
  `api_key`, both emitted `vocab#User`. One IRI, two different classes, which is
  precisely what the "unambiguous grounding" this module opens by claiming rules
  out. It is invisible from inside either service, since one document's IRIs
  look well-formed on their own.

  Derived rather than configured separately, on the same rule `@base` follows:
  the public `base_url` when a deployment states one, the request's own origin
  otherwise. So it needs no new setting to be correct in development, and
  setting `base_url` is what stops a class IRI moving when the service does —
  worth doing, since an IRI is an identity and one that changes with the host
  is several identities.

  `ah:` is unaffected and stays where it is. Terms like `ah:Script` and
  `ah:identity` are the *library's*, shared by every API it serves, and that is
  the one case a shared namespace states correctly.

      iex> AshHateoas.Hydra.Context.api_vocab("https://sim.example.org")
      "https://sim.example.org/vocab#"

      iex> AshHateoas.Hydra.Context.api_vocab(nil)
      "https://ash-hateoas.org/vocab#"
  """
  @spec api_vocab(String.t() | nil) :: String.t()
  def api_vocab(nil), do: @vocab
  def api_vocab(""), do: @vocab

  def api_vocab(origin) when is_binary(origin) do
    String.trim_trailing(origin, "/") <> "/vocab#"
  end

  @doc """
  Rewrite every library-namespaced vocabulary IRI to this API's own.

  Applied once, to a whole built document, rather than threaded through the
  fifty-odd sites that mint an IRI. Two reasons, and the second is the one that
  decided it: a document is emitted through exactly one function, so one pass
  cannot miss a path; and three of those sites are **compile-time
  transformers**, which have no request to read an origin from. Two of them
  emit the `sh:class` list a client reads to decide what a document may hold,
  so leaving them behind would have the save operation naming classes in a
  namespace the classes are not declared in — a client would resolve nothing.

  Rewriting the *string prefix* is safe because the namespace only ever appears
  as the head of an IRI this package minted. It is not a general find-replace
  over content: keys and values are walked structurally, and only a binary that
  starts with the namespace is touched.
  """
  @spec localise(term(), String.t() | nil) :: term()
  def localise(document, origin) do
    case api_vocab(origin) do
      @vocab ->
        document

      vocab ->
        document
        |> rewrite(vocab)
        |> restore_context(document)
        |> declare(vocab)
    end
  end

  # **Only the prefix binding is put back, never the whole context.**
  #
  # A context carries two different things and they need opposite treatment. The
  # prefix map binds `"ah"` to the library namespace as a *value*, so rewriting
  # it repoints the prefix itself and every `ah:Script` in the document resolves
  # into this API's namespace instead of the library's — silent, and it breaks
  # the terms this change exists to keep shared.
  #
  # The **term bindings** are the opposite case: `context_for/1` appends a map
  # of a node's flat keys to *this API's own property IRIs*, and those must move
  # with everything else. Restoring the whole context left them behind, so a
  # node's keys bound to IRIs the document no longer declared — the keys then
  # expanded to nothing, which is the silent-drop defect `node_terms/1` exists
  # to prevent, reintroduced from the other end. Caught by the expansion tests,
  # which is what they are for: the raw JSON reads identically either way.
  defp restore_context(%{"@context" => rewritten} = document, %{"@context" => original})
       when is_list(rewritten) and is_list(original) do
    Map.put(document, "@context", Enum.map(rewritten, &restore_prefixes(&1, original)))
  end

  defp restore_context(document, _original), do: document

  # A prefix map is the one whose entries bind a *namespace*, which is exactly
  # what the original said. Matched by position rather than by inspecting the
  # values, since a term binding and a prefix binding are both string→string.
  defp restore_prefixes(part, original) do
    Enum.find(original, part, fn candidate ->
      is_map(candidate) and is_map(part) and Map.keys(candidate) == Map.keys(part) and
        Map.has_key?(candidate, "ah")
    end)
  end

  # A namespace a consumer cannot resolve is a namespace it cannot use, so the
  # document declares its own under the empty prefix — the JSON-LD spelling of
  # SPARQL's `PREFIX : <…>`, and what lets a client name this API's vocabulary
  # without knowing where the API is deployed.
  defp declare(%{"@context" => context} = document, vocab) when is_list(context) do
    Map.put(document, "@context", context ++ [%{"vocab" => vocab}])
  end

  defp declare(document, _vocab), do: document

  defp rewrite(value, vocab) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, inner} -> {rewrite(key, vocab), rewrite(inner, vocab)} end)
  end

  defp rewrite(value, vocab) when is_list(value), do: Enum.map(value, &rewrite(&1, vocab))

  defp rewrite(@vocab <> segment, vocab), do: vocab <> segment

  defp rewrite(value, _vocab), do: value

  @doc """
  The vocabulary IRI for a term (`"ah:…"` expands to the vocab namespace).

      iex> AshHateoas.Hydra.Context.vocab_iri("ValidationReport")
      "https://ash-hateoas.org/vocab#ValidationReport"
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
