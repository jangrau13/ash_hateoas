defmodule AshHateoas.Resource.Method do
  @moduledoc """
  The HTTP method to route a generic action under.

  Generic actions are the one action kind whose verb cannot be derived: `action
  :tally, :boolean` says nothing about whether it reads or writes. POST is
  assumed, because it understates nothing — a client may not cache it or retry
  it blindly. This is how an author who knows better corrects it.

      hateoas do
        method :tally, :get
      end
  """

  @type t :: %__MODULE__{
          action: atom(),
          method: atom(),
          __identifier__: any(),
          __spark_metadata__: Spark.Dsl.Entity.spark_meta()
        }

  defstruct [:action, :method, :__identifier__, :__spark_metadata__]
end
