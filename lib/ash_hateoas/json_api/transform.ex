defmodule AshHateoas.JsonApi.Transform do
  @moduledoc """
  Injects affordance links into a serialized JSON:API document (§5.1).

  `ash_json_api` exposes no per-record seam for `links` — `serialize_one_record/3`
  is private and builds `links` with the self link only. So affordances are
  merged **after** serialization, on the public output rather than internals.

  Why that is sound rather than a workaround:

    * it touches no private functions — the JSON:API document is public output
    * it is version-robust — the document shape is fixed by the *spec*, so it
      survives refactors of `ash_json_api`'s private helpers
    * it is self-contained — no fork, no patched dependency

  ## Two stages

  1. **Capture** (`before_dispatch/2`) — `ash_json_api` hands us the typed
     `%Route{}`, domain and resource before dispatch. Stashing it on
     `conn.private` is what lets stage 2 know whether this was a single-record
     read (`:get`) or a collection read (`:index`) without guessing from the
     response shape.
  2. **Merge** (`call/2` + `register_before_send/2`) — decode the body, walk
     `data` and `included`, and merge `links` into each resource object.

  ## Wiring

      defmodule MyApp.JsonApiRouter do
        use AshJsonApi.Router,
          domains: [MyApp.Docs],
          before_dispatch: {AshHateoas.JsonApi.Transform, :before_dispatch, []}
      end

      # in the Plug pipeline, wrapping the router
      plug AshHateoas.JsonApi.Transform
      plug MyApp.JsonApiRouter

  Both halves are required: without the capture the transform cannot resolve
  the actor's route context and becomes a no-op.
  """

  @behaviour Plug

  require Logger

  alias AshHateoas.JsonApi.{Index, Renderer}

  @private_key :ash_hateoas
  @content_type "application/vnd.api+json"
  @profile "https://ash-hateoas.org/profiles/affordances"

  @doc "The JSON:API profile URI this package advertises."
  @spec profile() :: String.t()
  def profile, do: @profile

  # ── Stage 1: capture ────────────────────────────────────────────────────────

  @doc """
  `before_dispatch` hook. Stashes the route context for the merge stage.

  `route_info` is either an atom (`:open_api`, `:json_schema`, `:not_found`) or
  a map of `domain`, `resource`, `route`, `params`. Only the map form carries
  anything worth capturing.
  """
  @spec before_dispatch(Plug.Conn.t(), map() | atom()) :: Plug.Conn.t()
  def before_dispatch(conn, %{route: route, resource: resource, domain: domain} = info) do
    Plug.Conn.put_private(conn, @private_key, %{
      route: route,
      resource: resource,
      domain: domain,
      params: Map.get(info, :params, %{})
    })
  end

  def before_dispatch(conn, _route_info), do: conn

  # ── Stage 2: merge ──────────────────────────────────────────────────────────

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    if root_request?(conn, opts) do
      serve_root(conn, opts)
    else
      Plug.Conn.register_before_send(conn, &merge(&1, opts))
    end
  end

  # ── The root entry document (R9) ────────────────────────────────────────────

  # `ash_json_api` has no route for "/" and answers 404, so the entry document
  # is served here rather than decorated. This is the one URL a client
  # hardcodes: from it, every reachable type and collection is discoverable.
  #
  # Halts the pipeline, so the router never sees the request.
  defp serve_root(conn, opts) do
    actor = Ash.PlugHelpers.get_actor(conn)
    domains = configured_domains(opts)

    document =
      %{
        "jsonapi" => %{"version" => "1.0"},
        "links" => AshHateoas.Navigation.root(domains, actor, opts),
        "meta" => %{"profile" => @profile}
      }
      |> Jason.encode!()

    conn
    |> Plug.Conn.put_resp_content_type(@content_type <> "; profile=\"#{@profile}\"", nil)
    |> Plug.Conn.send_resp(200, document)
    |> Plug.Conn.halt()
  end

  # Only serve the root when domains are configured — without them there is
  # nothing to enumerate, and the request should fall through to the router.
  # `path_info`, NOT `request_path`. Under `forward "/api", to: …` Plug leaves
  # `request_path` as the full "/api" and moves the consumed segments out of
  # `path_info`, so matching on `request_path` means the root document is never
  # served from a mounted router — which is every real deployment.
  defp root_request?(%{method: "GET"} = conn, opts) do
    conn.path_info in [[], [""]] and configured_domains(opts) != []
  end

  defp root_request?(_conn, _opts), do: false

  defp configured_domains(opts) do
    opts
    |> Keyword.get(:domains, Keyword.get(opts, :domain))
    |> List.wrap()
  end

  defp merge(conn, opts) do
    with true <- json_api?(conn),
         %{} = context <- conn.private[@private_key],
         {:ok, document} <- decode(conn.resp_body),
         true <- Map.has_key?(document, "data") do
      actor = Ash.PlugHelpers.get_actor(conn)
      tenant = Ash.PlugHelpers.get_tenant(conn)

      merged =
        document
        |> inject(context, actor, tenant, opts)
        |> Jason.encode!()

      conn
      |> Plug.Conn.put_resp_content_type(@content_type <> "; profile=\"#{@profile}\"", nil)
      |> Map.put(:resp_body, merged)
      |> Plug.Conn.delete_resp_header("content-length")
      |> Plug.Conn.put_resp_header("content-length", byte_size(merged) |> Integer.to_string())
    else
      _ -> conn
    end
  rescue
    exception ->
      # A rendering failure must never break the response the client asked for.
      Logger.error("""
      [ash_hateoas] Failed to inject affordances; returning the document unchanged.

      #{Exception.format(:error, exception, __STACKTRACE__)}
      """)

      conn
  end

  defp inject(document, context, actor, tenant, opts) do
    index = Index.build(domains(context))

    document
    |> update_in_data(&decorate(&1, index, context, actor, tenant, opts))
    |> update_included(&decorate(&1, index, context, actor, tenant, opts))
    |> add_collection_affordances(context, actor, tenant, opts)
  end

  # A collection response carries TYPE-level affordances in its top-level links
  # (`create`, …) and none per record. That removes the M × N cost structurally
  # rather than defaulting it off, and serves the cold-start case: a client
  # entering at /documents is told it may create.
  defp add_collection_affordances(document, context, actor, tenant, opts) do
    if collection?(document) do
      affordances =
        AshHateoas.affordances(context.resource, actor,
          domain: context.domain,
          tenant: tenant,
          domains: domains(context)
        )

      links = Renderer.render(affordances, prefix: prefix(context, opts))

      Map.update(document, "links", links, &Map.merge(&1, links))
    else
      document
    end
  end

  # Per-record affordances apply only to single-record documents.
  defp decorate(%{"type" => type, "id" => id} = object, index, context, actor, tenant, opts) do
    with false <- collection_context?(context),
         {:ok, resource} <- Index.fetch(index, type),
         record when not is_nil(record) <- load(resource, id, actor, tenant, context) do
      affordances =
        AshHateoas.affordances(record, actor,
          domain: context.domain,
          tenant: tenant,
          domains: domains(context)
        )

      links =
        affordances
        |> Renderer.render(path_params: %{"id" => id}, prefix: prefix(context, opts))
        # R9: structural navigation travels with the affordances, in the same
        # links object. `collection` and `up` are registered IANA relations, so
        # they cannot collide with an action name.
        |> Map.merge(AshHateoas.Navigation.record_links(record, domains(context), opts))

      Map.update(object, "links", links, &Map.merge(&1, links))
    else
      _ -> object
    end
  end

  defp decorate(object, _index, _context, _actor, _tenant, _opts), do: object

  # The serialized document has already lost the record, so it is re-read to
  # evaluate record-dependent policies. Authorization is deliberately ON: a
  # record the actor cannot read must not gain affordances.
  defp load(resource, id, actor, tenant, _context) do
    resource
    |> Ash.get(id, actor: actor, tenant: tenant, authorize?: true)
    |> case do
      {:ok, record} -> record
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp update_in_data(%{"data" => data} = document, fun) when is_list(data) do
    %{document | "data" => Enum.map(data, fun)}
  end

  defp update_in_data(%{"data" => data} = document, fun) when is_map(data) do
    %{document | "data" => fun.(data)}
  end

  defp update_in_data(document, _fun), do: document

  defp update_included(%{"included" => included} = document, fun) when is_list(included) do
    %{document | "included" => Enum.map(included, fun)}
  end

  defp update_included(document, _fun), do: document

  defp collection?(%{"data" => data}), do: is_list(data)
  defp collection?(_document), do: false

  defp collection_context?(%{route: %{type: :index}}), do: true
  defp collection_context?(_context), do: false

  defp domains(%{domain: domain}), do: List.wrap(domain)

  defp prefix(context, opts) do
    Keyword.get(opts, :prefix) || domain_prefix(context)
  end

  defp domain_prefix(%{domain: domain}) do
    AshJsonApi.Domain.Info.prefix(domain)
  rescue
    _ -> nil
  end

  defp json_api?(conn) do
    conn
    |> Plug.Conn.get_resp_header("content-type")
    |> Enum.any?(&String.starts_with?(&1, @content_type))
  end

  defp decode(body) when is_binary(body) and byte_size(body) > 0, do: Jason.decode(body)
  defp decode(_body), do: :error
end
