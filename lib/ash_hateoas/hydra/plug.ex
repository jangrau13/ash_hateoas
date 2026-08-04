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
          base_url: "https://api.example.com",
          prefix: "/api",
          doc_path: "/doc"
      end

  ## Options

    * `:domains` (or `:domain`) — the Ash domain(s) to serve.
    * `:doc_path` — where the `ApiDocumentation` is served (default `"/doc"`).
    * `:prefix` — a mount path prepended to every route and used for matching
      (`"/api"`), for when the plug is forwarded under a sub-path.
    * `:base_url` — an absolute public origin (`"https://api.example.com"`)
      prepended to every **rendered** href (`@id`, links, navigation, the `Link`
      header) so the URLs a client receives are dereferenceable as-is rather than
      relative. It is used only for rendering — route matching is unaffected — so
      the plug still matches the plain request path whatever `base_url` says. Set
      it to the origin this service is reached at (behind a proxy, the external
      one), and cross-service links and generic clients can follow every `@id`
      without knowing the mount point out of band.

      Leaving it unset keeps the hrefs relative, which is supported: every
      document declares `@base`, so a relative `@id` still resolves to a real
      identity. Without `base_url` that base is the **request's** origin, which
      is wrong behind a proxy that rewrites the host — so set it in production
      and let the request supply it in development.

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

  require Ash.Query

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

  # `GET /` serves nothing, and falls through to the 404 below.
  #
  # It used to return a listing of every collection in the domain, and both the
  # listing and the `up` link that pointed at it are gone. **A
  # collection-of-collections is not a resource**: nothing in any domain
  # corresponds to it, and it existed only so that `up` had somewhere to point.
  #
  # Nor was it an entry point in any sense Hydra requires. A client may start at
  # *any* URL — every response carries `Link: <…/doc>; rel="apiDocumentation"`,
  # so the full description is one hop from whatever resource a client holds.
  # Sitting at the root path made a convenience look like a required first
  # fetch, and no consumer ever made it: the language derives its own root from
  # the class advertising `validate`.
  #
  # It was also the last place in this package where **data was used as JSON
  # object keys** — the collection map was keyed by type name, so the payload
  # lived in positions a `@context` cannot define. Measured before removal: 27
  # of 29 keys vanished under expansion, and the one survivor collided with a
  # Hydra term and was retyped as something unrelated. The rule that replaces
  # it: a key is a keyword or a declared term, never a value.

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
      {resource, type, action, id, scope} ->
        serve_write(conn, resource, type, action, id, actor, tenant, scoped(opts, scope))

      :error ->
        send_error(conn, 404, "Not Found")
    end
  end

  defp dispatch(conn, _segments, _actor, _tenant, _opts) do
    send_error(conn, 404, "Not Found")
  end

  # ── GET reads ─────────────────────────────────────────────────────────────

  # The owner ids a nested path carried travel in `opts` under `:scope`, rather
  # than as a positional argument threaded through every serve function. They
  # are request context — the same kind of thing as `prefix` and `base_url`
  # already in there — and every one of these functions already takes `opts`.
  defp serve_get(conn, segments, actor, opts) do
    case match(segments, opts) do
      {:member, resource, type, id, scope} ->
        serve_member(conn, resource, type, id, actor, scoped(opts, scope))

      {:collection, resource, type, action, scope} ->
        serve_collection(conn, resource, type, action, actor, scoped(opts, scope))

      {:related, resource, relationship, id, scope} ->
        serve_related(conn, resource, relationship, id, actor, scoped(opts, scope))

      :error ->
        send_error(conn, 404, "Not Found")
    end
  end

  defp scoped(opts, scope) when map_size(scope) == 0, do: opts
  defp scoped(opts, scope), do: Keyword.put(opts, :scope, scope)

  defp scope(opts), do: Keyword.get(opts, :scope, %{})

  defp serve_member(conn, resource, type, id, actor, opts) do
    tenant = Ash.PlugHelpers.get_tenant(conn)

    case load(resource, id, actor, tenant, scope(opts)) do
      nil ->
        send_error(conn, 404, "Not Found")

      record ->
        node = node(record, type, resource, id, actor, tenant, opts)
        node = maybe_project_observed(node, conn, resource)
        context = document_context(conn, opts, resource)
        send_json(conn, 200, Map.put(node, "@context", context))
    end
  end

  # `?observe=<attribute>` returns the property-level projection of a member:
  # just that attribute plus the node's identity. This is the URL a property
  # observable (`observable :name`) names as its topic, so it must resolve —
  # both for a hub that re-fetches (a thin ping) and for a client told "this
  # property changed" that wants the new value and nothing else.
  #
  # Only DECLARED observable attributes are projectable: projecting an
  # arbitrary attribute would make `?observe=` a second, ungoverned read shape.
  # An unknown or undeclared value yields the full member node, not an error —
  # the param narrows a response, it never changes what may be read.
  defp maybe_project_observed(node, conn, resource) do
    conn = Plug.Conn.fetch_query_params(conn)

    case conn.query_params["observe"] do
      nil ->
        node

      observed ->
        projectable =
          resource
          |> AshHateoas.Resource.Info.observables()
          |> Enum.map(& &1.subject)
          |> Enum.reject(&(&1 in [:resource, :collection]))

        if Enum.any?(projectable, &(to_string(&1) == observed)) do
          Map.take(node, ["@id", "@type", observed])
        else
          node
        end
    end
  rescue
    _ -> node
  end

  defp serve_collection(conn, resource, type, action, actor, opts) do
    tenant = Ash.PlugHelpers.get_tenant(conn)
    page = page_params(conn)
    arguments = read_arguments(conn, resource, action)

    case read(resource, action, arguments, actor, tenant, page, scope(opts)) do
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
          |> Renderer.render(render_opts(type, resource, opts))

        document =
          Collection.wrap(members,
            id: collection_href(resource, opts),
            total_items: total,
            operations: operations,
            view_map: view_map
          )
          # The members are nodes of this resource and carry its flat keys, so
          # the collection needs the same term bindings a member read on its own
          # would get. Without them a member expands to different triples inside
          # its collection than outside it — and `title` would land on
          # `hydra:title` here while resolving correctly one URL away.
          |> Map.put("@context", document_context(conn, opts, resource))

        send_json(conn, 200, document)

      {:error, error} ->
        # A read can fail for very different reasons — a policy denial, invalid
        # arguments, or a raised exception (e.g. a backend the action depends on
        # is down). Classify by the Ash error so the status is honest, instead of
        # reporting every failure as Forbidden.
        send_ash_error(conn, error)
    end
  end

  # One record's related collection (`/base/:id/<relationship>`) — the URL a
  # node advertises for each of its public to-many relationships.
  #
  # This is a read of the DESTINATION resource scoped to one source record, not
  # a read of the source: the members are comments, and they are rendered
  # exactly as the destination's own collection renders them, so a client
  # following a link gets the same node shape either way.
  #
  # Loading the source first is deliberate. It makes an unknown or unreadable
  # source a 404 rather than an empty collection — "this record has no
  # comments" and "this record does not exist" are different answers, and
  # authorization on the source is what decides whether its related set may be
  # seen at all.
  defp serve_related(conn, resource, relationship, id, actor, opts) do
    tenant = Ash.PlugHelpers.get_tenant(conn)

    with %{destination: destination} = definition <-
           Ash.Resource.Info.relationship(resource, relationship),
         record when not is_nil(record) <- load(resource, id, actor, tenant, scope(opts)),
         {:ok, loaded} <-
           Ash.load(record, [relationship], actor: actor, tenant: tenant, authorize?: true) do
      related = loaded |> Map.get(relationship) |> List.wrap()
      type = AshHateoas.Resource.Info.type(destination)

      members =
        Enum.map(related, fn member ->
          node(member, type, destination, record_id(member), actor, tenant, opts,
            scope: :collection
          )
        end)

      # No collection-level operations: a related collection is a view onto one
      # record's associations, and a create here would have to invent which
      # side owns the new row. The destination's own collection is where its
      # create affordance lives.
      document =
        Collection.wrap(members,
          id: related_href(resource, definition, id, opts),
          total_items: length(members)
        )
        # The DESTINATION's bindings, not the source's — the members are
        # comments. Same rule as the destination's own collection, which is what
        # makes "the same node shape either way" true of the triples and not
        # only of the JSON.
        |> Map.put("@context", document_context(conn, opts, destination))

      send_json(conn, 200, document)
    else
      {:error, error} -> send_ash_error(conn, error)
      _ -> send_error(conn, 404, "Not Found")
    end
  end

  defp related_href(resource, %{name: relationship}, id, opts) do
    case get_route(resource, &(&1.type == :related and &1.relationship == relationship)) do
      nil -> nil
      route -> href_prefix(opts) <> fill(route.route, id, opts)
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
    # The URL a create posts to already names the owner
    # (`POST /ledger/<id>/entry`), so the body need not repeat it — and must not
    # be able to contradict it. The path wins: an author writing a different
    # `ledger_id` in the body would otherwise create a record somewhere other
    # than where they posted it.
    input = conn |> read_body_params() |> Map.merge(scope(opts))

    safe(fn ->
      resource
      |> Ash.Changeset.for_create(action, input, actor: actor, tenant: tenant)
      |> Ash.create(authorize?: true)
    end)
    |> respond_write(conn, resource, type, actor, tenant, opts, created: true)
  end

  defp serve_write(conn, resource, type, action, id, actor, tenant, opts) do
    case load(resource, id, actor, tenant, scope(opts)) do
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
          |> Ash.destroy(authorize?: true, return_destroyed?: true)
        end)
        |> respond_destroy(conn, resource, type, actor, tenant, opts)

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
        |> respond_generic(conn, opts)
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
    context = document_context(conn, opts, resource)
    status = if Keyword.get(write_opts, :created, false), do: 201, else: 200
    send_json(conn, status, Map.put(node, "@context", context))
  end

  defp respond_write({:error, error}, conn, _resource, _type, _actor, _tenant, _opts, _write_opts) do
    send_ash_error(conn, error)
  end

  # A destroy returns the record it destroyed.
  #
  # The alternative — 204 with an empty body — makes a client that wants to show
  # what it deleted issue a GET first and hold the result across the delete.
  # Ash hands the record back for the asking (`return_destroyed?: true`), so the
  # information is already there; sending it costs one render.
  #
  # **The node carries no operations.** `node/7` would gate and attach the usual
  # affordances, and every one of them addresses a record that no longer exists
  # — a client following `update` on this node gets a 404, having been told it
  # was available. So the representation is the record's final state and nothing
  # more: what it *was*, not what may be done to it.
  #
  # `hydra:returns` names this class rather than `owl:Nothing`, and the two must
  # stay in step — see `Renderer.put_returns/3`.
  defp respond_destroy({:ok, record}, conn, resource, type, actor, tenant, opts) do
    id = record_id(record)
    node = node(record, type, resource, id, actor, tenant, opts)
    context = document_context(conn, opts, resource)

    send_json(
      conn,
      200,
      node
      |> Map.drop(["hydra:operation"])
      |> Map.put("@context", context)
    )
  end

  # A destroy action that yields no record — `return_destroyed?` is honoured by
  # the data layer, and a custom destroy may not carry one. Nothing to render,
  # so the empty response is still the truthful one.
  defp respond_destroy(:ok, conn, _resource, _type, _actor, _tenant, _opts),
    do: Plug.Conn.send_resp(conn, 204, "") |> Plug.Conn.halt()

  defp respond_destroy({:error, error}, conn, _resource, _type, _actor, _tenant, _opts),
    do: send_ash_error(conn, error)

  # A generic action returns whatever it returns; wrap non-resource results so a
  # client always receives a JSON-LD document.
  defp respond_generic({:ok, result}, conn, opts) do
    body =
      case result do
        %{__struct__: _} = struct when is_struct(struct) ->
          Map.new(Map.from_struct(struct), fn {k, v} -> {to_string(k), encodable(v)} end)

        other ->
          %{"@type" => "Result", "schema:result" => encodable(other)}
      end

    send_json(conn, 200, Map.put(body, "@context", document_context(conn, opts)))
  end

  defp respond_generic(:ok, conn, _opts), do: send_json(conn, 200, %{"@type" => "Result"})
  defp respond_generic({:error, error}, conn, _opts), do: send_ash_error(conn, error)

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
            render_opts(type, resource, opts,
              node_id: member_href(resource, id, opts),
              # The record's own id **and** any owner ids its path carried.
              # `Renderer.href/2` substitutes each `:name` it is given, so an
              # operation on an owned resource would otherwise advertise
              # `/ledger/:ledger_id/entry/<id>` — a pattern, not a target.
              path_params: Map.put(scope(opts), "id", id)
            )
          )

        nav = Navigation.record_links(record, opts[:domains], nav_opts(opts))

        base
        |> Map.merge(operations)
        |> merge_navigation(nav, opts)
        |> merge_relationship_links(resource, id, opts)
    end
  end

  # A public to-many relationship derives a `:related` route
  # (`/base/:id/<name>`); surface it on the node as a followable link to that
  # related collection, keyed by the relationship name. The property is declared
  # a `hydra:Link` in the ApiDocumentation, so a client knows the key is a link.
  defp merge_relationship_links(node, resource, id, opts) do
    resource
    |> AshHateoas.Resource.Info.routes()
    |> Enum.filter(&(&1.type == :related))
    |> Enum.reduce(node, fn route, acc ->
      url = href_prefix(opts) <> fill(route.route, id, opts)
      Map.put(acc, to_string(route.relationship), %{"@id" => url, "@type" => "Collection"})
    end)
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

  # A navigation link maps onto a Hydra link term as a typed node reference
  # (`{"@id", "@type"}`), so a strict client recognises the target's kind
  # without decoding a private `rel` token.
  #
  # `collection` is the only one. There used to be `up`, rendered as
  # `hydra:view` and pointing at `/` — a record's "owning
  # collection-of-collections", which is not a resource. A record's honest
  # parent is its collection, and that is what `hydra:collection` already says.
  #
  # Note `hydra:view` itself remains in use, for what it is actually for:
  # `Collection.wrap/2` emits a `hydra:PartialCollectionView` under it when a
  # collection is paged.
  defp merge_navigation(node, nav, opts) do
    Enum.reduce(nav, node, fn
      # `Navigation` is transport-neutral and knows nothing of a request, so an
      # owned resource's collection URL arrives still holding its owner's
      # placeholder. Filled here, where the scope from the request is in hand.
      {"collection", link}, acc ->
        Map.put(acc, "hydra:collection", nav_ref(%{link | url: fill(link.url, nil, opts)}))

      _other, acc ->
        acc
    end)
  end

  # A transport-neutral `%{url:, kind:}` navigation link → a Hydra node reference.
  # The `@type` value is a bare class token (`Collection`/`Resource`) the emitted
  # `@context` resolves to the Hydra core vocabulary.
  defp nav_ref(%{url: url, kind: kind}) do
    %{"@id" => url, "@type" => nav_type(kind)}
  end

  defp nav_type(:collection), do: "Collection"
  defp nav_type(:resource), do: "Resource"

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
    # A named collection index (`/base/search`) is a LITERAL path; the primary
    # member route (`/base/:id`) is a WILDCARD that would otherwise capture
    # `search` as an id and shadow it. Literal beats wildcard, so every `:index`
    # is tried before the `:get`/:id member route regardless of derivation order.
    |> Enum.sort_by(&route_match_rank/1)
    |> Enum.find_value(fn %Route{} = route ->
      match_route(route, resource, type, path, prefix)
    end)
  end

  # Lower rank is tried first. Index (literal) before related (one more literal
  # segment than the member route) before member (wildcard); anything else does
  # not participate in GET read matching.
  defp route_match_rank(%Route{type: :index}), do: 0
  defp route_match_rank(%Route{type: :related}), do: 1
  defp route_match_rank(%Route{type: :get, primary?: true}), do: 2
  defp route_match_rank(_route), do: 3

  # A named index (`/base/<action>`) carries its own action so the collection
  # read runs THAT action, not the primary read.
  defp match_route(
         %Route{type: :index, route: route, action: action},
         resource,
         type,
         path,
         prefix
       ) do
    # An owned resource's collection carries its owner's id
    # (`/ledger/:ledger_id/entry`), so this is a pattern match rather than a
    # string comparison — and the captured owner scopes the read.
    case capture_params(prefix <> route, path) do
      nil -> nil
      params -> {:collection, resource, type, action, scope_params(params)}
    end
  end

  defp match_route(%Route{type: :get, primary?: true, route: route}, resource, type, path, prefix) do
    case capture_params(prefix <> route, path) do
      nil -> nil
      params -> {:member, resource, type, own_id(params), scope_params(params)}
    end
  end

  # `/base/:id/<relationship>` — the URL the node advertises for a public
  # to-many relationship. Matching it here is what makes that link followable;
  # without this clause the node emits a URL the router 404s, which is a broken
  # contract for any client that follows links rather than constructing them.
  #
  # The match carries the SOURCE resource and the relationship, not the
  # destination: the destination's own collection route already exists and
  # returns every row, whereas this one is scoped to one record's related set.
  defp match_route(
         %Route{type: :related, route: route, relationship: relationship},
         resource,
         _type,
         path,
         prefix
       ) do
    case capture_params(prefix <> route, path) do
      nil -> nil
      params -> {:related, resource, relationship, own_id(params), scope_params(params)}
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
        {action, id, scope} -> {resource, type, action, id, scope}
      end
    end)
  end

  defp match_write_route(method, %Route{} = route, _type, path, prefix) do
    if route_method(route) == method do
      full = prefix <> (route.route || "")

      # A create posts to the collection base, which under an owner still
      # carries that owner's id — so both cases are a pattern match, and the
      # presence of `:id` in the *pattern* decides which it is.
      case capture_params(full, path) do
        nil -> nil
        params -> {route.action, own_id(params), scope_params(params)}
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
  # Every `:name` segment a path fills in, as `%{"name" => value}` — or `nil`
  # when the path does not match the pattern at all.
  #
  # This used to return one id, folding over the segments and keeping the last
  # `:id` it saw. A nested route has two — `/ledger/:ledger_id/entry/:id` — and
  # under the old shape the owner's id was silently discarded, so an entry
  # resolved regardless of which ledger was named. A map keeps both, and
  # keeps them distinguishable: the record's own is `:id`, and an owner's is
  # named after the relationship (`:ledger_id`), which is why
  # `DeriveActionRoutes.owner_prefix/2` does not spell it `:id` too.
  defp capture_params(pattern, path) do
    pattern_segs = String.split(pattern, "/", trim: true)
    path_segs = String.split(path, "/", trim: true)

    if length(pattern_segs) == length(path_segs) do
      pattern_segs
      |> Enum.zip(path_segs)
      |> Enum.reduce_while(%{}, fn
        {":" <> name, value}, acc -> {:cont, Map.put(acc, name, value)}
        {same, same}, acc -> {:cont, acc}
        {_a, _b}, _acc -> {:halt, :no_match}
      end)
      |> case do
        :no_match -> nil
        params -> params
      end
    end
  end

  # The record's own id from a captured set. A pattern with no `:id` — a
  # collection under an owner — has none, which is not a failure.
  defp own_id(params), do: params["id"]

  # Everything except the record's own id: the owner ids a nested path carries.
  # These become filters, so a record under the wrong owner is not found rather
  # than being found and mis-attributed.
  defp scope_params(params), do: Map.delete(params, "id")

  # ── Ash calls ───────────────────────────────────────────────────────────────

  defp load(resource, id, actor, tenant, scope) do
    case Ash.get(resource, id, actor: actor, tenant: tenant, authorize?: true) do
      {:ok, record} -> if in_scope?(record, scope), do: record, else: nil
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # A nested URL's owner id is a **constraint**, not decoration: an entry that
  # exists but belongs to a different ledger must not resolve under that
  # ledger's path. Without this the id in the path would be ignored, so
  # `/ledger/A/entry/<entry-of-B>` would happily return B's entry — the record
  # found, and silently mis-attributed to the wrong parent.
  #
  # Checked after the read rather than as a filter, so authorization decides
  # first and a mismatch is indistinguishable from a missing record: both are
  # 404, and neither confirms the record exists elsewhere.
  defp in_scope?(_record, scope) when map_size(scope) == 0, do: true

  defp in_scope?(record, scope) do
    Enum.all?(scope, fn {key, value} ->
      case Map.fetch(record, String.to_existing_atom(key)) do
        {:ok, actual} -> to_string(actual) == value
        :error -> true
      end
    end)
  rescue
    # An unknown key names no attribute, so there is nothing to contradict.
    ArgumentError -> true
  end

  # Run the matched read action (the primary read for the base index, or a named
  # collection read like `semantic_search` for `/base/<name>`), with any query
  # params bound to its public arguments.
  # Narrow a collection read to the owner ids its URL carried. Each key names an
  # attribute on the resource — `ledger_id` for `owned_by :ledger` — and a key
  # matching no attribute is skipped rather than raising, so an unexpected path
  # segment cannot turn a read into a 500.
  defp scope_query(query, _resource, scope) when map_size(scope) == 0, do: query

  defp scope_query(query, resource, scope) do
    Enum.reduce(scope, query, fn {key, value}, acc ->
      field = String.to_existing_atom(key)

      if Ash.Resource.Info.attribute(resource, field) do
        # A keyword filter rather than an `expr`: the field name is known only
        # at runtime, and `filter/2` is a macro that wants it at compile time.
        Ash.Query.filter_input(acc, [{field, value}])
      else
        acc
      end
    end)
  rescue
    ArgumentError -> query
  end

  defp read(resource, action, arguments, actor, tenant, page, scope) do
    read_opts = [actor: actor, tenant: tenant, authorize?: true]

    # Paginate only when page params were supplied AND this action declares
    # pagination support — passing `page:` to an unpaginated action raises.
    read_opts =
      if page != [] and paginatable?(resource, action) do
        Keyword.put(read_opts, :page, page)
      else
        read_opts
      end

    # A nested collection lists **that owner's** records, not every record of
    # the type. Without this filter `/ledger/A/entry` returns B's entries too —
    # a URL that names a scope and then ignores it.
    query =
      resource
      |> Ash.Query.for_read(action, arguments, actor: actor, tenant: tenant)
      |> scope_query(resource, scope)

    # The real Ash error is returned, not flattened to a bare `:error`, so the
    # caller can classify it (a policy denial is a 403, invalid input a 400/422,
    # anything else a 500) rather than mislabel every failure as Forbidden.
    Ash.read(query, read_opts)
  rescue
    exception -> {:error, exception}
  end

  # Bind a named read's public arguments from the query string
  # (`?query=solar&limit=5`). Only declared, public arguments are taken — an
  # unknown param is ignored, and nothing is passed for the primary read (which
  # has no arguments), so its behaviour is unchanged.
  defp read_arguments(conn, resource, action_name) do
    conn = Plug.Conn.fetch_query_params(conn)
    params = conn.query_params

    case Ash.Resource.Info.action(resource, action_name) do
      %{arguments: arguments} when is_list(arguments) ->
        for %{name: name, public?: true} <- arguments,
            value = params[to_string(name)],
            not is_nil(value),
            into: %{},
            do: {name, value}

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  defp paginatable?(resource, action_name) do
    case Ash.Resource.Info.action(resource, action_name) do
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
    case Navigation.collection_href(resource, opts[:domains], nav_opts(opts)) do
      nil ->
        nil

      # An owned resource's collection sits under its owner
      # (`/ledger/:ledger_id/entry`), so the owner's id has to be filled in here
      # too — a record's `hydra:collection` link is otherwise a pattern rather
      # than a URL. There is no record id in a collection path, so `fill/3` is
      # given none.
      href ->
        fill(href, nil, opts)
    end
  end

  defp member_href(resource, id, opts) do
    case get_route(resource, &(&1.type == :get and &1.primary?)) do
      nil -> nil
      route -> href_prefix(opts) <> fill(route.route, id, opts)
    end
  end

  # A route pattern with every placeholder filled: the record's own `:id`, and
  # any owner id a nested route carries.
  #
  # Substituting `:id` alone was enough while every route was flat. Under an
  # owner it leaves the parent's placeholder in the URL — a node advertising
  # `@id: "/ledger/:ledger_id/entry/<id>"`, which is not an address at all. The
  # owner ids come from `scope(opts)`, captured from the request that reached
  # this record, so they are the very ids the client used to get here.
  defp fill(pattern, id, opts) do
    # A collection path has no `:id` to fill, and is given none — substituting
    # `nil` would put an empty segment in the URL.
    filled = if is_nil(id), do: pattern, else: String.replace(pattern, ":id", to_string(id))

    Enum.reduce(scope(opts), filled, fn {key, value}, acc ->
      String.replace(acc, ":#{key}", to_string(value))
    end)
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

  defp render_opts(type, resource, opts, extra \\ []) do
    [
      type: type,
      prefix: href_prefix(opts),
      semantic_actions: AshHateoas.Resource.Info.semantic_actions(resource)
    ] ++ extra
  end

  defp nav_opts(opts), do: [prefix: href_prefix(opts)]

  defp doc_opts(conn, opts) do
    [entrypoint: href_prefix(opts) <> "/", id: href_prefix(opts) <> request_url(conn)]
  end

  defp prefix(opts), do: Keyword.get(opts, :prefix, "") || ""

  # The absolute base for a public URL, if configured. Emitted hrefs (`@id`,
  # links, navigation, the `Link` header) are prefixed with it so every URL a
  # client receives is dereferenceable as-is — a relative `/people/1` cannot be
  # followed by a consumer that only has the document, and cannot be rendered as
  # a clickable link. Trailing slash trimmed so it composes cleanly with the
  # leading-slash routes.
  #
  # It is used ONLY for rendering. Route matching keeps using `prefix/1` against
  # `conn.path_info`, so setting `base_url` never affects which requests match.
  defp base_url(opts) do
    case Keyword.get(opts, :base_url) do
      nil -> ""
      "" -> ""
      url -> String.trim_trailing(url, "/")
    end
  end

  # The full prefix for a rendered href: the public base plus any mount prefix.
  defp href_prefix(opts), do: base_url(opts) <> prefix(opts)

  # What a relative `@id` resolves against, declared as `@base` on every emitted
  # document.
  #
  # With `base_url` configured the hrefs are already absolute and `@base` is
  # inert — it applies only to relative IRIs. Without it they are relative, and a
  # JSON-LD processor resolves them against the document's location; for a
  # document parsed from a string that is the last remote context loaded, so
  # `/articles/1` became `http://www.w3.org/articles/1`. The request states the
  # true origin, so it is used when nothing else says otherwise.
  defp document_base(conn, opts) do
    case base_url(opts) do
      "" -> request_origin(conn)
      url -> url
    end
  end

  defp request_origin(%Plug.Conn{} = conn) do
    case conn.host do
      nil -> nil
      "" -> nil
      host -> "#{conn.scheme}://#{host}#{origin_port(conn)}"
    end
  end

  defp origin_port(%{scheme: :http, port: 80}), do: ""
  defp origin_port(%{scheme: :https, port: 443}), do: ""
  defp origin_port(%{port: port}) when is_integer(port), do: ":#{port}"
  defp origin_port(_conn), do: ""

  # A document's `@context`, with the base every relative `@id` in it resolves
  # against. Every send site goes through here so none can drift — an `@id` is
  # only as good as the base it resolves under.
  defp document_context(conn, opts), do: Context.put_base(Context.context(), document_base(conn, opts))

  defp document_context(conn, opts, resource),
    do: Context.put_base(Context.context_for(resource), document_base(conn, opts))

  defp doc_segments(opts) do
    opts[:doc_path] |> String.split("/", trim: true)
  end

  # The path AFTER the mount prefix. Under `forward "/api", to: …` Plug consumes
  # the prefix into `script_name` and leaves `path_info` as the remainder.
  defp path_segments(conn, _opts), do: conn.path_info

  # ── Response ────────────────────────────────────────────────────────────────

  defp put_link_header(conn, opts) do
    doc_url = href_prefix(opts) <> opts[:doc_path]

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
      # A framework-class failure or a raw raised exception is the server's
      # problem, not the caller's — a 500, not a 4xx. (A plain exception struct
      # has no Ash `class`, so `class_of` returns `:unknown`.)
      class_of(error) in [:framework, :unknown] -> {500, "Internal Server Error"}
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
