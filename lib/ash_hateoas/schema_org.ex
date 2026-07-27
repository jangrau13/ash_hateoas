defmodule AshHateoas.SchemaOrg do
  @moduledoc """
  Fetches a schema.org type definition live, so a resource can be scaffolded from
  a schema.org URL rather than hand-transcribing its properties.

  The generator (`mix ash_hateoas.gen.schema_org`) uses this; it is also usable
  directly. It downloads the published schema.org vocabulary graph and reads a
  class's properties from it, mapping each property's `rangeIncludes` to the
  closest Ash type.

  Requires an HTTP client (`req`) at runtime — an optional dependency, so this
  module only works where it is present.
  """

  @graph_url "https://schema.org/version/latest/schemaorg-current-https.jsonld"
  @schema "https://schema.org/"

  @typedoc "A resolved schema.org property"
  @type property :: %{
          name: String.t(),
          iri: String.t(),
          ash_type: atom(),
          # The schema.org type this property links to, when its range is
          # another type rather than a datatype (so `ash_type` is a resource
          # link). `nil` for scalar-valued properties.
          links_to: String.t() | nil,
          description: String.t() | nil
        }

  @typedoc "A resolved schema.org type"
  @type type_def :: %{
          label: String.t(),
          iri: String.t(),
          description: String.t() | nil,
          properties: [property()]
        }

  # schema.org range → Ash type. Anything else (another schema.org class, an
  # enumeration) is treated as a reference and falls back to :string.
  @range_types %{
    "schema:Text" => :string,
    "schema:URL" => :string,
    "schema:Integer" => :integer,
    "schema:Number" => :decimal,
    "schema:Float" => :decimal,
    "schema:Boolean" => :boolean,
    "schema:Date" => :date,
    "schema:Time" => :time,
    "schema:DateTime" => :utc_datetime
  }

  @doc """
  Resolve a schema.org type — given a label (`"Person"`) or full URL
  (`"https://schema.org/Person"`) — into its label, IRI, description and
  properties.

  ## Options

    * `:inherited` — when `true`, include properties of the type's ancestors too
      (via `rdfs:subClassOf`). Defaults to `false` (direct properties only).
    * `:graph` — a pre-fetched decoded graph (the `@graph` list), to avoid a
      network call; fetched via `fetch_graph/0` otherwise.
  """
  @spec resolve(String.t(), keyword()) :: {:ok, type_def()} | {:error, term()}
  def resolve(type, opts \\ []) do
    label = label_of(type)
    class_id = "schema:" <> label

    with {:ok, graph} <- graph(opts),
         node when not is_nil(node) <- find_class(graph, class_id) do
      class_ids = [class_id | if(opts[:inherited], do: ancestors(graph, class_id), else: [])]

      {:ok,
       %{
         label: label,
         iri: @schema <> label,
         description: text(node["rdfs:comment"]),
         properties: properties_for(graph, class_ids)
       }}
    else
      nil -> {:error, {:type_not_found, label}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Download and decode the schema.org vocabulary graph (the `@graph` list).

  Raises if `req` is not available.
  """
  @spec fetch_graph() :: {:ok, [map()]} | {:error, term()}
  def fetch_graph do
    unless Code.ensure_loaded?(Req) do
      raise "AshHateoas.SchemaOrg requires the :req dependency to fetch schema.org live."
    end

    # In a mix-task context the app tree is not started, so Req's Finch pool
    # would be absent — start it (and its deps) before the request.
    {:ok, _} = Application.ensure_all_started(:req)

    case Req.get(@graph_url, decode_body: false) do
      {:ok, %{status: 200, body: body}} ->
        with {:ok, decoded} <- Jason.decode(body) do
          {:ok, Map.get(decoded, "@graph", [])}
        end

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── internals ───────────────────────────────────────────────────────────────

  defp graph(opts) do
    case Keyword.get(opts, :graph) do
      nil -> fetch_graph()
      graph when is_list(graph) -> {:ok, graph}
    end
  end

  defp label_of(type) do
    type
    |> to_string()
    |> String.trim_trailing("/")
    |> String.split("/")
    |> List.last()
    |> String.split("#")
    |> List.last()
  end

  defp find_class(graph, class_id) do
    Enum.find(graph, fn node ->
      node["@id"] == class_id and rdfs_class?(node["@type"])
    end)
  end

  defp rdfs_class?("rdfs:Class"), do: true
  defp rdfs_class?(types) when is_list(types), do: "rdfs:Class" in types
  defp rdfs_class?(_), do: false

  # The chain of `rdfs:subClassOf` ancestors, nearest first.
  defp ancestors(graph, class_id, seen \\ []) do
    case find_class(graph, class_id) do
      nil ->
        []

      node ->
        node["rdfs:subClassOf"]
        |> ids()
        |> Enum.reject(&(&1 in seen))
        |> Enum.flat_map(fn parent -> [parent | ancestors(graph, parent, [parent | seen])] end)
        |> Enum.uniq()
    end
  end

  defp properties_for(graph, class_ids) do
    class_set = MapSet.new(class_ids)
    # Every id in the graph that is itself a type, so a property range pointing
    # at one is a reference to another resource rather than a scalar.
    types = type_ids(graph)

    graph
    |> Enum.filter(fn node ->
      property?(node["@type"]) and
        node["schema:domainIncludes"] |> ids() |> Enum.any?(&MapSet.member?(class_set, &1))
    end)
    |> Enum.map(&to_property(&1, types))
    |> Enum.uniq_by(& &1.name)
    |> Enum.sort_by(& &1.name)
  end

  defp type_ids(graph) do
    for node <- graph, rdfs_class?(node["@type"]), into: MapSet.new(), do: node["@id"]
  end

  defp property?("rdf:Property"), do: true
  defp property?(types) when is_list(types), do: "rdf:Property" in types
  defp property?(_), do: false

  defp to_property(node, types) do
    label = node["rdfs:label"] |> text() || strip_prefix(node["@id"])
    {ash_type, links_to} = classify_range(node["schema:rangeIncludes"], types)

    %{
      name: Macro.underscore(label),
      iri: @schema <> label,
      ash_type: ash_type,
      links_to: links_to,
      description: text(node["rdfs:comment"])
    }
  end

  # A property's range decides its Ash type:
  #
  #   * a scalar datatype (`schema:Text`, `schema:Date`, …) → the mapped Ash
  #     scalar;
  #   * ELSE if the range is another schema.org **type**, the value is a link to
  #     that resource → `AshHateoas.Type.ResourceLink`, which renders as a
  #     followable `@id` in JSON-LD. The linked type is recorded in `links_to`;
  #   * otherwise (an enumeration or an unmapped datatype) → `:string`.
  #
  # A scalar range wins over a type range when a property allows both
  # (`address` ranges over `PostalAddress` OR `Text`), because a plain string is
  # always representable and needs no companion resource.
  defp classify_range(range, types) do
    range_ids = ids(range)

    cond do
      scalar = Enum.find_value(range_ids, &Map.get(@range_types, &1)) ->
        {scalar, nil}

      linked = Enum.find(range_ids, &MapSet.member?(types, &1)) ->
        {AshHateoas.Type.ResourceLink, strip_prefix(linked)}

      true ->
        {:string, nil}
    end
  end

  # `%{"@id" => x}` | `[%{"@id" => x}, …]` | nil → list of id strings.
  defp ids(nil), do: []
  defp ids(%{"@id" => id}), do: [id]
  defp ids(list) when is_list(list), do: Enum.flat_map(list, &ids/1)
  defp ids(_), do: []

  defp strip_prefix("schema:" <> rest), do: rest
  defp strip_prefix(id) when is_binary(id), do: id |> String.split("/") |> List.last()
  defp strip_prefix(_), do: nil

  # `rdfs:comment`/`rdfs:label` may be a plain string or a language-map object.
  defp text(nil), do: nil
  defp text(value) when is_binary(value), do: value
  defp text(%{"@value" => value}), do: value
  defp text(_), do: nil
end
