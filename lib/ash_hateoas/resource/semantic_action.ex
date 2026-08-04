defmodule AshHateoas.Resource.SemanticAction do
  @moduledoc """
  Maps one of a resource's actions to a well-known Action-type IRI.

  So a resource can state what an action is *for* — declaring that its
  `:confirm` action is a `https://schema.org/ConfirmAction`, where its `:update`
  type says only that it writes. The mapping is surfaced as the `@type` of the
  operation's `schema:potentialAction`.

  **This is the only source of a `potentialAction`.** An action without one gets
  none, deliberately: a subtype derived from the HTTP method would restate
  `hydra:method` on the same node, and a role a method already implies states
  nothing. So the declaration is not an *override* of a default — it is the
  whole mechanism, and it exists because an operation's role is the one thing
  Hydra has no term for. A client matching on a declared type rather than on the
  strings `"validate"` and `"save"` keeps working when a domain renames its
  actions.

  The name is never guessed from the action — a role is opt-in.

  `iri` is a bare token (resolved against schema.org — `"ConfirmAction"` →
  `"https://schema.org/ConfirmAction"`) or an absolute IRI (used verbatim).
  """

  @type t :: %__MODULE__{
          action: atom(),
          iri: String.t(),
          __identifier__: any(),
          __spark_metadata__: Spark.Dsl.Entity.spark_meta()
        }

  defstruct [:action, :iri, :__identifier__, :__spark_metadata__]
end
