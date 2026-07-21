defmodule AshHateoas.Resource.Transformers.DeriveRelationshipRoutes do
  @moduledoc """
  Derives `related` and `relationship` routes for public relationships, so a
  record's `relationships` carry links (R9, "walk the data graph").

  `ash_json_api` renders `relationships.<name>.links.related` and `.self` from
  declared `related`/`relationship` routes. Declare none and the serialized
  record still lists the relationship — but with an empty `links` object. The
  relationship is public, loadable and routed on the other side; nothing says
  where it lives. A client told to follow links and construct nothing reaches a
  dead end at every edge of the graph.

  Everything needed is already declared: the relationship is public, its
  destination has a JSON:API type, and the source has a read action. So the
  routes are derived rather than demanded of the author — the same reasoning as
  `AshHateoas.Resource.Transformers.MarkPrimaryGet`, and R1's principle applied
  to structure instead of actions.

  ## What it will not do

    * **A relationship the author already routed is left alone.** An explicit
      `related :comments, :read` wins, including its `primary?` and any options.
    * **Private relationships are skipped.** Not public means not part of the
      API surface, and routing one would widen it.
    * **A destination without a JSON:API type is skipped.** It cannot be
      serialized as a resource object, so a link to it would not resolve.
    * **A resource with no primary read action is skipped.** Both route types
      need a read action to fetch the source record, and picking one when
      several exist is the author's call.
    * **`belongs_to` and `has_one` are skipped**, pending an upstream fix.
      `ash_json_api` 1.7.1 raises `FunctionClauseError` in
      `encode_primary_key/1` when serializing a to-one `relationship` route: it
      is handed a list where it expects a record. The same crash occurs with a
      hand-declared `relationship :document, :read`, so it is not caused by
      deriving them — but emitting a route that raises would be worse than
      emitting none. To-many relationships work, and are derived.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  # Runs AFTER Ash's own transformers, unlike `MarkPrimaryGet`. Relationships
  # are populated by a transformer (belongs_to generates its source attribute,
  # among other things), so reading them before that runs finds nothing —
  # which is a silent no-op rather than an error.
  #
  # Still before `ash_json_api`'s, so the routes exist by the time it reads
  # them.
  # Runs after EVERY Ash transformer, unlike `MarkPrimaryGet`. Relationships
  # are not in the DSL state until Ash's own transformers have populated them —
  # reading earlier finds an empty list, which is a silent no-op rather than an
  # error.
  @impl true
  def after?(module) do
    module |> Module.split() |> Enum.take(3) == ~w(Ash Resource Transformers)
  rescue
    _ -> false
  end

  # And before `ash_json_api`'s own, so the derived routes are in place when it
  # prefixes and validates them.
  @impl true
  def before?(module) do
    module |> Module.split() |> Enum.take(2) == ~w(AshJsonApi Resource)
  rescue
    _ -> false
  end

  @impl true
  def transform(dsl_state) do
    if Transformer.get_persisted(dsl_state, :embedded?, false) do
      {:ok, dsl_state}
    else
      derive(dsl_state)
    end
  end

  defp derive(dsl_state) do
    with read when not is_nil(read) <- primary_read(dsl_state),
         [_ | _] = relationships <- routable(dsl_state) do
      {:ok, Enum.reduce(relationships, dsl_state, &add_routes(&2, &1, read))}
    else
      _ -> {:ok, dsl_state}
    end
  rescue
    # A resource without ash_json_api has no such DSL path.
    _ -> {:ok, dsl_state}
  end

  defp routable(dsl_state) do
    routed = already_routed(dsl_state)

    dsl_state
    |> Ash.Resource.Info.relationships()
    |> Enum.filter(fn relationship ->
      relationship.public? and
        relationship.name not in routed and
        to_many?(relationship) and
        json_api_type?(relationship.destination)
    end)
  end

  # Both `related` and `relationship` route types carry the relationship name,
  # so one lookup covers both — a relationship with either declared is treated
  # as the author's, and left untouched.
  defp already_routed(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:json_api, :routes])
    |> Enum.filter(&(&1.type in [:get_related, :relationship]))
    |> Enum.map(& &1.relationship)
  end

  # See the moduledoc: a to-one `relationship` route raises in ash_json_api
  # 1.7.1, hand-declared or derived alike. Deriving one would turn a missing
  # link into a 500.
  defp to_many?(%{cardinality: :many}), do: true
  defp to_many?(_relationship), do: false

  defp add_routes(dsl_state, relationship, read) do
    Enum.reduce([:related, :relationship], dsl_state, fn type, dsl_state ->
      case build_route(type, relationship.name, read) do
        {:ok, route} ->
          Transformer.add_entity(dsl_state, [:json_api, :routes], route)

        _ ->
          dsl_state
      end
    end)
  end

  # `:route` is omitted, not passed as nil. Both entities make it optional and
  # fill it in via their own `set_related_route/1` / `set_relationship_route/1`
  # transform — `:id/<name>` and `:id/relationships/<name>`. Writing those paths
  # here would duplicate a convention `ash_json_api` owns and may change; the
  # base schema also declares `:route` required, so `nil` is rejected outright.
  defp build_route(type, relationship, read) do
    Transformer.build_entity(
      AshJsonApi.Resource,
      [:json_api, :routes],
      type,
      relationship: relationship,
      action: read,
      primary?: true
    )
  end

  defp primary_read(dsl_state) do
    case Ash.Resource.Info.primary_action(dsl_state, :read) do
      nil -> nil
      action -> action.name
    end
  rescue
    _ -> nil
  end

  # No `Code.ensure_loaded?` guard. During compilation the destination module is
  # typically still being compiled, so it answers false and every relationship
  # would be skipped — silently, since the result is an empty list rather than
  # an error. `AshJsonApi.Resource.Info.type/1` reads the DSL and works anyway;
  # the rescue covers a destination that genuinely has no json_api section.
  defp json_api_type?(destination) do
    not is_nil(AshJsonApi.Resource.Info.type(destination))
  rescue
    _ -> false
  end
end
