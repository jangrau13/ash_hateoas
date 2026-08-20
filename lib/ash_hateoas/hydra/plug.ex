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
  | `GET /` | `303 See Other` to `<doc_path>` — the entry point holds no representation of its own |
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

  alias AshHateoas.Hydra.{ApiDocumentation, Collection, Context, LinkInput, Renderer}
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

  # `GET /` holds no representation of its own, and answers `303 See Other`
  # pointing at the documentation.
  #
  # **A collection-of-collections is not a resource**: nothing in any domain
  # corresponds to it, so there is nothing for the root path to represent, and
  # a listing here would have to key its entries by type name — putting data in
  # JSON object key positions, which a `@context` cannot define, so a JSON-LD
  # processor drops such keys silently. The rule throughout this package is
  # that a key is a keyword or a declared term, never a value.
  #
  # None of which makes 404 the right answer, because this package does not
  # stay silent about the root: `ApiDocumentation` carries `hydra:entrypoint`,
  # whose range is `hydra:Resource`, so every document published here asserts
  # that the root IS a resource. Answering 404 there contradicts a triple this
  # server itself emitted, and a client following `hydra:entrypoint` — the one
  # thing that property is for — reaches a dead end.
  #
  # 303 rather than a body: the description already exists, at `doc_path`, and
  # serving its bytes from a second URL would give one resource two addresses
  # while its `@id` names only the first. "The answer is elsewhere, go there"
  # is exactly what 303 means.
  #
  # This is a convenience and not a protocol requirement. Hydra needs no entry
  # point — every response carries `Link: <…/doc>; rel="apiDocumentation"`, so
  # a client may start at *any* URL and reach the description in one hop.

  defp dispatch(%{method: "GET"} = conn, segments, actor, _tenant, opts) do
    cond do
      segments == doc_segments(opts) ->
        send_json(conn, 200, ApiDocumentation.build(opts[:domains], doc_opts(conn, opts)), opts)

      segments == [] ->
        send_json(conn, 200, entry_point(conn, actor, opts), opts)

      true ->
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

  # A path carries one id: the record's own. It used to carry the owner's too,
  # under `opts[:scope]`, and every serve function narrowed its read by it — so
  # the same record under a different owner segment was a 404 rather than the
  # same record. A record is now identified by its IRI alone, which is what a
  # triple needs and what `LinkInput` already assumed on the write side.
  defp serve_get(conn, segments, actor, opts) do
    case match(segments, opts) do
      {:member, resource, type, id} ->
        serve_member(conn, resource, type, id, actor, opts)

      {:collection, resource, type, action} ->
        serve_collection(conn, resource, type, action, actor, opts)

      {:related, resource, relationship, id} ->
        serve_related(conn, resource, relationship, id, actor, opts)

      :error ->
        send_error(conn, 404, "Not Found")
    end
  end

  defp serve_member(conn, resource, type, id, actor, opts) do
    tenant = Ash.PlugHelpers.get_tenant(conn)
    opts = Keyword.put(opts, :load, load_params(conn, resource))

    case load(resource, id, actor, tenant, opts[:load]) do
      nil ->
        send_error(conn, 404, "Not Found")

      record ->
        node = node(record, type, resource, id, actor, tenant, opts)
        node = maybe_project_observed(node, conn, resource)
        context = document_context(conn, opts, resource)
        send_json(conn, 200, Map.put(node, "@context", context), opts)
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
    opts = Keyword.put(opts, :load, load_params(conn, resource))

    case read(resource, action, arguments, actor, tenant, page, opts[:load]) do
      {:ok, result} ->
        {records, total, view_map} = paginate(result, resource, type, conn, opts)

        members =
          Enum.map(records, fn record ->
            id = record_id(record)
            node(record, type, resource, id, actor, tenant, opts, scope: :linked)
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

        send_json(conn, 200, document, opts)

      {:error, error} ->
        # A read can fail for very different reasons — a policy denial, invalid
        # arguments, or a raised exception (e.g. a backend the action depends on
        # is down). Classify by the Ash error so the status is honest, instead of
        # reporting every failure as Forbidden.
        send_ash_error(conn, error)
    end
  end

  # One record's related collection (`/base/:id/<relationship>`) — the URL its
  # inline collection carries as an `@id`, and the one `hydra:view` pages
  # against.
  #
  # This is a read of the DESTINATION resource narrowed to one source record,
  # not a read of the source: the members are comments, rendered exactly as the
  # destination's own collection renders them, so a client following a link gets
  # the same node shape either way.
  #
  # It addresses a **collection**, which is why it survives while member nesting
  # did not. `/articles/7/comments` names this article's comments — a real
  # resource with no address otherwise. `/articles/7/comments/3` would name one
  # comment through its article, which is a second address for a record that
  # already has one.
  #
  # Loading the source first is deliberate. It makes an unknown or unreadable
  # source a 404 rather than an empty collection — "this record has no comments"
  # and "this record does not exist" are different answers, and authorization on
  # the source is what decides whether its related set may be seen at all.
  defp serve_related(conn, resource, relationship, id, actor, opts) do
    tenant = Ash.PlugHelpers.get_tenant(conn)

    with %{destination: destination} = definition <-
           Ash.Resource.Info.relationship(resource, relationship),
         record when not is_nil(record) <- load(resource, id, actor, tenant, []),
         {:ok, loaded} <-
           Ash.load(record, [relationship], actor: actor, tenant: tenant, authorize?: true) do
      all = loaded |> Map.get(relationship) |> List.wrap()
      type = AshHateoas.Resource.Info.type(destination)

      # `?limit=&offset=` applied here rather than in the query, because a
      # relationship is loaded through its source and Ash pages a *read*, not a
      # `load`. The whole set is read either way; what this bounds is the
      # response. That is enough for the link `hydra:view` advertises to mean
      # something — a `next` that returned the same page would be worse than no
      # `next` at all — and the cost is bounded by one record's related set.
      {offset, limit} = related_window(conn)
      related = all |> Enum.drop(offset) |> then(&if limit, do: Enum.take(&1, limit), else: &1)

      members =
        Enum.map(related, fn member ->
          node(member, type, destination, record_id(member), actor, tenant, opts, scope: :linked)
        end)

      # No collection-level operations: a related collection is a view onto one
      # record's associations, and a create here would have to invent which side
      # owns the new row. The destination's own collection is where its create
      # affordance lives.
      document =
        Collection.wrap(members,
          id: related_href(resource, definition, id, opts),
          # The **whole** set, not this page — that is what `totalItems` means,
          # and it is what tells a client how much a page is leaving out.
          total_items: length(all)
        )
        # The DESTINATION's bindings, not the source's — the members are
        # comments. Same rule as the destination's own collection, which is what
        # makes "the same node shape either way" true of the triples and not
        # only of the JSON.
        |> Map.put("@context", document_context(conn, opts, destination))

      send_json(conn, 200, document, opts)
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

  # `?load=comments&load=authors` — the relationships a client asked to have
  # stated in place rather than referenced.
  #
  # This is what the `hydra:search` template on every node advertises, and the
  # only thing Hydra offers for a client-parameterised request. Without it a
  # to-many is a reference and the client fetches the same record again to
  # expand it; with it, one request carries the whole shape.
  #
  # **Only a public relationship is loadable.** An unknown or private name is
  # dropped rather than refused: the parameter narrows a response and must never
  # widen what may be read, so a client naming something it may not see gets
  # exactly the response it would have got without asking. Same rule as
  # `?observe=`, and the reason neither is an ungoverned second read shape.
  #
  # RFC 6570's explode form, so a repeated param is a list — which is what
  # `{?load*}` in the template says and what Plug parses natively.
  defp load_params(conn, resource) do
    conn = Plug.Conn.fetch_query_params(conn)

    allowed =
      resource
      |> public_relationships()
      |> Enum.map(& &1.name)
      |> MapSet.new()

    conn.query_params
    |> Map.get("load", [])
    |> List.wrap()
    |> Enum.flat_map(&String.split(to_string(&1), ","))
    |> Enum.map(&String.trim/1)
    |> Enum.map(&safe_atom/1)
    |> Enum.filter(&(&1 && MapSet.member?(allowed, &1)))
    |> Enum.uniq()
  end

  # `String.to_existing_atom/1` so a request cannot mint atoms — an unbounded
  # atom table is a denial-of-service, and every legal value already exists as a
  # relationship name.
  defp safe_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  # `?offset=&limit=` for a related collection, as plain integers.
  #
  # Separate from `page_params/1` because that builds *Ash* pagination options
  # for a read action, and a related collection is not read through one — it is
  # loaded through its source. Same query parameters, so a client pages both the
  # same way.
  defp related_window(conn) do
    conn = Plug.Conn.fetch_query_params(conn)
    params = conn.query_params

    offset = params["offset"] || get_in(params, ["page", "offset"])
    limit = params["limit"] || get_in(params, ["page", "limit"])

    {to_int(offset) || 0, to_int(limit)}
  end

  defp to_int(nil), do: nil

  defp to_int(value) do
    case Integer.parse(to_string(value)) do
      {int, _rest} when int >= 0 -> int
      _ -> nil
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
    # The body is the whole input. A nested create merged the owner id from the
    # path over it, so the address supplied part of the write — which is the
    # same fact in two places, and the path silently won when they disagreed.
    # A create now names its parent as a link, which `LinkInput` resolves
    # against the routes that serve a GET.
    body = read_body_params(conn)

    action_struct = Ash.Resource.Info.action(resource, action)

    with {:ok, input, links} <-
           LinkInput.split(body, resource, action_struct, link_opts(resource, opts)),
         :ok <- LinkInput.verify_targets(links, actor: actor, tenant: tenant) do
      {keys, managed} = LinkInput.partition(links, resource, action_struct)

      safe(fn ->
        resource
        |> Ash.Changeset.for_create(action, Map.merge(input, keys), actor: actor, tenant: tenant)
        |> LinkInput.manage(managed)
        |> Ash.create(authorize?: true)
      end)
      |> respond_write(conn, resource, type, actor, tenant, opts, created: true)
    else
      {:error, _reason, detail} -> send_error(conn, 422, detail)
    end
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
    body = read_body_params(conn)
    action_struct = Ash.Resource.Info.action(resource, action)

    with {:ok, input, links} <-
           LinkInput.split(body, resource, action_struct, link_opts(resource, opts)),
         :ok <- LinkInput.verify_targets(links, actor: actor, tenant: tenant) do
      run_write(conn, record, resource, type, action_struct, input, links, actor, tenant, opts)
    else
      {:error, _reason, detail} -> send_error(conn, 422, detail)
    end
  end

  defp run_write(conn, record, resource, type, action_struct, input, links, actor, tenant, opts) do
    action = action_struct.name

    case action_struct.type do
      :destroy ->
        safe(fn ->
          record
          |> Ash.Changeset.for_destroy(action, input, actor: actor, tenant: tenant)
          |> Ash.destroy(authorize?: true, return_destroyed?: true)
        end)
        |> respond_destroy(conn, resource, type, actor, tenant, opts)

      :update ->
        {keys, managed} = LinkInput.partition(links, resource, action_struct)

        safe(fn ->
          record
          |> Ash.Changeset.for_update(action, Map.merge(input, keys),
            actor: actor,
            tenant: tenant
          )
          |> LinkInput.manage(managed)
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
    node = record |> forget_links(resource) |> node(type, resource, id, actor, tenant, opts)
    context = document_context(conn, opts, resource)
    status = if Keyword.get(write_opts, :created, false), do: 201, else: 200
    send_json(conn, status, Map.put(node, "@context", context), opts)
  end

  defp respond_write({:error, error}, conn, _resource, _type, _actor, _tenant, _opts, _write_opts) do
    send_ash_error(conn, error)
  end

  # Managing a relationship leaves its target loaded on the result, which would
  # expand that one link and reference every other — a shape decided by how the
  # write ran rather than by what the action declares. A write returns the new
  # state of the record it wrote, so its links are references, the same as a
  # read of a resource that loads nothing.
  defp forget_links(record, resource) do
    resource
    |> public_relationships()
    |> Enum.reduce(record, fn relationship, acc ->
      Map.put(acc, relationship.name, %Ash.NotLoaded{
        type: :relationship,
        field: relationship.name
      })
    end)
  rescue
    _ -> record
  end

  # A destroy returns the record it destroyed.
  #
  # The alternative — 204 with an empty body — makes a client that wants to show
  # what it deleted issue a GET first and hold the result across the delete.
  # Ash hands the record back for the asking (`return_destroyed?: true`), so the
  # information is already there; sending it costs one render.
  #
  # **The node carries no operations.** Every affordance would address a record
  # that no longer exists, so a client following `update` on this node gets a
  # 404 having been told it was available. The representation is the record's
  # final state and nothing more: what it *was*, not what may be done to it.
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
      |> Map.put("@context", context),
      opts
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

    send_json(conn, 200, Map.put(body, "@context", document_context(conn, opts)), opts)
  end

  defp respond_generic(:ok, conn, _opts), do: send_json(conn, 200, %{"@type" => "Result"})
  defp respond_generic({:error, error}, conn, _opts), do: send_ash_error(conn, error)

  # ── Node building ─────────────────────────────────────────────────────────

  # A resource node: its attributes flattened onto the node, its identity, its
  # relationship links, and (for a member) its gated operations + structural
  # navigation.
  defp node(record, type, resource, id, actor, tenant, opts, node_opts \\ []) do
    href = member_href(resource, id, opts)

    base =
      record
      |> attributes(resource, opts)
      |> Map.merge(%{
        "@id" => href,
        "@type" => Context.node_type(type, AshHateoas.Resource.Info.semantic_type(resource))
      })

    # A node already rendered further up the graph is referenced rather than
    # rendered again — the link says the same thing, and a cycle
    # (comment → document → comment) would otherwise not terminate.
    visited = MapSet.put(Keyword.get(node_opts, :visited, MapSet.new()), href)
    link_opts = Keyword.put(opts, :visited, visited)

    case Keyword.get(node_opts, :scope, :member) do
      # A node reached through a link or as a collection member: its own data
      # and its own links, but no operations — an affordance belongs on the
      # node it addresses, one URL away.
      :linked ->
        # No `hydra:search` here: a linked node is one URL away from the node
        # that addresses it, and repeating the template on every member of every
        # page would be noise. Follow the member's `@id` to ask it anything.
        merge_relationships(base, record, resource, id, actor, tenant, link_opts)

      :member ->
        operations =
          record
          |> AshHateoas.affordances(actor, affordance_opts(resource, opts) ++ [tenant: tenant])
          |> Renderer.render(
            render_opts(type, resource, opts,
              node_id: member_href(resource, id, opts),
              # The record's own id, which is the only placeholder a flat route
              # has. `Renderer.href/2` substitutes each `:name` it is given.
              path_params: %{"id" => id}
            )
          )

        nav = Navigation.record_links(record, opts[:domains], nav_opts(opts))

        base
        |> Map.merge(operations)
        |> merge_navigation(nav, opts)
        |> merge_relationships(
          record,
          resource,
          id,
          actor,
          tenant,
          Keyword.put(link_opts, :addressed?, true)
        )
    end
  end

  # Every public relationship surfaces on the node as a link, keyed by the
  # relationship name. Each property is declared a `hydra:Link` in the
  # ApiDocumentation, so a client knows the key is a link.
  #
  # What the link carries depends on whether the relationship was loaded:
  #
  #   * **Not loaded** — a `belongs_to` references the target member, built from
  #     the local foreign key without reading the target. A to-many has nothing
  #     to reference and is **omitted**: there is no per-relationship collection
  #     URL, and an empty collection would assert the record has no members. A
  #     `has_one` keeps its key on the destination, so it too appears only when
  #     loaded.
  #   * **Loaded** (`Ash.load/3`, an action preparation, a query load) — the
  #     target rendered in place, carrying its own `@id`, recursively. A to-many
  #     is a `hydra:Collection` carrying its members.
  #
  # Both forms are the same graph: expansion states the target's own triples
  # alongside the link rather than in a separate response. The reference is the
  # identity either way, so a client may follow or read, and gets the same
  # answer.
  defp merge_relationships(node, record, resource, id, actor, tenant, opts) do
    resource
    |> public_relationships()
    |> Enum.reduce(node, fn relationship, acc ->
      case relationship_link(record, resource, relationship, id, actor, tenant, opts) do
        nil -> acc
        value -> Map.put(acc, to_string(relationship.name), value)
      end
    end)
    |> maybe_put_load_template(resource, id, opts)
  end

  defp maybe_put_load_template(node, resource, id, opts) do
    if Keyword.get(opts, :addressed?, false) do
      put_load_template(node, resource, id, opts)
    else
      node
    end
  end

  # `hydra:search` — how a client asks for a relationship's members in place.
  #
  #     {"@type": "IriTemplate",
  #      "hydra:template": "/articles/7{?load*}",
  #      "hydra:mapping": [{"hydra:variable": "load",
  #                         "hydra:property": {"@id": "…#article/comments"}}, …]}
  #
  # A `hydra:IriTemplate` because it is the only thing Hydra has for a
  # client-parameterised request: the vocabulary has no term for "expand this",
  # and inventing one would put a fact in a place no generic client looks.
  #
  # **One mapping per loadable relationship**, each keyed on the property IRI
  # the ontology already declares — so the set of legal values is stated by
  # enumeration, in terms a client can resolve, rather than by a SHACL
  # constraint on a node that is not a shape.
  #
  # `{?load*}` is RFC 6570's explode form: `?load=a&load=b`, which is what Plug
  # parses natively and what `hydra:variableRepresentation` describes.
  #
  # Omitted where the resource has no public to-many, since a template offering
  # nothing is noise.
  defp put_load_template(node, resource, id, opts) do
    loadable = Enum.filter(public_relationships(resource), &(&1.cardinality == :many))
    type = AshHateoas.Resource.Info.type(resource)

    case {loadable, member_href(resource, id, opts)} do
      {[], _href} ->
        node

      {_loadable, nil} ->
        node

      {loadable, href} ->
        Map.put(node, "hydra:search", %{
          "@type" => "IriTemplate",
          "hydra:template" => "#{href}{?load*}",
          "hydra:variableRepresentation" => "BasicRepresentation",
          "hydra:mapping" =>
            Enum.map(loadable, fn relationship ->
              %{
                "@type" => "IriTemplateMapping",
                "hydra:variable" => "load",
                "hydra:property" => %{
                  "@id" => Context.property_iri(type, relationship.name)
                },
                "hydra:required" => false
              }
            end)
        })
    end
  end

  defp public_relationships(resource) do
    Ash.Resource.Info.public_relationships(resource)
  rescue
    _ -> []
  end

  defp relationship_link(record, resource, relationship, id, actor, tenant, opts) do
    case Map.get(record, relationship.name) do
      %Ash.NotLoaded{} -> unloaded_link(record, resource, relationship, id, actor, tenant, opts)
      nil -> unloaded_link(record, resource, relationship, id, actor, tenant, opts)
      loaded -> loaded_link(loaded, resource, relationship, id, opts)
    end
  end

  # A `belongs_to` reference comes from the local foreign key — no read of the
  # target. A missing or unselected key yields no property: absent, not null.
  defp unloaded_link(
         record,
         _resource,
         %{type: :belongs_to} = relationship,
         _id,
         _actor,
         _tenant,
         opts
       ) do
    case Map.get(record, relationship.source_attribute) do
      key when is_binary(key) or is_integer(key) ->
        member_ref(relationship.destination, key, opts)

      _missing ->
        nil
    end
  end

  # A `has_one` keeps its key on the destination, so there is nothing local to
  # reference and it appears only when loaded.
  defp unloaded_link(_record, _resource, %{cardinality: :one}, _id, _actor, _tenant, _opts),
    do: nil

  # An unloaded to-many renders **the way its collection URL does**: a bounded
  # page of members, the true total, its own `@id`, and a `hydra:view` to page
  # with.
  #
  #     "comments": {"@id": "/articles/7/comments", "@type": "Collection",
  #                  "hydra:totalItems": 214,
  #                  "hydra:member": [{"@id": "/comments/1"}, …],
  #                  "hydra:view": {"@type": "PartialCollectionView", …}}
  #
  # The `@id` is the related route, so the collection has a real identity that
  # dereferences to exactly this collection — not the record's own URL, which
  # would make the article and its comments one subject and turn
  # `hydra:totalItems: 214` into a statement about the article.
  #
  # **The members are references.** Their `@id` and nothing else, because
  # nothing was loaded: a client learns which comments exist and can follow any
  # of them, without the server rendering 214 nodes. `?load=comments` expands
  # the same members in place — so `load` controls *expansion*, never presence,
  # which is the rule a to-one already follows.
  #
  # Built by `Collection.wrap/2`, the same function that renders `/articles`, so
  # an inline collection and an addressed one cannot drift into two shapes for
  # one concept.
  defp unloaded_link(record, resource, relationship, id, actor, tenant, opts) do
    case related_href(resource, relationship, id, opts) do
      nil ->
        nil

      href ->
        {refs, total} = preview(record, relationship, actor, tenant, opts)

        Collection.wrap(refs,
          id: href,
          total_items: total,
          # `:view_map`, not `:view` — this is a built `PartialCollectionView`,
          # where `:view` takes the page links to build one from.
          view_map: view_links(href, total)
        )
    end
  end

  # How many member references an unloaded to-many states before deferring to
  # its collection URL.
  #
  # Small deliberately. This runs for every public to-many on every node of
  # every collection page, so the cost multiplies — and its job is to let a
  # client recognise the set, not to deliver it.
  @preview_limit 10

  # The first page of a relationship as bare references, and its true size.
  #
  # Read as the **actor**, so a member they may not see is neither referenced
  # nor counted: an inline collection must never disclose more than a read of
  # the destination would, which is the same rule `?observe=` follows.
  #
  # Degrades to `{[], nil}` rather than raising. A relationship that cannot be
  # read here must leave a collection with an `@id` and no members — still
  # followable, still true — rather than take the whole node down.
  defp preview(record, relationship, actor, tenant, opts) do
    read_opts = [actor: actor, tenant: tenant, authorize?: true]

    case Ash.load(record, [relationship.name], read_opts) do
      {:ok, loaded} ->
        related = loaded |> Map.get(relationship.name) |> List.wrap()

        refs =
          related
          |> Enum.take(@preview_limit)
          |> Enum.map(&member_ref(relationship.destination, record_id(&1), opts))
          |> Enum.reject(&is_nil/1)

        {refs, length(related)}

      _ ->
        {[], nil}
    end
  rescue
    _ -> {[], nil}
  end

  # A `PartialCollectionView` when the references are a page of something
  # larger, and none when they are the whole set.
  #
  # `hydra:next` is what makes the truncation actionable rather than merely
  # declared: `hydra:totalItems` says how much is missing, and this says where
  # to get it. Both need a URL to page against, which is the related route's
  # reason for existing.
  defp view_links(_href, total) when is_nil(total), do: nil

  defp view_links(_href, total) when total <= @preview_limit, do: nil

  defp view_links(href, _total) do
    Collection.view(id: href, first: href, next: "#{href}?offset=#{@preview_limit}")
  end

  # A loaded to-one: the target node in place of its reference.
  defp loaded_link(target, _resource, %{cardinality: :one} = relationship, _id, opts)
       when is_struct(target) do
    expanded_node(target, relationship.destination, opts)
  end

  # A loaded to-many: a `hydra:Collection` carrying its members.
  #
  # **Not a bare array.** `hydra:member` is a real predicate: with it, the
  # property points at *one collection* which *has* N members. Without it the
  # property would point at N unrelated things and the collection — the subject
  # `hydra:totalItems` and any future paging describe — would not exist at all.
  #
  # The collection is a **blank node**, which is honest rather than a
  # degradation: it is not separately addressable, it exists as the value of
  # this property on this record. Each member carries its own flat `@id`, so it
  # is a link *and* the data, and a client follows that to reach the member's
  # own affordances. The class collection is the addressable one.
  defp loaded_link(targets, resource, relationship, id, opts) when is_list(targets) do
    members =
      targets
      |> Enum.map(&expanded_node(&1, relationship.destination, opts))
      |> Enum.reject(&is_nil/1)

    collection = %{
      "@type" => "Collection",
      "hydra:member" => members,
      "hydra:totalItems" => length(members)
    }

    # The same `@id` the unloaded form carries — the collection's own URL, not
    # the request's. Expansion states more about the members; it never changes
    # which collection this is, so both forms are one subject with one identity.
    # (`?load=comments` is how a client *asked*; it is not what the collection
    # is called.)
    case related_href(resource, relationship, id, opts) do
      href when is_binary(href) -> Map.put(collection, "@id", href)
      _ -> collection
    end
  end

  defp loaded_link(_targets, _resource, _relationship, _id, _opts), do: nil

  # A target rendered in place. Already-visited nodes degrade to a bare
  # reference: the same statement, and what stops a cycle from recursing.
  defp expanded_node(target, destination, opts) do
    id = record_id(target)
    href = member_href(destination, id, opts)
    visited = Keyword.get(opts, :visited, MapSet.new())

    cond do
      is_nil(href) ->
        nil

      MapSet.member?(visited, href) ->
        %{"@id" => href}

      true ->
        type = AshHateoas.Resource.Info.type(destination)

        target
        |> node(type, destination, id, nil, nil, opts, scope: :linked, visited: visited)
        |> put_scoped_terms(destination)
    end
  end

  # An expanded node carries the DESTINATION's keys — `owner_id` on a Document,
  # `article` on a Comment — while the document's `@context` binds the keys of
  # the resource that was requested. A key no term defines is silently dropped
  # by a JSON-LD processor, so without this the target's data expands to
  # nothing: present in the JSON, absent from the graph.
  #
  # JSON-LD 1.1 lets a node object carry its own `@context`, scoped to that
  # subtree. The bindings are the very ones a read of the target on its own
  # would emit (`Context.node_terms/1`), which is what makes a node expand to
  # the same triples whether it is reached directly or through a link.
  defp put_scoped_terms(node, destination) do
    case Context.node_terms(destination) do
      terms when map_size(terms) == 0 -> node
      terms -> Map.put(node, "@context", terms)
    end
  end

  # A node reference to another resource's member: the target's primary `:get`
  # route with the key filled in. A route still carrying a placeholder after
  # filling (an owned target whose owner id this request never saw) is not an
  # address, so no reference is emitted.
  defp member_ref(destination, key, opts) do
    with %Route{} = route <- get_route(destination, &(&1.type == :get and &1.primary?)),
         filled = fill(route.route, key, opts),
         false <- String.contains?(filled, ":") do
      %{"@id" => href_prefix(opts) <> filled}
    else
      _ -> nil
    end
  end

  # A generated foreign key is excluded here as it is from the documentation —
  # the node and the class it claims to be an instance of must agree about what
  # properties exist. See `AshHateoas.Resource.Info.public_attributes/1`.
  defp attributes(record, resource, opts) do
    resource
    |> AshHateoas.Resource.Info.public_attributes()
    |> Map.new(fn attribute ->
      value = Map.get(record, attribute.name)
      {to_string(attribute.name), attribute_value(attribute, value, opts)}
    end)
    |> Map.merge(calculations(record, resource, opts))
  end

  # A public calculation is part of the representation, exactly as an attribute
  # is. The difference is only in where the value comes from — derived rather
  # than stored — which is a storage concern the wire has no reason to carry.
  #
  # It was omitted entirely: every path here read `public_attributes/1` and
  # stopped, so a resource could declare a calculation, load it, and still have
  # it absent from the node. That made a derived property unreadable by any
  # client no matter how it was declared.
  #
  # **Unloaded ones are skipped rather than rendered as null.** A calculation is
  # computed only when an action loads it, and `%Ash.NotLoaded{}` means "not
  # asked for" — while `null` would assert the value *is* nothing. The same
  # distinction a to-many draws between absent and empty.
  defp calculations(record, resource, opts) do
    resource
    |> Ash.Resource.Info.public_calculations()
    |> Enum.flat_map(fn calculation ->
      case Map.get(record, calculation.name) do
        %Ash.NotLoaded{} -> []
        nil -> []
        value -> [{to_string(calculation.name), calculation_value(calculation, value, opts)}]
      end
    end)
    |> Map.new()
  end

  defp calculation_value(calculation, value, opts) when is_list(value),
    do: Enum.map(value, &calculation_value(calculation, &1, opts))

  # A calculation typed `AshHateoas.Type.ResourceLink` is a **link**, and is
  # rendered as one — `{"@id" => url}` — exactly as an attribute of that type is.
  #
  # The two paths agreeing matters more than it looks. A reference a resource
  # cannot express as a relationship has to travel some other way, and a
  # calculation is how: an `Ash.Type.Union` over several resources has no single
  # `destination` for a `belongs_to` to name, so the address is *derived* rather
  # than declared. Rendering it as a bare string would make it the one reference
  # in a document that a client cannot follow.
  defp calculation_value(%{type: type}, value, _opts) when is_binary(value) do
    if link_type?(type), do: %{"@id" => value}, else: value
  end

  defp calculation_value(_calculation, value, _opts), do: value

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
  # `collection` is the only one: a record's parent is its collection, which is
  # exactly what `hydra:collection` says. Anything above that would be a
  # collection-of-collections, which is not a resource.
  #
  # Note `hydra:view` itself remains in use, for what it is actually for:
  # `Collection.wrap/2` emits a `hydra:PartialCollectionView` under it when a
  # collection is paged.
  defp merge_navigation(node, nav, opts) do
    Enum.reduce(nav, node, fn
      # `Navigation` is transport-neutral and builds from a route pattern, so a
      # collection URL may still hold `:id`. Filled here, against the request
      # that reached this record.
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
    # A pattern match rather than a string comparison, so a path carrying an
    # extra segment fails to match rather than being truncated onto this route.
    case capture_params(prefix <> route, path) do
      nil -> nil
      _params -> {:collection, resource, type, action}
    end
  end

  defp match_route(%Route{type: :get, primary?: true, route: route}, resource, type, path, prefix) do
    case capture_params(prefix <> route, path) do
      nil -> nil
      params -> {:member, resource, type, params["id"]}
    end
  end

  # `/base/:id/<relationship>` — the URL an inline collection carries as its
  # `@id`. Matching it here is what makes that identity dereferenceable; without
  # this clause the node states an `@id` the router 404s, which is a broken
  # contract for a client that follows links rather than constructing them.
  defp match_route(
         %Route{type: :related, route: route, relationship: relationship},
         resource,
         _type,
         path,
         prefix
       ) do
    case capture_params(prefix <> route, path) do
      nil -> nil
      params -> {:related, resource, relationship, params["id"]}
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

      # A create posts to the collection base and has no `:id`; an update or a
      # destroy addresses a member and has one. The presence of `:id` in the
      # *pattern* decides which, so both are one pattern match.
      case capture_params(full, path) do
        nil -> nil
        params -> {route.action, params["id"]}
      end
    end
  end

  defp route_method(%Route{type: :post}), do: "POST"
  defp route_method(%Route{type: :patch}), do: "PATCH"
  defp route_method(%Route{type: :delete}), do: "DELETE"

  defp route_method(%Route{type: :route, method: method}),
    do: method |> to_string() |> String.upcase()

  defp route_method(_route), do: nil

  # Every `:name` segment a path fills in, as `%{"name" => value}` — or `nil`
  # when the path does not match the pattern at all. `/documents/:id` against
  # `/documents/123` yields `%{"id" => "123"}`.
  #
  # A map rather than a bare id because it is the honest shape of a pattern
  # match, and it was load-bearing while routes nested and carried two. Every
  # route now has at most `:id`, so callers read that key directly — but the
  # map is what makes an extra segment a non-match rather than a silent
  # mis-capture.
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

  # ── Ash calls ───────────────────────────────────────────────────────────────

  defp load(resource, id, actor, tenant, load \\ []) do
    opts = [actor: actor, tenant: tenant, authorize?: true]
    opts = if load == [], do: opts, else: Keyword.put(opts, :load, load)

    case Ash.get(resource, id, opts) do
      {:ok, record} -> record
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Run the matched read action (the primary read for the base index, or a named
  # collection read like `semantic_search` for `/base/<name>`), with any query
  # params bound to its public arguments.
  defp read(resource, action, arguments, actor, tenant, page, load) do
    read_opts = [actor: actor, tenant: tenant, authorize?: true]
    read_opts = if load == [], do: read_opts, else: Keyword.put(read_opts, :load, load)

    # Paginate only when page params were supplied AND this action declares
    # pagination support — passing `page:` to an unpaginated action raises.
    read_opts =
      if page != [] and paginatable?(resource, action) do
        Keyword.put(read_opts, :page, page)
      else
        read_opts
      end

    query = Ash.Query.for_read(resource, action, arguments, actor: actor, tenant: tenant)

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

  # A route pattern with its placeholder filled.
  #
  # There is exactly one: the record's own `:id`. A nested route carried the
  # owner's too, and substituting `:id` alone left the parent's placeholder in
  # the URL — a node advertising `@id: "/ledger/:ledger_id/entry/<id>"`, which
  # is a pattern rather than an address. Flat routes remove the second
  # placeholder rather than filling it, so that failure mode has no source.
  defp fill(pattern, id, _opts) do
    # A collection path has no `:id` to fill, and is given none — substituting
    # `nil` would put an empty segment in the URL.
    if is_nil(id), do: pattern, else: String.replace(pattern, ":id", to_string(id))
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

  # What `LinkInput` needs to resolve an IRI back to a resource: the route
  # table's domains, and the prefix/origin the rendered hrefs carry — so the
  # URLs this API issues are the URLs it accepts.
  defp link_opts(resource, opts) do
    [
      resource: resource,
      domains: opts[:domains],
      prefix: opts[:prefix],
      base_url: opts[:base_url]
    ]
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
  defp document_context(conn, opts),
    do: Context.put_base(Context.context(), document_base(conn, opts))

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

  # Every JSON body this package emits passes through here, which is why the
  # vocabulary is localised at this one point rather than at the fifty-odd sites
  # that mint an IRI — one pass cannot miss a path, and the three sites that run
  # in a compile-time transformer have no request to read an origin from.
  defp send_json(conn, status, body, opts \\ []) do
    conn
    |> Plug.Conn.put_resp_content_type(Context.content_type(), nil)
    |> Plug.Conn.send_resp(
      status,
      Jason.encode!(Context.localise(body, vocab_origin(conn, opts)))
    )
    |> Plug.Conn.halt()
  end

  # What an API's own classes are named after: the public origin it states, or
  # the one this request arrived on. The same rule `@base` follows, and for the
  # same reason — a relative identity has to resolve against the API rather than
  # against whatever the reader happened to load last.
  defp vocab_origin(conn, opts) do
    case base_url(opts) do
      "" -> request_origin(conn)
      url -> url
    end
  end

  # The entry point: the one URL a client has to be told.
  #
  # It carries `hydra:collection` per reachable type, which is the same property
  # a record uses to name the collection it belongs to, so a client that can
  # follow one can follow these. Nothing is keyed by type name, so no data lands
  # in a JSON object key: the values are typed node references and the key is a
  # declared Hydra term. That was the objection to the old root listing, and it
  # is answered here rather than avoided.
  #
  # THE LIST IS PER ACTOR. A link is followable only if the actor may perform
  # the action that following it performs, so a collection this actor would be
  # refused is omitted rather than offered and rejected on arrival.
  defp entry_point(conn, actor, opts) do
    collections =
      opts[:domains]
      |> Index.build()
      |> Enum.sort_by(fn {type, _} -> type end)
      |> Enum.flat_map(fn {type, resource} -> collection_link(type, resource, actor, opts) end)

    %{
      "@context" => Context.context(),
      "@id" => href_prefix(opts) <> request_url(conn),
      "@type" => "hydra:Resource",
      "hydra:title" => "Entry point",
      "hydra:apiDocumentation" => %{"@id" => href_prefix(opts) <> opts[:doc_path]},
      "hydra:collection" => collections
    }
  end

  defp collection_link(type, resource, actor, opts) do
    with href when is_binary(href) <-
           Navigation.collection_href(resource, opts[:domains], prefix: href_prefix(opts)),
         true <- readable?(resource, actor) do
      [%{"@id" => href, "@type" => "hydra:Collection", "hydra:title" => to_string(type)}]
    else
      _ -> []
    end
  end

  # Whether this actor may read this resource at all. `Ash.can?/3` asks the same
  # question the read itself will ask, so the answer here and the answer on
  # arrival cannot disagree.
  defp readable?(resource, actor) do
    case Ash.Resource.Info.primary_action(resource, :read) do
      nil -> false
      %{name: name} -> Ash.can?({resource, name, %{}}, actor, run_queries?: false, maybe_is: true)
    end
  rescue
    _ -> false
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
