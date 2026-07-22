defmodule AshHateoas.Field do
  @moduledoc """
  A single input a client may supply when invoking an affordance (R4, R5).

  Fields derive from an action's **public** arguments. The shape is fixed and
  transport-neutral — JSON:API renders it as `meta.fields`, and anything else
  built on the profile projects from the same structure — so changing it is a
  breaking change for every client reading affordances.

  ## Sensitive arguments

  A `sensitive?` argument still becomes a field — the client must know to supply
  it — but its `default` is **never** emitted.

  `default` is `{:ok, value} | :error` rather than a bare value because `nil` is
  itself a legitimate default: a plain `nil` could not distinguish "defaults to
  nil" from "has no default". `:error` means no default reaches the wire, either
  because the argument has none or because it is sensitive.

  ## `allow_nil?` mirrors Ash

  This field carries Ash's own name and polarity rather than the wire format's
  `required`. Renderers invert it at the edge — JSON Schema and HAL-FORMS both
  say `required` — so the inversion lives at the boundary, and everything
  upstream reads the way the resource DSL does.
  """

  @type t :: %__MODULE__{
          name: atom(),
          type: String.t(),
          allow_nil?: boolean(),
          description: String.t() | nil,
          default: {:ok, term()} | :error,
          constraints: map()
        }

  defstruct [
    :name,
    :type,
    :description,
    allow_nil?: true,
    default: :error,
    constraints: %{}
  ]
end
