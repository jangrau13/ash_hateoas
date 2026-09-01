defmodule AshHateoas.Candidates do
  @moduledoc """
  Builds the candidate action set — stage 1 of the backbone.

  Candidates are the actions reachable via the resource's derived routes, minus
  any the author has excluded. Where a resource declares no routes at all the
  set falls back to the resource's actions directly, so the backbone works even
  before route derivation has run.

  Nothing here does authorization or state reasoning — those are gates.
  """

  alias AshHateoas.Route

  @typedoc "An action paired with the route that exposes it, if any"
  @type candidate :: {struct(), Route.t() | nil}

  @doc """
  Actions reachable for `resource`, as `{action, route}` pairs.

  `route` is `nil` when there is no route for the action — either because
  derivation has not run, or because the action is `unrouted`. An affordance
  without a route still has a name and its fields, which is all a caller reading
  the backbone directly needs; only the `href` is missing.

  `kind` selects which actions are eligible:

    * `:record` — actions that operate on an existing record
    * `:collection` — actions that operate on the type (creates and index reads)

  `_domains` is accepted for call-site compatibility; routes are resource-level.
  """
  @spec for_resource(module(), [module()], :record | :collection) :: [candidate()]
  def for_resource(resource, _domains, kind) do
    routes = routes(resource)

    if routes == [] do
      resource
      |> Ash.Resource.Info.actions()
      |> Enum.filter(&eligible?(&1, kind))
      |> Enum.map(&{&1, nil})
    else
      routes
      |> Enum.filter(&route_matches_kind?(&1, kind))
      |> Enum.flat_map(fn route ->
        case Ash.Resource.Info.action(resource, route.action) do
          nil -> []
          action -> [{action, route}]
        end
      end)
      |> Enum.uniq_by(fn {action, _route} -> action.name end)
    end
  end

  defp routes(resource) do
    AshHateoas.Resource.Info.routes(resource)
  rescue
    _ -> []
  end

  # Which routes address a single existing record, and which the collection.
  #
  # **From the path, not the kind.** The kind lists used to be
  # `[:get, :patch, :delete, :route]` and `[:index, :post, :route]`, and they had
  # two faults. `:route` appeared in both, so a generic action at
  # `/:id/<name>` was offered on a collection that has no id to give it. And the
  # moment a named sub-action became a `POST` — a transition is not a partial
  # modification — every one of them was filed as a collection operation and
  # vanished from the record that offers it.
  #
  # `AshHateoas.Route.member?/1` reads `:id` out of the pattern, which is the
  # fact both lists were approximating.
  defp route_matches_kind?(route, :record),
    do: not Route.navigation?(route) and Route.member?(route)

  defp route_matches_kind?(route, :collection),
    do: not Route.navigation?(route) and not Route.member?(route)

  defp route_matches_kind?(_route, _kind), do: false

  # Fallback shape, used only when no routes are declared.
  defp eligible?(%{type: :create}, :collection), do: true
  defp eligible?(%{type: :read}, :collection), do: true
  defp eligible?(%{type: :action}, :collection), do: true
  defp eligible?(%{type: type}, :record) when type in [:update, :destroy, :action], do: true
  defp eligible?(%{type: :read}, :record), do: true
  defp eligible?(_action, _kind), do: false
end
