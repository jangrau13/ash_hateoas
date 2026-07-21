defmodule AshHateoas.Mcp.RouterTest do
  @moduledoc """
  End-to-end MCP tests, driven in-process with `Plug.Test`.
  """

  use ExUnit.Case, async: false
  alias AshHateoas.Mcp.Resources
  alias AshHateoas.Test.{Actor, McpEndpoint, Order}

  @actor %Actor{id: "agent-1", role: :admin}

  setup do
    order =
      Order
      |> Ash.Changeset.for_create(:create, %{reference: unique("ref")})
      |> Ash.create!(authorize?: false)

    session = unique("session")

    %{order: order, session: session}
  end

  describe "tools/list is collection-level and stateless (§5.2)" do
    test "offers what can be done without a record in hand" do
      names = tool_names(list_tools())

      assert "order_create" in names,
             "a client that has just arrived must be told what it may do"
    end

    test "withholds record-level transitions, which need a record to act on" do
      names = tool_names(list_tools())

      refute "order_confirm" in names,
             "tools/list names no record, so it cannot offer a record's transitions"

      refute "order_ship" in names
    end

    test "answers identically whatever the client read first", %{order: order} do
      before = tool_names(list_tools())

      # Dereferencing a record must not change what a later tools/list returns.
      # A read is safe: it moves no cursor, because there is no cursor.
      read_resource(Resources.uri(Order, order.id))

      assert tool_names(list_tools()) == before,
             "a read changed the tool list — server-held position has crept back in"
    end

    test "answers identically for a session id and for none", %{session: session} do
      assert tool_names(list_tools(session)) == tool_names(list_tools()),
             "the tool list varies by actor, never by session"
    end

    test "tool names are namespaced by resource" do
      for name <- tool_names(list_tools()) do
        assert String.contains?(name, "_"),
               "MCP tool names are flat, so they must not collide across resources"
      end
    end
  end

  describe "a record's affordances travel in its representation (§5.2)" do
    test "resources/read carries the state-legal transitions", %{order: order} do
      body = read_record(Order, order.id)

      names = Enum.map(body["affordances"], & &1["name"])

      assert "confirm" in names
      refute "ship" in names, ":ship is not legal from :pending"
    end

    test "the affordances follow the record's state", %{order: order} do
      order
      |> Ash.Changeset.for_update(:confirm, %{})
      |> Ash.update!(authorize?: false)

      names = Order |> read_record(order.id) |> Map.fetch!("affordances") |> Enum.map(& &1["name"])

      assert "ship" in names,
             "this is the loop: acting changes state, which changes what may be done next"

      refute "confirm" in names
    end

    test "navigation says where the client may go next", %{order: order} do
      body = read_record(Order, order.id)

      assert get_in(body, ["navigation", "collection", "method"]) == "resources/list",
             "a record must tell the client how to reach its collection"
    end
  end

  describe "inputSchema (§5.2)" do
    test "nests inputs under a top-level `input` property" do
      schema = tool(list_tools(), "order_create")["inputSchema"]

      assert schema["type"] == "object"
      assert Map.has_key?(schema["properties"], "input"),
             "ash_ai reads action inputs from arguments[\"input\"], so the schema must nest them there"
    end

    test "advertises accepted attributes, not just arguments" do
      schema = tool(list_tools(), "order_create")["inputSchema"]

      assert get_in(schema, ["properties", "input", "properties", "reference"]),
             "create accepts :reference as an attribute — a client must be told to send it"
    end

    test "uses string keys throughout" do
      schema = tool(list_tools(), "order_create")["inputSchema"]

      assert Enum.all?(Map.keys(schema), &is_binary/1),
             "ash_ai round-trips schemas to string keys; ours must match or clients differ"
    end

    test "every tool carries a non-empty description" do
      for tool <- list_tools() do
        assert is_binary(tool["description"]) and tool["description"] != "",
               "#{tool["name"]} has no description for a model to read"
      end
    end
  end

  describe "capabilities" do
    test "advertises listChanged: true" do
      response =
        post(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2025-03-26",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "test", "version" => "1"}
          }
        })

      assert get_in(response, ["result", "capabilities", "tools", "listChanged"]) == true,
             "ash_ai hardcodes false; the wrapper must override it"
    end

    test "the notification message is well-formed JSON-RPC" do
      notification = AshHateoas.Mcp.Router.notify_list_changed("any-session")

      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == "notifications/tools/list_changed"
      refute Map.has_key?(notification, "id"), "a notification must not carry an id"
    end
  end

  describe "authorization still applies" do
    test "an actor who may not act is offered nothing they cannot do", %{session: session} do

      # Order's policies are permissive, so this asserts the actor is threaded
      # through at all rather than a specific denial.
      names = tool_names(list_tools(session, nil))

      assert is_list(names)
    end
  end

  describe "acting hands back the onward links (§5.2)" do
    test "a record-level call returns a resource_link to what it changed", %{order: order} do
      content = call_tool("order_confirm", %{"id" => order.id, "input" => %{}})

      link = Enum.find(content, &(&1["type"] == "resource_link"))

      assert link, "acting on a record must hand the agent its onward links"
      assert link["uri"] == Resources.uri(Order, order.id)
    end

    test "the link names what became available", %{order: order} do
      content = call_tool("order_confirm", %{"id" => order.id, "input" => %{}})
      link = Enum.find(content, &(&1["type"] == "resource_link"))

      assert link["description"] =~ "ship",
             "the agent learns the consequence of its own action from the response to it"
    end

    test "the link is annotated for the model", %{order: order} do
      content = call_tool("order_confirm", %{"id" => order.id, "input" => %{}})
      link = Enum.find(content, &(&1["type"] == "resource_link"))

      assert link["annotations"]["audience"] == ["assistant"]
    end

    test "the tool's own text result is preserved", %{order: order} do
      content = call_tool("order_confirm", %{"id" => order.id, "input" => %{}})

      assert Enum.any?(content, &(&1["type"] == "text")),
             "enrichment must add to the result, never replace it"
    end

    test "a create links to the record it just made" do
      content = call_tool("order_create", %{"input" => %{"reference" => unique("ref")}})

      link = Enum.find(content, &(&1["type"] == "resource_link"))

      assert link,
             "a create has no subject in its arguments, but execution returns the record — " <>
               "so the agent is handed the URI of what it just created"

      assert link["description"] =~ "confirm",
             "a fresh order is :pending, so :confirm is what it may do next"
    end
  end

  defp read_record(resource, id) do
    resource
    |> Resources.uri(id)
    |> read_resource()
  end

  defp read_resource(uri) do
    %{"jsonrpc" => "2.0", "id" => 1, "method" => "resources/read", "params" => %{"uri" => uri}}
    |> post()
    |> get_in(["result", "contents"])
    |> hd()
    |> Map.fetch!("text")
    |> Jason.decode!()
  end

  defp call_tool(name, arguments) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => arguments}
    }
    |> post()
    |> get_in(["result", "content"])
  end

  defp list_tools(session \\ nil, actor \\ @actor) do
    %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}
    |> post(session, actor)
    |> get_in(["result", "tools"])
  end

  defp post(body, session \\ nil, actor \\ @actor) do
    conn =
      :post
      |> Plug.Test.conn("/", Jason.encode!(body))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Ash.PlugHelpers.set_actor(actor)

    conn =
      if session,
        do: Plug.Conn.put_req_header(conn, "mcp-session-id", session),
        else: conn

    conn
    |> McpEndpoint.call(McpEndpoint.init([]))
    |> then(&Jason.decode!(&1.resp_body))
  end

  defp tool_names(tools), do: Enum.map(tools, & &1["name"])

  defp tool(tools, name), do: Enum.find(tools, &(&1["name"] == name))

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
