defmodule AshHateoas.Route do
  @moduledoc """
  A package-owned, transport-neutral route.

  Route derivation persists these structs, and the backbone reads them to learn
  each affordance's `href` and `method`. Owning the route model here is what
  lets the package serve Hydra directly.

  The field set carries exactly what the backbone and navigation need:

    * `type` — the route kind: `:get`, `:index`, `:post`, `:patch`, `:delete`,
      `:route` (a generic action, method carried as data), or the relationship
      kinds `:related` / `:relationship`.
    * `method` — the HTTP verb. `nil` for the verb-implied kinds (`:get` is GET,
      `:post` is POST, …); set explicitly only for `:route`.
    * `route` — the path, with `:id`-style params (`"/:id/approve"`).
    * `action` — the Ash action name this route exposes.
    * `relationship` — the relationship name, for `:related` / `:relationship`.
    * `primary?` — marks the canonical `:get`, so a record knows its own `@id`.
  """

  @type kind ::
          :get | :index | :post | :patch | :delete | :route | :related | :relationship

  @type t :: %__MODULE__{
          type: kind(),
          method: atom() | nil,
          route: String.t() | nil,
          action: atom() | nil,
          relationship: atom() | nil,
          primary?: boolean()
        }

  defstruct [
    :type,
    :method,
    :route,
    :action,
    :relationship,
    primary?: false
  ]
end
