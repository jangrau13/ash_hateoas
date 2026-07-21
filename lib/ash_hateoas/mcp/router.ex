if Code.ensure_loaded?(Plug) and Code.ensure_loaded?(AshAi.Mcp.Server) do
  defmodule AshHateoas.Mcp.Router do
    @moduledoc """
    An MCP router that serves state-gated affordances as tools (§5.2).

        forward "/mcp", AshHateoas.Mcp.Router,
          domain: MyApp.Docs,
          otp_app: :my_app

    ## What it changes, and what it does not

    Two methods are handled here; everything else is delegated to
    `AshAi.Mcp.Server` unchanged, so an app keeps ash_ai's behaviour for
    initialization, `tools/call`, `resources/*` and the rest.

      * **`tools/list`** — returns the backbone's affordance set for the
        session's current position, rather than `AshAi.exposed_tools/1`'s set.
        That is what brings the state gate to MCP: `exposed_tools` filters by
        `Ash.can?` but not by transitions, so unmodified it offers a transition
        from a state it cannot start in.

      * **`initialize`** — declares `listChanged: true`. ash_ai hardcodes
        `false` and never emits the notification, so a client is told not to
        expect refreshes.

    ## The list_changed gap

    `notifications/tools/list_changed` is ratified and in the MCP spec, and
    Claude Code honours it — but ash_ai 0.7.2 emits it nowhere, and its SSE
    stream holds no channel to push it through.

    This router therefore advertises the capability and provides
    `notify_list_changed/1` for a host app to call after a transition. Where the
    session has no open SSE stream the notification is dropped, and correctness
    still holds: `tools/list` is computed fresh on every call, so a client that
    re-lists after acting always sees the new state. The push is an
    optimisation, not the mechanism.

    This is the one place REQ's "public surface only" rule and R3's push loop
    genuinely conflict. Wrapping — rather than patching — is what keeps us on
    ash_ai's public API.
    """

    use Plug.Router, copy_opts_to_assign: :router_opts

    alias AshAi.Mcp.Server
    alias AshHateoas.Mcp.{Resources, Session, Tools}

    plug(Plug.Parsers,
      parsers: [:json],
      pass: ["application/json"],
      json_decoder: Jason
    )

    plug(:match)
    plug(:dispatch)

    post "/" do
      session_id = session_id(conn)
      opts = conn.assigns.router_opts

      case intercept(conn.params, session_id, conn, opts) do
        {:handled, response} ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(response))

        :delegate ->
          Server.handle_post(conn, conn.params, session_id, opts)
      end
    end

    get "/" do
      Server.handle_get(conn, session_id(conn))
    end

    delete "/" do
      id = session_id(conn)
      Session.clear(id)
      Server.handle_delete(conn, id)
    end

    match _ do
      send_resp(conn, 404, "Not found")
    end

    @doc """
    Build a `notifications/tools/list_changed` message.

    A host app sends this over its own channel to the session after a
    transition. Correctness does not depend on it — `tools/list` is recomputed
    on every call — but a client that honours it refreshes immediately rather
    than on its next poll.
    """
    @spec notify_list_changed(String.t() | nil) :: map()
    def notify_list_changed(_session_id \\ nil) do
      %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}
    end

    @doc """
    Point a session at a record, so the next `tools/list` reflects its state.
    """
    @spec focus(String.t(), module(), term()) :: :ok
    defdelegate focus(session_id, resource, id), to: Session

    # ── Interception ──────────────────────────────────────────────────────────

    defp intercept(%{"method" => "tools/list", "id" => id}, session_id, conn, opts) do
      {:handled,
       %{
         "jsonrpc" => "2.0",
         "id" => id,
         "result" => %{"tools" => tools(session_id, conn, opts)}
       }}
    end

    # ash_ai hardcodes listChanged: false. Rewrite just that flag and leave the
    # rest of its initialize response — protocol version, server info,
    # instructions — exactly as it built it.
    defp intercept(%{"method" => "initialize"} = message, session_id, _conn, opts) do
      case Server.process_message(message, session_id, opts) do
        {:initialize_response, response, _session_id} ->
          {:handled, advertise_list_changed(response)}

        _other ->
          :delegate
      end
    rescue
      _ -> :delegate
    end

    # R9: navigation uses the `resources` primitive, never tools. ash_ai
    # implements resources/list and resources/read only for its own
    # `mcp_resources` DSL entries and has no resources/templates/list at all,
    # so all three are served here over the domain's resources.
    defp intercept(%{"method" => "resources/templates/list", "id" => id}, _session, conn, opts) do
      templates =
        Resources.templates(
          resources(opts, Keyword.get(opts, :domain)),
          Ash.PlugHelpers.get_actor(conn),
          tenant: Ash.PlugHelpers.get_tenant(conn)
        )

      {:handled,
       %{"jsonrpc" => "2.0", "id" => id, "result" => %{"resourceTemplates" => templates}}}
    end

    defp intercept(%{"method" => "resources/list", "id" => id}, _session, conn, opts) do
      entries =
        Resources.list(
          resources(opts, Keyword.get(opts, :domain)),
          Ash.PlugHelpers.get_actor(conn),
          tenant: Ash.PlugHelpers.get_tenant(conn)
        )

      {:handled, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"resources" => entries}}}
    end

    defp intercept(
           %{"method" => "resources/read", "id" => id, "params" => %{"uri" => uri}},
           session_id,
           conn,
           opts
         ) do
      domain_resources = resources(opts, Keyword.get(opts, :domain))

      result =
        Resources.read(
          uri,
          domain_resources,
          Ash.PlugHelpers.get_actor(conn),
          tenant: Ash.PlugHelpers.get_tenant(conn)
        )

      case result do
        {:ok, contents} ->
          # Reading a record IS the focus signal: MCP has no separate "focus"
          # verb, and `resources/read` is the client saying "I am looking at
          # this record now". Focusing here is what makes the record-level
          # state gate reachable over pure MCP — the next `tools/list` returns
          # that record's transitions rather than the cold-start type-level
          # set. Best-effort: a read that cannot be located still returns the
          # record, it just does not move focus.
          maybe_focus(session_id, uri, domain_resources)

          {:handled, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"contents" => [contents]}}}

        {:error, reason} ->
          {:handled,
           %{
             "jsonrpc" => "2.0",
             "id" => id,
             "error" => %{"code" => -32002, "message" => "Resource not found: #{inspect(reason)}"}
           }}
      end
    end

    defp intercept(_message, _session_id, _conn, _opts), do: :delegate

    defp advertise_list_changed(response) when is_binary(response) do
      response
      |> Jason.decode!()
      |> update_in(
        ["result", "capabilities", "tools"],
        &Map.put(&1 || %{}, "listChanged", true)
      )
    end

    defp tools(session_id, conn, opts) do
      actor = Ash.PlugHelpers.get_actor(conn)
      tenant = Ash.PlugHelpers.get_tenant(conn)
      domain = Keyword.get(opts, :domain)

      case Session.position(session_id) do
        # A record is in focus: record-level affordances, state gate applies.
        %{resource: resource, id: id} ->
          case load(resource, id, actor, tenant) do
            nil ->
              collection_tools(opts, actor, tenant, domain)

            record ->
              record
              |> AshHateoas.affordances(actor, domain: domain, tenant: tenant)
              |> Tools.render(type_prefix(resource))
          end

        # Cold start: no record, so type-level affordances across the domain.
        nil ->
          collection_tools(opts, actor, tenant, domain)
      end
    end

    defp collection_tools(opts, actor, tenant, domain) do
      opts
      |> resources(domain)
      |> Enum.flat_map(fn resource ->
        resource
        |> AshHateoas.affordances(actor, domain: domain, tenant: tenant)
        |> Tools.render(type_prefix(resource))
      end)
    end

    defp resources(opts, domain) do
      case Keyword.get(opts, :resources) do
        nil -> Ash.Domain.Info.resources(domain)
        resources -> List.wrap(resources)
      end
    rescue
      _ -> []
    end

    defp load(resource, id, actor, tenant) do
      case Ash.get(resource, id, actor: actor, tenant: tenant, authorize?: true) do
        {:ok, record} -> record
        _ -> nil
      end
    rescue
      _ -> nil
    end

    # Tool names are flat in MCP, so they are namespaced by resource to avoid
    # collisions between two resources with an :approve action.
    defp type_prefix(resource) do
      resource
      |> Module.split()
      |> List.last()
      |> Macro.underscore()
    end

    # Move session focus to the record a resources/read addressed, if it
    # resolves to a known resource. A nil session id (a stateless client) or an
    # unresolvable URI is a no-op — focus is an optimisation, never a
    # correctness requirement.
    defp maybe_focus(nil, _uri, _resources), do: :ok

    defp maybe_focus(session_id, uri, resources) do
      case Resources.locate(uri, resources) do
        {:ok, resource, id} -> Session.focus(session_id, resource, id)
        {:error, _} -> :ok
      end
    end

    defp session_id(conn) do
      case Plug.Conn.get_req_header(conn, "mcp-session-id") do
        [session_id | _] -> session_id
        [] -> nil
      end
    end
  end
end
