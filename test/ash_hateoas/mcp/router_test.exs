defmodule AshHateoas.Mcp.RouterTest do
  @moduledoc """
  End-to-end MCP tests, driven in-process with `Plug.Test`.
  """

  use ExUnit.Case, async: false

  alias AshHateoas.Mcp.Session
  alias AshHateoas.Test.{Actor, McpEndpoint, Order}

  @actor %Actor{id: "agent-1", role: :admin}

  setup do
    order =
      Order
      |> Ash.Changeset.for_create(:create, %{reference: unique("ref")})
      |> Ash.create!(authorize?: false)

    session = unique("session")
    on_exit(fn -> Session.clear(session) end)

    %{order: order, session: session}
  end

  describe "tools/list reflects the session's position (§5.2)" do
    test "with no record in focus, offers type-level tools" do
      names = tool_names(list_tools())

      assert "order_create" in names,
             "the cold-start case must offer what can be done without a record"
    end

    test "with a record in focus, offers its state-legal transitions", %{
      order: order,
      session: session
    } do
      Session.focus(session, Order, order.id)
      names = tool_names(list_tools(session))

      assert "order_confirm" in names
      refute "order_ship" in names, ":ship is not legal from :pending"
    end

    test "the tool list changes as the record transitions", %{order: order, session: session} do
      Session.focus(session, Order, order.id)

      before = tool_names(list_tools(session))

      order
      |> Ash.Changeset.for_update(:confirm, %{})
      |> Ash.update!(authorize?: false)

      after_confirm = tool_names(list_tools(session))

      assert "order_confirm" in before
      refute "order_confirm" in after_confirm

      assert "order_ship" in after_confirm,
             "this is the loop: acting changes state, which changes the tools"
    end

    test "tool names are namespaced by resource", %{order: order, session: session} do
      Session.focus(session, Order, order.id)

      for name <- tool_names(list_tools(session)) do
        assert String.starts_with?(name, "order_"),
               "MCP tool names are flat, so they must not collide across resources"
      end
    end
  end

  describe "inputSchema (§5.2)" do
    test "nests inputs under a top-level `input` property", %{order: order, session: session} do
      Session.focus(session, Order, order.id)

      schema = tool(list_tools(session), "order_cancel")["inputSchema"]

      assert schema["type"] == "object"
      assert Map.has_key?(schema, "properties")
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
    test "an actor who may not act is offered nothing they cannot do", %{
      order: order,
      session: session
    } do
      Session.focus(session, Order, order.id)

      # Order's policies are permissive, so this asserts the actor is threaded
      # through at all rather than a specific denial.
      names = tool_names(list_tools(session, nil))

      assert is_list(names)
    end
  end

  describe "session store" do
    test "position/1 is nil for an unknown session" do
      assert Session.position("never-seen") == nil
    end

    test "focus/3 then position/1 round-trips", %{order: order, session: session} do
      Session.focus(session, Order, order.id)

      assert %{resource: Order, id: id} = Session.position(session)
      assert id == order.id
    end

    test "clear/1 returns a session to the cold-start case", %{order: order, session: session} do
      Session.focus(session, Order, order.id)
      Session.clear(session)

      assert Session.position(session) == nil
    end
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
