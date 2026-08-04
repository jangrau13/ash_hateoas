defmodule AshHateoas.Resource.Transformers.DeriveObservables do
  @moduledoc """
  Turns `observable` declarations into `AshHateoas.Observable` specs.

  Every spec is derived from the routes `DeriveActionRoutes` already persisted —
  the topic IS a route (the canonical index for `:collection`, the primary get
  for `:resource`, that same member URL plus `?observe=<attribute>` for a
  property) — so an observable can never name a URL the API does not serve.

  The `actions` list holds concrete, routed action names:

    * `:collection` — creates and destroys (the set changed)
    * `:resource` — updates and destroys (the record changed)
    * an attribute — updates only, filtered at publish time by `changing?`

  An `unrouted` action is excluded, mirroring the route deny-list: keeping an
  action off the HTTP surface also keeps it from notifying.

  A subject whose topic cannot be derived (no canonical index, no primary get)
  yields NO spec — the verifier warns, since the declaration is then inert.

  This transformer publishes nothing. Specs are persisted under the
  `ash_hateoas`-owned key `:ash_hateoas_observables` for a transport package
  (e.g. `ash_websub`) to read and act on.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @persisted_observables_key :ash_hateoas_observables

  # The specs are built FROM the persisted routes, so this must run after
  # DeriveActionRoutes — and after Ash's own transformers for the same reason
  # it must (actions are read to build the notify-on lists).
  @impl true
  def after?(AshHateoas.Resource.Transformers.DeriveActionRoutes), do: true

  def after?(module) do
    module |> Module.split() |> Enum.take(3) == ~w(Ash Resource Transformers)
  rescue
    _ -> false
  end

  @impl true
  def transform(dsl_state) do
    # Ash's flag for a value type, which has no identity and therefore no URL
    # to observe.
    if Transformer.get_persisted(dsl_state, :embedded?, false) do
      {:ok, dsl_state}
    else
      derive(dsl_state)
    end
  end

  defp derive(dsl_state) do
    observables =
      dsl_state
      |> AshHateoas.Resource.Info.observable_subjects()
      |> Enum.uniq()
      |> Enum.flat_map(&build(dsl_state, &1))

    {:ok, Transformer.persist(dsl_state, @persisted_observables_key, observables)}
  rescue
    _ -> {:ok, dsl_state}
  end

  defp build(dsl_state, :collection) do
    case canonical_index(dsl_state) do
      nil ->
        []

      route ->
        [
          %AshHateoas.Observable{
            subject: :collection,
            topic: route.route,
            actions: routed(dsl_state, [:create, :destroy])
          }
        ]
    end
  end

  defp build(dsl_state, :resource) do
    case primary_get(dsl_state) do
      nil ->
        []

      route ->
        [
          %AshHateoas.Observable{
            subject: :resource,
            topic: route.route,
            actions: routed(dsl_state, [:update, :destroy])
          }
        ]
    end
  end

  defp build(dsl_state, attribute) do
    case primary_get(dsl_state) do
      nil ->
        []

      route ->
        [
          %AshHateoas.Observable{
            subject: attribute,
            topic: "#{route.route}?observe=#{attribute}",
            actions: routed(dsl_state, [:update])
          }
        ]
    end
  end

  # Action names of the given types whose notification signals a change —
  # minus the unrouted ones, which are off the HTTP surface and therefore
  # silent.
  defp routed(dsl_state, types) do
    unrouted = AshHateoas.Resource.Info.unrouted(dsl_state)

    dsl_state
    |> Ash.Resource.Info.actions()
    |> Enum.filter(&(&1.type in types and &1.name not in unrouted))
    |> Enum.map(& &1.name)
  end

  defp primary_get(dsl_state) do
    dsl_state
    |> AshHateoas.Resource.Info.routes()
    |> Enum.find(&(&1.type == :get and &1.primary?))
  end

  # The canonical collection: the index whose route does not end in its own
  # action name. Mirrors the rule `AshHateoas.Navigation` and the verifier's
  # `base_path_index?` apply; kept local so this transformer reaches into
  # neither.
  defp canonical_index(dsl_state) do
    dsl_state
    |> AshHateoas.Resource.Info.routes()
    |> Enum.find(&(&1.type == :index and not String.ends_with?(&1.route, "/#{&1.action}")))
  end
end
