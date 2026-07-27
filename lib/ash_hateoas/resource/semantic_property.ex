defmodule AshHateoas.Resource.SemanticProperty do
  @moduledoc """
  Maps one of a resource's attributes to a well-known property IRI.

  So a resource can advertise, say, that its `:additional_name` attribute is
  `https://schema.org/additionalName` — letting a client that knows schema.org
  read the value semantically rather than only by the API-local property IRI.

  `iri` is a bare token (resolved against schema.org — `"additionalName"` →
  `"https://schema.org/additionalName"`) or an absolute IRI (used verbatim).
  """

  @type t :: %__MODULE__{
          attribute: atom(),
          iri: String.t(),
          __identifier__: any(),
          __spark_metadata__: Spark.Dsl.Entity.spark_meta()
        }

  defstruct [:attribute, :iri, :__identifier__, :__spark_metadata__]
end
