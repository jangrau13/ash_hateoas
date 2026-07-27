defmodule AshHateoas.Hydra.Context do
  @moduledoc """
  Hydra / JSON-LD constants and the `@context` this package emits.

  Every Hydra term (`Operation`, `Collection`, `member`, …) resolves to the
  Hydra namespace through the referenced context, so a generic client knows
  `member` means `http://www.w3.org/ns/hydra/core#member` regardless of which
  API served it. That unambiguous grounding is what lets Hydra clients be
  generic.

  The emitted context references the canonical Hydra context and inline-extends
  it with an `ah:` vocabulary for the two facts Hydra core has no term for —
  `multiStep` and `notDelegable` — and for this API's own classes and
  properties.
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
  top, so both Hydra core terms and the `ah:` extension terms resolve.
  """
  @spec context() :: [String.t() | map()]
  def context do
    [
      @hydra_context_url,
      %{
        "ah" => @vocab,
        "xsd" => "http://www.w3.org/2001/XMLSchema#",
        "multiStep" => "ah:multiStep",
        "notDelegable" => "ah:notDelegable"
      }
    ]
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

  Mirrors the JSON:API adapter's `rel/1` so the two transports name the same
  affordance identically when lifted out of context.

      iex> AshHateoas.Hydra.Context.rel_iri(:approve)
      "https://ash-hateoas.org/rels/approve"
  """
  @spec rel_iri(atom() | String.t()) :: String.t()
  def rel_iri(action_name), do: "#{@rel_base}/#{action_name}"
end
