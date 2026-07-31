defmodule AshHateoas.Resource.Observable do
  @moduledoc """
  Declares part of this resource observable, so a subscriber can be told when it
  changes.

      hateoas do
        observable :resource
        observable :collection
        observable :name
      end

  Two subjects are reserved:

    * `:resource` — the member topic (a record's canonical URL). Fires when a
      routed update or destroy changes that record.
    * `:collection` — the collection topic (the type's canonical index URL).
      Fires when a routed create or destroy changes the set.

  Any other subject names an attribute and derives a property-level topic — the
  member URL plus `?observe=<attribute>` — which fires only when a routed update
  actually changes that attribute, so a subscriber is not woken by unrelated
  writes.

  The declaration is transport-neutral: `DeriveObservables` turns it into
  `AshHateoas.Observable` specs, and a transport package (e.g. `ash_websub`)
  reads those specs and publishes. With no transport installed the declaration
  is inert.
  """

  @type t :: %__MODULE__{
          subject: :resource | :collection | atom(),
          __identifier__: any(),
          __spark_metadata__: Spark.Dsl.Entity.spark_meta()
        }

  defstruct [:subject, :__identifier__, :__spark_metadata__]
end
