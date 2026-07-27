defmodule AshHateoas.Resource.NotDelegable do
  @moduledoc """
  An action a delegated credential may be offered but must not execute.

  Distinct from every other entry in this package's DSL, which subtract from the
  advertised surface. This one subtracts nothing: the action stays routed, stays
  advertised, and carries a flag saying it will be refused unless the requesting
  credential is one that commits.

  That is the point. Withholding the action instead — by policy, or by
  `AshHateoas.Resource.Exclusion` — leaves a delegated actor unable to tell
  "this does not exist" from "you may propose this but not do it", and so unable
  to ask anyone for it.
  """

  @type t :: %__MODULE__{
          action: atom(),
          __identifier__: any(),
          __spark_metadata__: Spark.Dsl.Entity.spark_meta()
        }

  defstruct [:action, :__identifier__, :__spark_metadata__]
end
