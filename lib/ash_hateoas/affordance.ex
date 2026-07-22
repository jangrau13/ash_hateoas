defmodule AshHateoas.Affordance do
  @moduledoc """
  One action a client may take next (R5).

  The envelope the backbone returns is a map of action name → `%Affordance{}`.
  Only the **set** of actions is dynamic — resolved per record, actor and state
  at runtime. Everything below the key is fixed:

    * `name` — the action name; also the key in the envelope
    * `href` — from the declared route, or an author's `override`
    * `method` — the HTTP verb the route declares (`:get`, `:post`, …)
    * `description` — the action's own `description`, surfaced verbatim (R4)
    * `fields` — `AshHateoas.Field` structs, one per public argument
    * `multi_step?` — optional flag for a compound (e.g. Reactor-backed) operation
    * `not_delegable?` — optional flag: only a committing credential may execute
      this action (R10). Declared, so it reads the same for every actor; what
      varies is whether the endpoint commits.

  Renderers MUST NOT emit structurally different affordances across records or
  transports.
  """

  alias AshHateoas.Field

  @type t :: %__MODULE__{
          name: atom(),
          href: String.t() | nil,
          method: atom(),
          description: String.t() | nil,
          fields: [Field.t()],
          multi_step?: boolean(),
          not_delegable?: boolean()
        }

  defstruct [
    :name,
    :href,
    :method,
    :description,
    fields: [],
    multi_step?: false,
    not_delegable?: false
  ]
end
