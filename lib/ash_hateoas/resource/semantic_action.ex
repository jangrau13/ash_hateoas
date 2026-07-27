defmodule AshHateoas.Resource.SemanticAction do
  @moduledoc """
  Maps one of a resource's actions to a well-known Action-type IRI.

  So a resource can sharpen a state transition beyond its CRUD type — declaring
  that its `:confirm` action is a `https://schema.org/ConfirmAction` rather than
  the generic `UpdateAction` inferred from its `:update` type. The mapping is
  surfaced as the `@type` of the operation's `schema:potentialAction`, letting a
  schema.org-aware client (search engine, assistant) understand the *verb*, not
  only the noun.

  Only an override is ever needed: an unmapped action's `potentialAction` type is
  inferred from the action's CRUD type (read → `ReadAction`, create →
  `CreateAction`, update → `UpdateAction`, destroy → `DeleteAction`, generic →
  `Action`). The name is never guessed — a finer subtype is opt-in.

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
