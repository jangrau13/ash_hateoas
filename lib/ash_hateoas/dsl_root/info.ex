defmodule AshHateoas.DslRoot.Info do
  @moduledoc """
  Whether a resource is a DSL root.

  There is no option to read: carrying `AshHateoas.DslRoot` *is* the
  declaration. A boolean inside the extension would have to be `true` for the
  extension to do anything at all, so it said the same thing twice and could
  only be set to the one value that was not a mistake.
  """

  @doc """
  Whether this resource is the aggregate root — the thing a client authors,
  validates and saves as one document.

  Returns `false` for a resource that does not carry `AshHateoas.DslRoot`, so a
  caller never has to check for the extension first.

  Accepts a resource module or a DSL state, so a transformer can ask before the
  module exists.
  """
  @spec root?(Ash.Resource.t() | map()) :: boolean()
  def root?(resource_or_dsl) do
    AshHateoas.DslRoot in Spark.extensions(resource_or_dsl)
  rescue
    # A resource still compiling, or something that is not a Spark module at
    # all. Neither is a root, and neither is worth raising over.
    _ -> false
  end
end
