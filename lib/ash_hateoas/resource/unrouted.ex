defmodule AshHateoas.Resource.Unrouted do
  @moduledoc """
  An action that must not be given an HTTP route.

  Distinct from `AshHateoas.Resource.Exclusion`, which withholds an action from
  *advertisement* while leaving it routed and callable. This withholds the route
  itself, so the action is not reachable over HTTP at all.

  The two compose in one direction only: unrouted implies unadvertised, since
  affordances derive from routes. Excluding an action that is also unrouted is
  redundant rather than wrong.
  """

  @type t :: %__MODULE__{
          action: atom(),
          __identifier__: any(),
          __spark_metadata__: Spark.Dsl.Entity.spark_meta()
        }

  defstruct [:action, :__identifier__, :__spark_metadata__]
end
