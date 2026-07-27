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
  | `POST`/`PATCH`/`DELETE`/generic | runs the action and renders the new state, `204`, or a `hydra:Error` |

  Every response carries `Content-Type: application/ld+json` and a `Link` header
  advertising the API documentation, so a generic client discovers the whole API
  from any single response (see the Hydra client flow).
  """

  @behaviour Plug

  require Logger

  alias AshHateoas.Hydra.{ApiDocumentation, Collection, Context, Renderer}
  alias AshHateoas.Hydra.Error, as: HydraError
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

      send_error(conn, 500, "Internal Server Error")
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

  defp dispatch(%{method: method} = conn, segments, actor, tenant, opts)
       when method in ["POST", "PATCH", "DELETE"] do
    case match_write(method, segments, opts) do
      {resource, type, action, id} ->
        serve_write(conn, resource, type, action, id, actor, tenant, opts)

      :error ->
        send_error(conn, 404, "Not Found")
    end
  end

  defp dispatch(conn, _segments, _actor, _tenant, _opts) do
    send_error(conn, 404, "Not Found")
  end

  # ── GET reads ─────────────────────────────────────────────────────────────

  defp serve_get(conn, segments, actor, opts) do
    case match(segments, opts) do
      {:member, resource, type, id} ->
        serve_member(conn, resource, type, id, actor, opts)

      {:collection, resource, type} ->
        serve_collection(conn, resource, type, actor, opts)

      :error ->
        send_error(conn, 404, "Not Found")
    end
  end

  defp serve_member(conn, resource, type, id, actor, opts) do
    tenant = Ash.PlugHelpers.get_tenant(conn)

    case load(resource, id, actor, tenant) do
      nil ->
        send_error(conn, 404, "Not Found")

      record ->
        node = node(record, type, resource, id, actor, tenant, opts)
        context = Context.context_for(AshHateoas.Resource.Info.semantic_properties(resource))
        send_json(conn, 200, Map.put(node, "@context", context))
    end
  end

  defp serve_collection(conn, resource, type, actor, opts) do
    tenant = Ash.PlugHelpers.get_tenant(conn)
    page = page_params(conn)

    case read(resource, actor, tenant, page) do
      {:ok, result} ->
        {records, total, view_map} = paginate(result, resource, type, conn, opts)

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
            total_items: total,
            operations: operations,
            view_map: view_map
          )
          |> Map.put("@context", Context.context())

        send_json(conn, 200, document)

      :error ->
        send_error(conn, 403, "Forbidden")
    end
  end

  # `?limit=&offset=` (or the bracketed `?page[limit]=&page[offset]=`) are
  # parsed into Ash offset-pagination options, applied only when the read action
  # supports pagination — otherwise the params are ignored and a full read runs.
  defp page_params(conn) do
    conn = Plug.Conn.fetch_query_params(conn)
    params = conn.query_params

    limit = params["limit"] || get_in(params, ["page", "limit"])
    offset = params["offset"] || get_in(params, ["page", "offset"])

    if is_nil(limit) and is_nil(offset) do
      []
    else
      # `count: true` asks Ash for the total so `hydra:totalItems` and the
      # first/last/next view links can be computed.
      [count: true]
      |> put_int(:limit, limit)
      |> put_int(:offset, offset)
    end
  end

  defp put_int(opts, _key, nil), do: opts

  defp put_int(opts, key, value) do
    case Integer.parse(to_string(value)) do
      {int, _} -> Keyword.put(opts, key, int)
      _ -> opts
    end
  end

  # An offset page carries results + count; a plain list has neither. Build the
  # PartialCollectionView links only for a real page.
  defp paginate(%Ash.Page.Offset{} = page, resource, _type, conn, opts) do
    total = page.count || length(page.results)
    limit = page.limit
    offset = page.offset || 0

    view =
      Collection.view(
        id: page_href(resource, opts, conn, limit, offset),
        first: page_href(resource, opts, conn, limit, 0),
        previous: prev_href(resource, opts, conn, limit, offset),
        next: next_href(resource, opts, conn, limit, offset, total),
        last: last_href(resource, opts, conn, limit, total)
      )

    {page.results, total, view}
  end

  defp paginate(records, _resource, _type, _conn, _opts) when is_list(records) do
    {records, length(records), nil}
  end

  defp page_href(resource, opts, _conn, limit, offset) do
    base = collection_href(resource, opts)
    "#{base}?limit=#{limit}&offset=#{max(offset, 0)}"
  end

  defp prev_href(_resource, _opts, _conn, _limit, offset) when offset <= 0, do: nil

  defp prev_href(resource, opts, conn, limit, offset),
    do: page_href(resource, opts, conn, limit, offset - (limit || 0))

  defp next_href(_resource, _opts, _conn, nil, _offset, _total), do: nil

  defp next_href(resource, opts, conn, limit, offset, total) do
    if offset + limit < total,
      do: page_href(resource, opts, conn, limit, offset + limit),
      else: nil
  end

  defp last_href(_resource, _opts, _conn, nil, _total), do: nil

  defp last_href(resource, opts, conn, limit, total) do
    last_offset = max(div(total - 1, limit) * limit, 0)
    page_href(resource, opts, conn, limit, last_offset)
  end

  # ── Writes ──────────────────────────────────────────────────────────────────

  # A create has no id; an update/destroy/generic acts on an existing record.
  defp serve_write(conn, resource, type, action, nil, actor, tenant, opts) do
    input = read_body_params(conn)

    safe(fn ->
      resource
      |> Ash.Changeset.for_create(action, input, actor: actor, tenant: tenant)
      |> Ash.create(authorize?: true)
    end)
    |> respond_write(conn, resource, type, actor, tenant, opts, created: true)
  end

  defp serve_write(conn, resource, type, action, id, actor, tenant, opts) do
    case load(resource, id, actor, tenant) do
      nil ->
        send_error(conn, 404, "Not Found")

      record ->
        # Pre-flight the same `Ash.can?/3` the affordance layer gates on. Ash's
        # atomic update path erases the forbidden class into an opaque
        # `UnknownError`, so a post-hoc class check cannot see it; asking up front
        # gives an honest 403 and avoids running a write the actor may not do.
        if can?(record, action, actor, tenant) do
          run_write(conn, record, resource, type, action, actor, tenant, opts)
        else
          send_error(conn, 403, "Forbidden")
        end
    end
  end

  defp can?(record, action, actor, tenant) do
    Ash.can?({record, action}, actor, tenant: tenant)
  rescue
    _ -> false
  end

  defp run_write(conn, record, resource, type, action, actor, tenant, opts) do
    input = read_body_params(conn)
    action_struct = Ash.Resource.Info.action(resource, action)

    case action_struct.type do
      :destroy ->
        safe(fn ->
          record
          |> Ash.Changeset.for_destroy(action, input, actor: actor, tenant: tenant)
          |> Ash.destroy(authorize?: true)
        end)
        |> respond_destroy(conn)

      :update ->
        safe(fn ->
          record
          |> Ash.Changeset.for_update(action, input, actor: actor, tenant: tenant)
          |> Ash.update(authorize?: true)
        end)
        |> respond_write(conn, resource, type, actor, tenant, opts, [])

      :action ->
        safe(fn ->
          resource
          |> Ash.ActionInput.for_action(action, Map.put(input, :id, record_id(record)),
            actor: actor,
            tenant: tenant
          )
          |> Ash.run_action(authorize?: true)
        end)
        |> respond_generic(conn)
    end
  end

  # An Ash write can either return `{:error, _}` or raise (an atomic update
  # raises its policy error). Normalise both to a tagged tuple so response
  # mapping is uniform. `:ok`/`{:ok, _}` pass through unchanged.
  defp safe(fun) do
    fun.()
  rescue
    error -> {:error, error}
  end

  # Renders the resulting record as a fresh node (a write returns the new state).
  defp respond_write({:ok, record}, conn, resource, type, actor, tenant, opts, write_opts) do
    id = record_id(record)
    node = node(record, type, resource, id, actor, tenant, opts)
    context = Context.context_for(AshHateoas.Resource.Info.semantic_properties(resource))
    status = if Keyword.get(write_opts, :created, false), do: 201, else: 200
    send_json(conn, status, Map.put(node, "@context", context))
  end

  defp respond_write({:error, error}, conn, _resource, _type, _actor, _tenant, _opts, _write_opts) do
    send_ash_error(conn, error)
  end

  defp respond_destroy(:ok, conn), do: Plug.Conn.send_resp(conn, 204, "") |> Plug.Conn.halt()
  defp respond_destroy({:ok, _record}, conn), do: respond_destroy(:ok, conn)
  defp respond_destroy({:error, error}, conn), do: send_ash_error(conn, error)

  # A generic action returns whatever it returns; wrap non-resource results so a
  # client always receives a JSON-LD document.
  defp respond_generic({:ok, result}, conn) do
    body =
      case result do
        %{__struct__: _} = struct when is_struct(struct) ->
          Map.new(Map.from_struct(struct), fn {k, v} -> {to_string(k), encodable(v)} end)

        other ->
          %{"@type" => "Result", "ah:value" => encodable(other)}
      end

    send_json(conn, 200, Map.put(body, "@context", Context.context()))
  end

  defp respond_generic(:ok, conn), do: send_json(conn, 200, %{"@type" => "Result"})
  defp respond_generic({:error, error}, conn), do: send_ash_error(conn, error)

  # ── Node building ─────────────────────────────────────────────────────────

  # A resource node: its attributes flattened onto the node, its identity, and
  # (for a member) its gated operations + structural navigation.
  defp node(record, type, resource, id, actor, tenant, opts, node_opts \\ []) do
    base =
      record
      |> attributes(resource, opts)
      |> Map.merge(%{
        "@id" => member_href(resource, id, opts),
        "@type" => Context.node_type(type, AshHateoas.Resource.Info.semantic_type(resource))
      })

    case Keyword.get(node_opts, :scope, :member) do
      :collection ->
        base

      :member ->
        operations =
          record
          |> AshHateoas.affordances(actor, affordance_opts(resource, opts) ++ [tenant: tenant])
          |> Renderer.render(
            render_opts(type, opts,
              node_id: member_href(resource, id, opts),
              path_params: %{"id" => id}
            )
          )

        nav = Navigation.record_links(record, opts[:domains], nav_opts(opts))

        base
        |> Map.merge(operations)
        |> merge_navigation(nav)
    end
  end

  defp attributes(record, resource, opts) do
    resource
    |> Ash.Resource.Info.public_attributes()
    |> Map.new(fn attribute ->
      value = Map.get(record, attribute.name)
      {to_string(attribute.name), attribute_value(attribute, value, opts)}
    end)
  end

  # A followable link (`AshHateoas.Type.ResourceLink`) is rendered as a JSON-LD
  # reference node — `{"@id" => url}` — rather than a bare string, which is what
  # marks the value followable (a node reference, not a literal).
  #
  # Internal vs external is NOT a separate flag: the `@id`'s host already carries
  # it. A URL sharing this request's origin (or a relative one) is internal; a
  # foreign host is external. Both server and client infer it from the IRI — the
  # trust boundary is the origin, which the `@id` states.
  defp attribute_value(%{type: type}, value, _opts) when is_binary(value) do
    if link_type?(type) do
      %{"@id" => value}
    else
      value
    end
  end

  defp attribute_value(_attribute, value, _opts), do: encodable(value)

  defp link_type?(type) do
    Ash.Type.get_type(type) == AshHateoas.Type.ResourceLink
  rescue
    _ -> false
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
    |> Enum.find_value(fn %Route{} = route ->
      match_route(route, resource, type, path, prefix)
    end)
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

  # Match a write request against the routes whose HTTP method matches, returning
  # `{resource, type, action, id}` (id nil for a create). A `:route` (generic)
  # carries its own method; the verb kinds imply theirs.
  defp match_write(method, segments, opts) do
    path = "/" <> Enum.join(segments, "/")
    prefix = prefix(opts)

    opts[:domains]
    |> Index.build()
    |> Enum.find_value(:error, fn {type, resource} ->
      resource
      |> AshHateoas.Resource.Info.routes()
      |> Enum.find_value(fn %Route{} = route ->
        match_write_route(method, route, type, path, prefix)
      end)
      |> case do
        nil -> nil
        {action, id} -> {resource, type, action, id}
      end
    end)
  end

  defp match_write_route(method, %Route{} = route, _type, path, prefix) do
    if route_method(route) == method do
      full = prefix <> (route.route || "")

      cond do
        # A create/collection POST — the path is the collection base, no :id.
        not String.contains?(full, ":id") and full == path ->
          {route.action, nil}

        String.contains?(full, ":id") ->
          case capture_id(full, path) do
            nil -> nil
            id -> {route.action, id}
          end

        true ->
          nil
      end
    end
  end

  defp route_method(%Route{type: :post}), do: "POST"
  defp route_method(%Route{type: :patch}), do: "PATCH"
  defp route_method(%Route{type: :delete}), do: "DELETE"

  defp route_method(%Route{type: :route, method: method}),
    do: method |> to_string() |> String.upcase()

  defp route_method(_route), do: nil

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

  defp read(resource, actor, tenant, page) do
    read_opts = [actor: actor, tenant: tenant, authorize?: true]

    # Paginate only when page params were supplied AND the primary read declares
    # pagination support — passing `page:` to an unpaginated action raises.
    read_opts =
      if page != [] and paginatable?(resource) do
        Keyword.put(read_opts, :page, page)
      else
        read_opts
      end

    case Ash.read(resource, read_opts) do
      {:ok, result} -> {:ok, result}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp paginatable?(resource) do
    case Ash.Resource.Info.primary_action(resource, :read) do
      %{pagination: pagination} when not is_nil(pagination) and pagination != false -> true
      _ -> false
    end
  rescue
    _ -> false
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

    Plug.Conn.put_resp_header(
      conn,
      "link",
      "<#{doc_url}>; rel=\"#{Context.api_documentation_rel()}\""
    )
  end

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type(Context.content_type(), nil)
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
    |> Plug.Conn.halt()
  end

  defp send_error(conn, status, title) do
    send_json(conn, status, HydraError.render(status: status, title: title))
  end

  # The R10 refusal carries a projection; any other Ash error maps to its class's
  # HTTP status with a machine-readable Hydra Error body.
  defp send_ash_error(conn, %AshHateoas.Error.NotDelegable{} = error) do
    send_json(conn, 403, HydraError.not_delegable(error))
  end

  defp send_ash_error(conn, error) do
    {status, title} = error_status(error)

    send_json(
      conn,
      status,
      HydraError.render(status: status, title: title, detail: error_detail(error))
    )
  end

  defp error_status(error) do
    cond do
      # An atomic update wraps its authorization failure in `Ash.Error.Unknown`
      # with `class: :unknown`, so the top-level class is not enough — look for a
      # forbidden anywhere in the error tree.
      forbidden?(error) -> {403, "Forbidden"}
      class_of(error) == :invalid -> {400, "Bad Request"}
      true -> {422, "Unprocessable Entity"}
    end
  end

  defp class_of(%{class: class}), do: class
  defp class_of(_error), do: :unknown

  defp forbidden?(error) do
    class_of(error) == :forbidden or
      match?(%Ash.Error.Forbidden{}, error) or
      Enum.any?(nested_errors(error), &forbidden?/1)
  end

  defp nested_errors(%{errors: errors}) when is_list(errors), do: errors
  defp nested_errors(_error), do: []

  defp error_detail(error) do
    Exception.message(error)
  rescue
    _ -> nil
  end

  # The request body decoded into an action-input map. Reads the raw body since
  # the endpoint carries no `Plug.Parsers` — a Hydra client sends JSON-LD.
  defp read_body_params(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, _conn} when byte_size(body) > 0 ->
        case Jason.decode(body) do
          {:ok, map} when is_map(map) -> strip_ld_keywords(map)
          _ -> %{}
        end

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  # JSON-LD keywords (`@context`, `@id`, `@type`) are not action inputs.
  defp strip_ld_keywords(map) do
    map
    |> Enum.reject(fn {key, _value} -> is_binary(key) and String.starts_with?(key, "@") end)
    |> Map.new()
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
