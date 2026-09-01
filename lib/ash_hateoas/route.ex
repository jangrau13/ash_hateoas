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

  # `:related` and `:relationship` are navigation — a way to reach other records
  # — rather than something a client invokes. They carry `:id` like any member
  # route, so they have to be named rather than sorted by shape.
  @navigation [:related, :relationship]

  @doc """
  Whether a route addresses **one record**, rather than the collection.

  Read from the path, because the path is the fact. It used to be read from
  `type`, on the reading that `:get`/`:patch`/`:delete` address a record and
  `:index`/`:post` address the collection — which held only while an action's
  kind and its URL agreed. They stopped agreeing when a named sub-action became
  a `POST`: `/exam/:id/open_sitting` is a `:post` that plainly addresses one
  exam, and every reader sorting by kind filed it under the collection.

  `:id` in the pattern is the whole test, and it is the same one
  `AshHateoas.Hydra.ApiDocumentation` already used to decide which operations
  can answer 404 — a route that can 404 on a missing record is a route that
  names one.

      iex> AshHateoas.Route.member?(%AshHateoas.Route{type: :post, route: "/exam/:id/sit"})
      true

      iex> AshHateoas.Route.member?(%AshHateoas.Route{type: :post, route: "/exam"})
      false
  """
  @spec member?(t() | map()) :: boolean()
  def member?(%{route: route}) when is_binary(route), do: String.contains?(route, ":id")
  def member?(_route), do: false

  @doc """
  Whether a route is navigation rather than an affordance.

  A relationship route reaches other records; nothing is invoked against it, so
  it is neither a member operation nor a collection one.
  """
  @spec navigation?(t() | map()) :: boolean()
  def navigation?(%{type: type}), do: type in @navigation
  def navigation?(_route), do: false
end
