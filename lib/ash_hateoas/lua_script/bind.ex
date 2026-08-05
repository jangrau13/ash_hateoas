defmodule AshHateoas.LuaScript.Bind do
  @moduledoc """
  One name a script may reference, and the resource it resolves to.

      bind :author, MyApp.People.Author

  The name becomes a Lua subscript — `author["Ada Lovelace"]` — and the
  resource is what such a reference resolves against. Binding is what makes a
  reference *checkable*: a name nothing binds is a parse error rather than a
  string that fails later.

  `key` names the attribute a subscript matches on, defaulting to `:name`. It is
  the resource's own naming key, the same one `ah:identity` publishes, so a
  script cites what a client can already write.
  """

  @type t :: %__MODULE__{
          name: atom(),
          resource: module(),
          key: atom(),
          __identifier__: any(),
          __spark_metadata__: Spark.Dsl.Entity.spark_meta()
        }

  defstruct [:name, :resource, :key, :__identifier__, :__spark_metadata__]
end
