defmodule AshHateoas.Resource.Override do
  @moduledoc """
  A deviation from an action's derived affordance.

  Currently only `href` may be overridden — the derived value comes from the
  action's declared route, and an author occasionally needs a different path.
  """

  @type t :: %__MODULE__{
          action: atom(),
          href: String.t() | nil,
          __identifier__: any(),
          __spark_metadata__: Spark.Dsl.Entity.spark_meta()
        }

  defstruct [:action, :href, :__identifier__, :__spark_metadata__]
end
