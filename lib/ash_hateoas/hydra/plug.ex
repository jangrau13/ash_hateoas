defmodule AshHateoas.Hydra.Plug do
  @moduledoc """
  Serves an Ash domain as a Hydra / JSON-LD API.

  This is the native transport: it does its own Ash reads and writes and its own
  JSON-LD serialization, rather than decorating another serializer's output. It
  reads the routes `AshHateoas.Resource` derives (the single source of what
  exists and where it lives) to match requests and build hrefs.

      defmodule MyApp.HydraRouter do
        use Plug.Builder
        plug AshHateoas.Hydra.Plug,
          domains: [MyApp.Docs],
          prefix: "/api",
          doc_path: "/doc"
      end

  ## What it serves

  | request | response |
  |---|---|
  | `GET /` | the `hydra:ApiDocumentation` entrypoint — reachable types + links |
  | `GET <doc_path>` | the full `ApiDocumentation` (`supportedClass`…) |
  | `GET <collection>` | a `hydra:Collection` with `member` + `totalItems` |
  | `GET <member>` | the resource node with its gated `hydra:operation`s |

  Writes (`POST`/`PATCH`/`DELETE`) arrive in a later phase.

  Every response carries `Content-Type: application/ld+json` and a `Link` header
  advertising the API documentation, so a generic client discovers the whole API
  from any single response (see the Hydra client flow).
  """

  @behaviour Plug

  require Logger

  alias AshHateoas.Hydra.{ApiDocumentation, Collection, Context, Renderer}
  alias AshHateoas.{Index, Navigation, Route}

  @impl Plug
  def init(opts) do
    domains = opts |> Keyword.get(:domains, Keyword.get(opts, :domain)) |> List.wrap()

    opts
    |> Keyword.put(:domains, domains)
    |> Keyword.put_new(:doc_path, "/doc")
  end

  @impl Plug
  def call(conn, opts) do
    conn = put_link_header(conn, opts)
    actor = Ash.PlugHelpers.get_actor(conn)
    tenant = Ash.PlugHelpers.get_tenant(conn)

    dispatch(conn, path_segments(conn, opts), actor, tenant, opts)
  rescue
    exception ->
      Logger.error("""
      [ash_hateoas] Hydra request failed.

      #{Exception.format(:error, exception, __STACKTRACE__)}
      """)

      send_json(conn, 500, %{"@type" => "Error", "hydra:statusCode" => 500})
  end

  # ── Dispatch ────────────────────────────────────────────────────────────────

  # The root entry document: every reachable type and its collection link.
  defp dispatch(%{method: "GET"} = conn, [], actor, _tenant, opts) do
    document =
      Context.context()
      |> then(&%{"@context" => &1, "@type" => "EntryPoint"})
      |> Map.put("hydra:collection", Navigation.root(opts[:domains], actor, nav_opts(opts)))

    send_json(conn, 200, document)
  end

  defp dispatch(%{method: "GET"} = conn, segments, actor, _tenant, opts) do
    if segments == doc_segments(opts) do
      send_json(conn, 200, ApiDocumentation.build(opts[:domains], doc_opts(conn, opts)))
    else
      serve_get(conn, segments, actor, opts)
    end
  end

  defp dispatch(conn, _segments, _actor, _tenant, _opts) do
    # Writes are handled in a later phase; anything else is not found.
    send_json(conn, 404, %{"@type" => "Error", "hydra:statusCode" => 404})
  end

  # ── GET reads ─────────────────────────────────────────────────────────────

  defp serve_get(conn, segments, actor, opts) do
    case match(segments, opts) do
      {:member, resource, type, id} ->
        serve_member(conn, resource, type, id, actor, opts)

      {:collection, resource, type} ->
        serve_collection(conn, resource, type, actor, opts)

      :error ->
        send_json(conn, 404, %{"@type" => "Error", "hydra:statusCode" => 404})
    end
  end

  defp serve_member(conn, resource, type, id, actor, opts) do
    tenant = Ash.PlugHelpers.get_tenant(conn)

    case load(resource, id, actor, tenant) do
      nil ->
        send_json(conn, 404, %{"@type" => "Error", "hydra:statusCode" => 404})

      record ->
        node = node(record, type, resource, id, actor, tenant, opts)
        send_json(conn, 200, Map.put(node, "@context", Context.context()))
    end
  end

  defp serve_collection(conn, resource, type, actor, opts) do
    tenant = Ash.PlugHelpers.get_tenant(conn)

    case read(resource, actor, tenant) do
      {:ok, records} ->
        members =
          Enum.map(records, fn record ->
            id = record_id(record)
            node(record, type, resource, id, actor, tenant, opts, scope: :collection)
          end)

        # Collection-level affordances (create, …) live on the collection, not
        # on its members — this keeps a collection response independent of page
        # size.
        operations =
          resource
          |> AshHateoas.affordances(actor, affordance_opts(resource, opts))
          |> Renderer.render(render_opts(type, opts))

        document =
          Collection.wrap(members,
            id: collection_href(resource, opts),
            total_items: length(records),
            operations: operations
          )
          |> Map.put("@context", Context.context())

        send_json(conn, 200, document)

      :error ->
        send_json(conn, 403, %{"@type" => "Error", "hydra:statusCode" => 403})
    end
  end

  # ── Node building ─────────────────────────────────────────────────────────

  # A resource node: its attributes flattened onto the node, its identity, and
  # (for a member) its gated operations + structural navigation.
  defp node(record, type, resource, id, actor, tenant, opts, node_opts \\ []) do
    base =
      record
      |> attributes(resource)
      |> Map.merge(%{
        "@id" => member_href(resource, id, opts),
        "@type" => Context.class_iri(type)
      })

    case Keyword.get(node_opts, :scope, :member) do
      :collection ->
        base

      :member ->
        operations =
          record
          |> AshHateoas.affordances(actor, affordance_opts(resource, opts) ++ [tenant: tenant])
          |> Renderer.render(render_opts(type, opts, node_id: member_href(resource, id, opts), path_params: %{"id" => id}))

        nav = Navigation.record_links(record, opts[:domains], nav_opts(opts))

        base
        |> Map.merge(operations)
        |> merge_navigation(nav)
    end
  end

  defp attributes(record, resource) do
    resource
    |> Ash.Resource.Info.public_attributes()
    |> Map.new(fn attribute ->
      {to_string(attribute.name), encodable(Map.get(record, attribute.name))}
    end)
  end

  # Navigation links (`collection`, `up`) map onto Hydra link terms.
  defp merge_navigation(node, nav) do
    Enum.reduce(nav, node, fn
      {"collection", %{"href" => href}}, acc -> Map.put(acc, "hydra:collection", %{"@id" => href})
      {"up", %{"href" => href}}, acc -> Map.put(acc, "hydra:view", %{"@id" => href})
      _other, acc -> acc
    end)
  end

  # ── Route matching ──────────────────────────────────────────────────────────

  # Match the request path against the derived routes, returning the resource
  # and whether it is a member or collection read.
  defp match(segments, opts) do
    path = "/" <> Enum.join(segments, "/")

    opts[:domains]
    |> Index.build()
    |> Enum.find_value(:error, fn {type, resource} ->
      match_resource(resource, type, path, opts)
    end)
  end

  defp match_resource(resource, type, path, opts) do
    prefix = prefix(opts)

    resource
    |> AshHateoas.Resource.Info.routes()
    |> Enum.find_value(fn %Route{} = route -> match_route(route, resource, type, path, prefix) end)
  end

  defp match_route(%Route{type: :index, route: route}, resource, type, path, prefix) do
    if prefix <> route == path, do: {:collection, resource, type}, else: nil
  end

  defp match_route(%Route{type: :get, primary?: true, route: route}, resource, type, path, prefix) do
    case capture_id(prefix <> route, path) do
      nil -> nil
      id -> {:member, resource, type, id}
    end
  end

  defp match_route(_route, _resource, _type, _path, _prefix), do: nil

  # `/documents/:id` against `/documents/123` yields `"123"`; nil on no match.
  defp capture_id(pattern, path) do
    pattern_segs = String.split(pattern, "/", trim: true)
    path_segs = String.split(path, "/", trim: true)

    if length(pattern_segs) == length(path_segs) do
      pattern_segs
      |> Enum.zip(path_segs)
      |> Enum.reduce_while(nil, fn
        {":id", value}, _acc -> {:cont, value}
        {same, same}, acc -> {:cont, acc}
        {_a, _b}, _acc -> {:halt, :no_match}
      end)
      |> case do
        :no_match -> nil
        id -> id
      end
    end
  end

  # ── Ash calls ───────────────────────────────────────────────────────────────

  defp load(resource, id, actor, tenant) do
    case Ash.get(resource, id, actor: actor, tenant: tenant, authorize?: true) do
      {:ok, record} -> record
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp read(resource, actor, tenant) do
    case Ash.read(resource, actor: actor, tenant: tenant, authorize?: true) do
      {:ok, records} -> {:ok, records}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp record_id(record) do
    resource = record.__struct__

    case Ash.Resource.Info.primary_key(resource) do
      [key] -> record |> Map.get(key) |> to_string()
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # ── Hrefs ─────────────────────────────────────────────────────────────────

  defp collection_href(resource, opts) do
    Navigation.collection_href(resource, opts[:domains], nav_opts(opts))
  end

  defp member_href(resource, id, opts) do
    case get_route(resource, &(&1.type == :get and &1.primary?)) do
      nil -> nil
      route -> prefix(opts) <> String.replace(route.route, ":id", to_string(id))
    end
  end

  defp get_route(resource, fun) do
    resource
    |> AshHateoas.Resource.Info.routes()
    |> Enum.find(fun)
  rescue
    _ -> nil
  end

  # ── Options helpers ─────────────────────────────────────────────────────────

  defp affordance_opts(resource, opts) do
    domain = Ash.Resource.Info.domain(resource)
    [domain: domain, domains: opts[:domains]]
  end

  defp render_opts(type, opts, extra \\ []) do
    [type: type, prefix: prefix(opts)] ++ extra
  end

  defp nav_opts(opts), do: [prefix: prefix(opts)]

  defp doc_opts(conn, opts) do
    [entrypoint: prefix(opts) <> "/", id: request_url(conn)]
  end

  defp prefix(opts), do: Keyword.get(opts, :prefix, "") || ""

  defp doc_segments(opts) do
    opts[:doc_path] |> String.split("/", trim: true)
  end

  # The path AFTER the mount prefix. Under `forward "/api", to: …` Plug consumes
  # the prefix into `script_name` and leaves `path_info` as the remainder.
  defp path_segments(conn, _opts), do: conn.path_info

  # ── Response ────────────────────────────────────────────────────────────────

  defp put_link_header(conn, opts) do
    doc_url = prefix(opts) <> opts[:doc_path]
    Plug.Conn.put_resp_header(conn, "link", "<#{doc_url}>; rel=\"#{Context.api_documentation_rel()}\"")
  end

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type(Context.content_type(), nil)
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
    |> Plug.Conn.halt()
  end

  defp request_url(conn), do: conn.request_path

  defp encodable(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: to_string(value)

  defp encodable(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encodable(%Date{} = value), do: Date.to_iso8601(value)
  defp encodable(%Time{} = value), do: Time.to_iso8601(value)
  defp encodable(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp encodable(%Decimal{} = value), do: Decimal.to_string(value)
  defp encodable(value) when is_list(value), do: Enum.map(value, &encodable/1)
  defp encodable(value), do: value
end
