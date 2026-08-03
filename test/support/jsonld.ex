defmodule AshHateoas.Test.JsonLd do
  @moduledoc """
  Expands emitted documents with a real JSON-LD processor.

  Every assertion about what this package *means* belongs here rather than on
  the raw JSON. Two shipped defects make the case, and neither was visible to a
  key-based assertion:

  - **Four malformed `@context` term definitions.** `"ah:SaveAction" => %{"rdfs:subClassOf" => …}`
    and three like it. A term definition admits JSON-LD keywords only, so a
    conformant processor rejects the **whole document** — every ApiDocumentation
    this package emitted failed to expand, and nothing downstream ever saw a
    triple. In the JSON the entries look perfect.

  - **Record nodes bound no terms.** A node emitted `"title"` and `"comments"`
    while the ontology declared `vocab#article/title` and
    `vocab#article/comments`, and nothing joined them. Unbound keys were
    *silently dropped* — every relationship link produced zero triples — and
    keys the Hydra context happens to define were *captured*, so a record's own
    `name` expanded to `hydra:name`. Again: identical JSON either way.

  Hand-rolling term resolution in a test would encode the emitter's own
  assumptions and agree with itself. An independent implementation is what makes
  these assertions evidence rather than restatement.

  ## Why the Hydra context is vendored

  Expansion dereferences `http://www.w3.org/ns/hydra/context.jsonld`. Fetching it
  would make the suite fail offline and, worse, make it pass or fail on
  something outside the repository — a W3C outage would read as a defect here.
  The file in `test/support/fixtures` is that context, served locally.

  `load/2` **raises on any other URL** rather than falling through to the
  network. A silent fetch is how a test starts depending on a resource nobody
  declared, and this module exists because silence is the failure mode.
  """

  @behaviour JSON.LD.DocumentLoader

  alias JSON.LD.DocumentLoader.RemoteDocument

  @hydra_context "http://www.w3.org/ns/hydra/context.jsonld"
  @fixture Path.join(__DIR__, "fixtures/hydra-context.jsonld")

  @external_resource @fixture

  @impl true
  def load(@hydra_context = url, _options) do
    {:ok,
     %RemoteDocument{
       document: @fixture |> File.read!() |> Jason.decode!(),
       document_url: url,
       content_type: "application/ld+json"
     }}
  end

  def load(url, _options) do
    raise """
    the JSON-LD test loader refused a remote fetch: #{url}

    Only the vendored Hydra context is served locally. A document reaching for
    anything else would make this suite depend on the network — add the document
    to test/support/fixtures and serve it here instead.
    """
  end

  @doc """
  Expands a document and returns its node objects.

  Raises if the document does not expand — which is the assertion that matters
  most, and the one the malformed term definitions failed for the entire life of
  the package.
  """
  @spec expand(map()) :: [map()]
  def expand(document) do
    JSON.LD.expand(document, document_loader: __MODULE__)
  end

  @doc """
  The expanded node for a record, found by the **path** its `@id` ends with.

  Matching on a path rather than the whole IRI is deliberate: a node's `@id` may
  be relative (`/articles/1`), and expansion resolves it against the document's
  `@base`. So the IRI in the JSON and the IRI in the graph are legitimately
  different strings, and asserting on the raw one would be asserting on the
  wrong thing — which is how every record resolving under `http://www.w3.org/`
  went unnoticed.

  Searches nested nodes too, since a collection's members are nested under
  `hydra:member` rather than sitting at the top level.
  """
  @spec node(map(), String.t()) :: map()
  def node(document, path) do
    nodes = nodes(document)

    Enum.find(nodes, &(&1["@id"] && String.ends_with?(&1["@id"], path))) ||
      raise """
      no expanded node whose @id ends with #{path}

      expanded @ids: #{inspect(Enum.map(nodes, & &1["@id"]))}
      """
  end

  @doc """
  Every expanded node in a document, nested ones included.

  Expansion nests a collection's members under `hydra:member` rather than
  flattening them, so a member is not reachable at the top level.
  """
  @spec nodes(map()) :: [map()]
  def nodes(document) do
    document |> expand() |> Enum.flat_map(&flatten/1)
  end

  defp flatten(node) when is_map(node) do
    nested =
      node
      |> Map.drop(["@id", "@type", "@value"])
      |> Map.values()
      |> List.flatten()
      |> Enum.filter(&is_map/1)
      |> Enum.flat_map(&flatten/1)

    [node | nested]
  end

  defp flatten(_other), do: []

  @doc """
  The predicate IRIs a node asserts — what the document actually *says*, with
  every key resolved through the context that shipped with it.

  A key bound to nothing never appears here, which is the point: a dropped key
  is indistinguishable from an absent one once expanded, and that is exactly how
  a missing relationship link goes unnoticed.
  """
  @spec predicates(map()) :: [String.t()]
  def predicates(node) do
    node
    |> Map.keys()
    |> Enum.reject(&String.starts_with?(&1, "@"))
    |> Enum.sort()
  end

  @doc """
  The lexical values a node asserts for a predicate IRI.
  """
  @spec values(map(), String.t()) :: [term()]
  def values(node, predicate) do
    node
    |> Map.get(predicate, [])
    |> Enum.map(fn
      %{"@value" => value} -> value
      %{"@id" => id} -> id
      other -> other
    end)
  end
end
