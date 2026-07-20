defmodule AshHateoas.Mcp.Session do
  @moduledoc """
  Tracks each MCP session's current position (§5.2).

  MCP is a stateful connection, and the affordance set depends on *where the
  session is* — which record is in focus. A session with no record in focus gets
  collection-level affordances, which is the cold-start case.

  Backed by an ETS table owned by this process. Sessions are dropped when the
  connection ends, and the table is public so the router's request processes can
  read and write without a GenServer round trip on every `tools/list`.
  """

  use GenServer

  @table __MODULE__

  @type position :: %{resource: module(), id: term()} | nil

  # ── Client ──────────────────────────────────────────────────────────────────

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record which record a session is working on.

  Called after a tool runs, so the next `tools/list` reflects the new position.
  """
  @spec focus(String.t(), module(), term()) :: :ok
  def focus(session_id, resource, id) when is_binary(session_id) do
    ensure_table()
    :ets.insert(@table, {session_id, %{resource: resource, id: id}})
    :ok
  end

  @doc "The record a session is working on, or `nil` for the cold-start case."
  @spec position(String.t() | nil) :: position()
  def position(nil), do: nil

  def position(session_id) do
    ensure_table()

    case :ets.lookup(@table, session_id) do
      [{^session_id, position}] -> position
      [] -> nil
    end
  end

  @doc "Clear a session's position, returning it to the cold-start case."
  @spec clear(String.t() | nil) :: :ok
  def clear(nil), do: :ok

  def clear(session_id) do
    ensure_table()
    :ets.delete(@table, session_id)
    :ok
  end

  # ── Server ──────────────────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    ensure_table()
    {:ok, %{}}
  end

  # The table is created on demand so the store works whether or not the host
  # app supervises this process — a library must not require supervision to be
  # correct, only to be tidy.
  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _reference ->
        @table
    end
  rescue
    ArgumentError -> @table
  end
end
