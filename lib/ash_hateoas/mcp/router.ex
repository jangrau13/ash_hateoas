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
    alias AshHateoas.Mcp.{Session, Tools}

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

    defp session_id(conn) do
      case Plug.Conn.get_req_header(conn, "mcp-session-id") do
        [session_id | _] -> session_id
        [] -> nil
      end
    end
  end
end
