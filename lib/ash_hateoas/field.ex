defmodule AshHateoas.Field do
  @moduledoc """
  A single input a client may supply when invoking an affordance (R4, R5).

  Fields derive from an action's **public** arguments. The shape is fixed:
  every transport projects from it (JSON:API renders them as `meta.fields`, MCP
  as the tool's `inputSchema`), so changing it is a breaking change for every
  client reading affordances.

  ## Sensitive arguments

  A `sensitive?` argument still becomes a field — the client must know to supply
  it — but its `default` is **never** emitted.

  `default` is `{:ok, value} | :error` rather than a bare value because `nil` is
  itself a legitimate default: a plain `nil` could not distinguish "defaults to
  nil" from "has no default". `:error` means no default reaches the wire, either
  because the argument has none or because it is sensitive.

  ## Why `required` and not `allow_nil?`

  Ash spells this `allow_nil?`, and mirroring the framework is usually right.
  This struct is deliberately different because it is a **wire format**, not a
  resource DSL: JSON Schema, HAL-FORMS and MCP's `inputSchema` all say
  `required`, with the opposite polarity. Naming it `allow_nil?` here would make
  every renderer invert the field on the way out — the surprise belongs in the
  one place that reads the Ash DSL, not in all of them.
  """

  @type t :: %__MODULE__{
          name: atom(),
          type: String.t(),
          required: boolean(),
          description: String.t() | nil,
          default: {:ok, term()} | :error,
          constraints: map()
        }

  defstruct [
    :name,
    :type,
    :description,
    required: false,
    default: :error,
    constraints: %{}
  ]
end
