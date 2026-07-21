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
    alias AshHateoas.Mcp.{Resources, Tools}

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
        {:handled, response, headers} ->
          conn
          |> put_resp_headers(headers)
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(response))

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
      Server.handle_delete(conn, session_id(conn))
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

    # ── Interception ──────────────────────────────────────────────────────────

    defp intercept(%{"method" => "tools/list", "id" => id}, _session_id, conn, opts) do
      {:handled,
       %{
         "jsonrpc" => "2.0",
         "id" => id,
         "result" => %{"tools" => tools(conn, opts)}
       }}
    end

    # ash_ai hardcodes listChanged: false. Rewrite just that flag and leave the
    # rest of its initialize response — protocol version, server info,
    # instructions — exactly as it built it.
    defp intercept(%{"method" => "initialize"} = message, session_id, _conn, opts) do
      case Server.process_message(message, session_id, opts) do
        {:initialize_response, response, new_session_id} ->
          # ash_ai issues the session id here and, in its own handler, sets it
          # as the `mcp-session-id` response header. Because we intercept
          # initialize to rewrite listChanged, we must carry that header
          # ourselves — without it a spec-following client never learns its
          # session id, sends none back, and session focus can never persist.
          {:handled, advertise_list_changed(response), [{"mcp-session-id", new_session_id}]}

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
           _session_id,
           conn,
           opts
         ) do
      domain_resources = resources(opts, Keyword.get(opts, :domain))

      result =
        Resources.read(
          uri,
          domain_resources,
          Ash.PlugHelpers.get_actor(conn),
          # `domain` matters here: the representation embeds the record's own
          # affordances, and the backbone needs the domain to resolve routes.
          domain: Keyword.get(opts, :domain),
          tenant: Ash.PlugHelpers.get_tenant(conn)
        )

      case result do
        {:ok, contents} ->
          # No side effect. A read is safe and idempotent, and the URI in the
          # request already carries the position a session cursor used to hold
          # — the contents include the record's affordances and links, so
          # dereferencing tells the client both what it may do and where it may
          # go, without the server remembering anything.
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

    # Acting on a record hands the agent its onward links (§5.2). ash_ai runs
    # the action; we enrich what it returns.
    #
    # This is the reaction loop without a session: a tool call is the one moment
    # the server knows both WHICH record changed and THAT it changed, so the
    # consequence travels back in the response to the call that caused it. No
    # cursor to update, no notification to push, no polling — the client learns
    # the new state from the same message that reports the write.
    #
    # A third party's change is NOT covered by this and cannot be: the client
    # re-reads, exactly as a JSON:API client re-GETs.
    defp intercept(
           %{
             "method" => "tools/call",
             "id" => id,
             "params" => %{"name" => tool_name, "arguments" => arguments}
           },
           _session_id,
           conn,
           opts
         )
         when is_map(arguments) and is_binary(tool_name) do
      actor = Ash.PlugHelpers.get_actor(conn)
      tenant = Ash.PlugHelpers.get_tenant(conn)

      context = %{
        actor: actor,
        tenant: tenant,
        context: Ash.PlugHelpers.get_context(conn) || %{}
      }

      case execute(tool_name, arguments, context, opts) do
        {:ok, text, resource, record} ->
          {:handled,
           %{
             "jsonrpc" => "2.0",
             "id" => id,
             "result" => %{
               "isError" => false,
               "content" =>
                 [%{"type" => "text", "text" => text}] ++
                   onward_links(resource, record, actor, tenant, opts)
             }
           }}

        {:error, :unknown_tool} ->
          {:handled,
           %{
             "jsonrpc" => "2.0",
             "id" => id,
             "error" => %{"code" => -32602, "message" => "Tool not found: #{tool_name}"}
           }}

        {:error, text} ->
          {:handled,
           %{
             "jsonrpc" => "2.0",
             "id" => id,
             "result" => %{
               "isError" => true,
               "content" => [%{"type" => "text", "text" => to_string(text)}]
             }
           }}
      end
    end

    defp intercept(_message, _session_id, _conn, _opts), do: :delegate

    # Run the action a tool names.
    #
    # ash_ai's `tools/call` resolves names through `AshAi.Info.tools/1`, which
    # reads an `ai do ... end` DSL block — so an action only becomes callable if
    # an author declared it. That is the opposite of R1: we derive every routed
    # action, so delegating would advertise tools that answer "Tool not found".
    #
    # `AshAi.Tools.execute/3` takes a plain `%AshAi.Tool{}` struct and never
    # asks where it came from, so we build one from the affordance and keep
    # ash_ai's argument coercion, action running and error formatting. Discovery
    # is ours; execution stays theirs.
    defp execute(tool_name, arguments, context, opts) do
      with {:ok, resource, action_name} <- resolve(tool_name, opts),
           {:ok, action} <- fetch_action(resource, action_name) do
        tool = %AshAi.Tool{
          name: String.to_atom(tool_name),
          resource: resource,
          action: action,
          domain: Ash.Resource.Info.domain(resource),
          # nil means "the primary key", read from the TOP-LEVEL arguments —
          # which is exactly where `Tools.render/3` pins the subject as a
          # `const`, so an update or destroy finds its record.
          identity: nil,
          arguments: [],
          load: []
        }

        case AshAi.Tools.execute(tool, arguments, context) do
          {:ok, text, record} -> {:ok, text, resource, record}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    defp fetch_action(resource, action_name) do
      case Ash.Resource.Info.action(resource, action_name) do
        nil -> {:error, :unknown_tool}
        action -> {:ok, action}
      end
    end

    # Tool names are `<type_prefix>_<action>`, so the longest matching prefix
    # identifies the resource. Longest wins: `order_line` must not resolve as
    # `order` when both exist.
    defp resolve(tool_name, opts) do
      opts
      |> resources(Keyword.get(opts, :domain))
      |> Enum.filter(&String.starts_with?(tool_name, type_prefix(&1) <> "_"))
      |> Enum.max_by(&String.length(type_prefix(&1)), fn -> nil end)
      |> case do
        nil ->
          {:error, :unknown_tool}

        resource ->
          prefix = type_prefix(resource) <> "_"
          action = String.replace_prefix(tool_name, prefix, "")

          {:ok, resource, String.to_existing_atom(action)}
      end
    rescue
      # String.to_existing_atom raises for a name no action ever used.
      _ -> {:error, :unknown_tool}
    end

    # Acting on a record hands the agent its onward links (§5.2).
    #
    # The record comes straight from execution, so there is no reload and no
    # guessing which record was touched — a create is covered too, which the
    # arguments alone could not have told us.
    #
    # A collection-level result (a read returning many, or a generic action with
    # no record) gets no link: there is no single record to point at.
    defp onward_links(resource, %{__struct__: resource} = record, actor, tenant, opts) do
      uri = Resources.uri(resource, primary_key(resource, record))

      affordances =
        AshHateoas.affordances(record, actor,
          domain: Keyword.get(opts, :domain),
          tenant: tenant
        )

      [
        %{
          "type" => "resource_link",
          "uri" => uri,
          "name" => uri,
          "mimeType" => "application/json",
          "description" => onward_description(affordances),
          # The spec sanctions this exact case: "Resource links returned by
          # tools are not guaranteed to appear in the results of a
          # resources/list request." The link is for the model, not the user,
          # and it is the most important thing in the result — without it the
          # agent does not learn that its action changed what it may do next.
          "annotations" => %{"audience" => ["assistant"], "priority" => 0.9}
        }
      ]
    rescue
      # Enrichment must never lose a result whose action already ran.
      _ -> []
    end

    defp onward_links(_resource, _record, _actor, _tenant, _opts), do: []

    # What the agent may do NEXT, named. The link alone says "re-read this";
    # naming the affordances means the agent knows whether that is worth a
    # round trip.
    defp onward_description(affordances) when map_size(affordances) == 0 do
      "No further actions are available on this record."
    end

    defp onward_description(affordances) do
      names = affordances |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &to_string/1)

      "Now available on this record: #{names}."
    end

    defp primary_key(resource, record) do
      case Ash.Resource.Info.primary_key(resource) do
        [key] -> Map.get(record, key)
        keys -> keys |> Enum.map(&Map.get(record, &1)) |> Enum.join(",")
      end
    end

    defp advertise_list_changed(response) when is_binary(response) do
      response
      |> Jason.decode!()
      |> update_in(
        ["result", "capabilities", "tools"],
        &Map.put(&1 || %{}, "listChanged", true)
      )
    end

    # Collection-level affordances across the domain, for every client alike.
    #
    # `tools/list` carries no reference to a record, so there is nothing in the
    # request that could scope this to one — and inferring a scope from what the
    # client read earlier would mean holding a position across requests, which
    # is the cookie shape Fielding's second constraint rules out. The list is
    # therefore the collection-level surface, the direct analogue of a JSON:API
    # collection's top-level `links`.
    #
    # A record's own affordances live in its representation, reached by
    # dereferencing its URI with `resources/read`.
    defp tools(conn, opts) do
      collection_tools(
        opts,
        Ash.PlugHelpers.get_actor(conn),
        Ash.PlugHelpers.get_tenant(conn),
        Keyword.get(opts, :domain)
      )
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


    # Tool names are flat in MCP, so they are namespaced by resource to avoid
    # collisions between two resources with an :approve action.
    defp type_prefix(resource) do
      resource
      |> Module.split()
      |> List.last()
      |> Macro.underscore()
    end

    defp put_resp_headers(conn, headers) do
      Enum.reduce(headers, conn, fn
        {_key, nil}, acc -> acc
        {key, value}, acc -> Plug.Conn.put_resp_header(acc, key, value)
      end)
    end

    defp session_id(conn) do
      case Plug.Conn.get_req_header(conn, "mcp-session-id") do
        [session_id | _] -> session_id
        [] -> nil
      end
    end
  end
end
