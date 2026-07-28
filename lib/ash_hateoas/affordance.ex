defmodule AshHateoas.Affordance do
  @moduledoc """
  One action a client may take next.

  The envelope the backbone returns is a map of action name → `%Affordance{}`.
  Only the **set** of actions is dynamic — resolved per record, actor and state
  at runtime. Everything below the key is fixed:

    * `name` — the action name; also the key in the envelope
    * `href` — from the declared route, or an author's `override`
    * `method` — the HTTP verb the route declares (`:get`, `:post`, …)
    * `description` — the action's own `description`, surfaced verbatim
    * `fields` — `AshHateoas.Field` structs, one per public argument
    * `not_delegable?` — optional flag: only a committing credential may execute
      this action. Declared, so it reads the same for every actor; what
      varies is whether the endpoint commits.

  The Hydra renderer MUST NOT emit structurally different affordances across
  records.
  """

  alias AshHateoas.Field

  @type t :: %__MODULE__{
          name: atom(),
          href: String.t() | nil,
          method: atom(),
          description: String.t() | nil,
          fields: [Field.t()],
          not_delegable?: boolean()
        }

  defstruct [
    :name,
    :href,
    :method,
    :description,
    fields: [],
    not_delegable?: false
  ]
end