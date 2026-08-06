defmodule AshHateoas.Field do
  @moduledoc """
  A single input a client may supply when invoking an affordance.

  Fields derive from an action's **public** arguments. The shape is fixed and
  transport-neutral — the Hydra renderer projects each field as a
  `hydra:SupportedProperty` on its operation — so changing it is a breaking
  change for every client reading affordances.

  ## Sensitive arguments

  A `sensitive?` argument still becomes a field — the client must know to supply
  it — but its `default` is **never** emitted.

  `default` is `{:ok, value} | :error` rather than a bare value because `nil` is
  itself a legitimate default: a plain `nil` could not distinguish "defaults to
  nil" from "has no default". `:error` means no default reaches the wire, either
  because the argument has none or because it is sensitive.

  ## `allow_nil?` mirrors Ash

  This field carries Ash's own name and polarity rather than the wire format's
  `required`. The Hydra renderer inverts it at the edge — a
  `hydra:SupportedProperty` is described by `hydra:required` — so the inversion
  lives at the boundary, and everything upstream reads the way the resource DSL
  does.

  ## `script_language` is carried, not re-derived

  `type` collapses an Ash type to a wire name, and `"script"` says the value is
  source code without saying in what. The language cannot be recovered further
  downstream: an argument is not a property of any class, so the ontology
  declares no range for it and there is nothing to look it up in.

  So it is read here, where the Ash type is still in hand, and travels beside
  the type it qualifies. `nil` for anything that is not a script — which is the
  reason it is a field rather than a constraint: it says what the value *is*,
  not what it must satisfy.
  """

  @type t :: %__MODULE__{
          name: atom(),
          type: String.t(),
          allow_nil?: boolean(),
          description: String.t() | nil,
          default: {:ok, term()} | :error,
          constraints: map(),
          script_language: String.t() | nil
        }

  defstruct [
    :name,
    :type,
    :description,
    :script_language,
    allow_nil?: true,
    default: :error,
    constraints: %{}
  ]
end
