defmodule AshHateoas.LuaScript.Info do
  @moduledoc """
  Reads the `lua` section: which attribute holds a script, what a script may
  reference, and where the callable functions live.

  Every accessor answers for a resource that does not carry
  `AshHateoas.LuaScript` too — `nil` or `[]` — so a caller never has to check
  for the extension first.
  """

  alias AshHateoas.LuaScript.Bind

  @doc """
  Whether this resource declares a script attribute.
  """
  @spec script?(Ash.Resource.t() | map()) :: boolean()
  def script?(resource_or_dsl), do: not is_nil(script(resource_or_dsl))

  @doc """
  The attribute holding the source, or `nil`.
  """
  @spec script(Ash.Resource.t() | map()) :: atom() | nil
  def script(resource_or_dsl), do: opt(resource_or_dsl, :script)

  @doc """
  The resource whose records are the callable functions, or `nil`.

  A domain with no functions declares none, and a script that calls anything is
  then refused — which is the honest default: an unchecked call is a failure
  deferred to whoever reads the script next.
  """
  @spec functions(Ash.Resource.t() | map()) :: module() | nil
  def functions(resource_or_dsl), do: opt(resource_or_dsl, :functions)

  @doc """
  Every `bind` declared, in the order written.
  """
  @spec binds(Ash.Resource.t() | map()) :: [Bind.t()]
  def binds(resource_or_dsl) do
    resource_or_dsl
    |> entities()
    |> Enum.filter(&match?(%Bind{}, &1))
  end

  @doc """
  The binds as a map keyed by the Lua subscript, which is how a walk over the
  AST asks whether a name means anything.
  """
  @spec bind_map(Ash.Resource.t() | map()) :: %{atom() => Bind.t()}
  def bind_map(resource_or_dsl) do
    resource_or_dsl
    |> binds()
    |> Map.new(&{&1.name, &1})
  end

  defp opt(resource_or_dsl, key) do
    Spark.Dsl.Extension.get_opt(resource_or_dsl, [:lua], key, nil)
  rescue
    # A module still compiling, or one that is not a Spark module at all.
    # Neither declares a script, and neither is worth raising over.
    _ -> nil
  end

  defp entities(resource_or_dsl) do
    Spark.Dsl.Extension.get_entities(resource_or_dsl, [:lua]) || []
  rescue
    _ -> []
  end
end
