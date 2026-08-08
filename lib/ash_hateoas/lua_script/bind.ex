defmodule AshHateoas.LuaScript.Bind do
  @moduledoc """
  One name a script may reference, and the resource it resolves to.

      bind :author, MyApp.People.Author

  The name becomes a Lua subscript — `author["Ada Lovelace"]` — and the
  resource is what such a reference resolves against. Binding is what makes a
  reference *checkable*: a name nothing binds is a parse error rather than a
  string that fails later.

  ## The name is a spelling, not storage

  A bind's name is chosen to read well **inside a formula**, so it may be
  shorter than the resource it points at:

      bind :var, MyApp.Simulation.Variable    # var["MI_Li"] * 2

  The generated citation column is named after the **resource** — `variable_id`
  — and does not move when the subscript does. That separation is deliberate:
  when the column was derived from the bind name, shortening a subscript for
  readability silently renamed a database column and broke every caller that
  derived the same column from its own notion of the record's kind. A rename
  here should change the text an author types and nothing else.

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
