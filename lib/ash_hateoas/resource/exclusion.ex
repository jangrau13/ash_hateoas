defmodule AshHateoas.Resource.Exclusion do
  @moduledoc """
  An action that is routed but must not be advertised.

  The DSL is override-only: there are no per-action "enable" entries, because
  everything routed is advertised by default. An exclusion is the deviation.
  """

  @type t :: %__MODULE__{
          action: atom(),
          __identifier__: any(),
          __spark_metadata__: Spark.Dsl.Entity.spark_meta()
        }

  defstruct [:action, :__identifier__, :__spark_metadata__]
end
