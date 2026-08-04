defmodule AshHateoas.Resource.Transformers.DeriveRelationshipRoutes do
  @moduledoc """
  Derives `related` and `relationship` routes for public to-many relationships,
  so a record can carry links to its related collections — walking the data
  graph.

  Everything needed is already declared: the relationship is public, its
  destination has a type, and the source has a read action. So the routes are
  derived rather than demanded of the author — the read-what-is-declared
  principle applied to structure instead of actions.

  Routes are `AshHateoas.Route` structs appended to the same persisted
  `:ash_hateoas_routes` key `DeriveActionRoutes` writes.

  ## What it will not do

    * **Private relationships are skipped.** Not public means not part of the
      API surface, and routing one would widen it.
    * **A destination without a type is skipped.** It cannot be addressed as a
      node, so a link to it would not resolve.
    * **A resource with no primary read action is skipped.** Both route types
      need a read action to fetch the source record.
    * **`belongs_to` and `has_one` derive no route** — a to-one is carried on
      the record itself as a node reference (see `Plug.merge_relationships/5`),
      so there is no separate collection URL to derive.
  """

  use Spark.Dsl.Transformer

  alias AshHateoas.Route
  alias Spark.Dsl.Transformer

  @persisted_routes_key :ash_hateoas_routes

  # Runs after EVERY Ash transformer: relationships are not in the DSL state
  # until Ash's own transformers have populated them, and reading earlier finds
  # an empty list (a silent no-op rather than an error).
  #
  # Also after `DeriveActionRoutes`, so the action routes it persists are read
  # here and appended to rather than overwritten.
  @impl true
  def after?(AshHateoas.Resource.Transformers.DeriveActionRoutes), do: true

  def after?(module) do
    module |> Module.split() |> Enum.take(3) == ~w(Ash Resource Transformers)
  rescue
    _ -> false
  end

  @impl true
  def transform(dsl_state) do
    # `:embedded?` is Ash's own flag for a value type — a struct stored inside
    # an attribute. It has no identity, so no IRI, so nothing that could be
    # linked to or dereferenced. Routing one would advertise a URL that cannot
    # resolve.
    if Transformer.get_persisted(dsl_state, :embedded?, false) do
      {:ok, dsl_state}
    else
      derive(dsl_state)
    end
  end

  defp derive(dsl_state) do
    with read when not is_nil(read) <- primary_read(dsl_state),
         base when not is_nil(base) <- base(dsl_state),
         [_ | _] = relationships <- routable(dsl_state) do
      existing = Transformer.get_persisted(dsl_state, @persisted_routes_key, [])
      derived = Enum.flat_map(relationships, &routes_for(&1, read, base))
      {:ok, Transformer.persist(dsl_state, @persisted_routes_key, existing ++ derived)}
    else
      _ -> {:ok, dsl_state}
    end
  rescue
    _ -> {:ok, dsl_state}
  end

  defp routable(dsl_state) do
    dsl_state
    |> Ash.Resource.Info.relationships()
    |> Enum.filter(fn relationship ->
      relationship.public? and
        to_many?(relationship) and
        has_type?(relationship.destination)
    end)
  end

  defp to_many?(%{cardinality: :many}), do: true
  defp to_many?(_relationship), do: false

  defp routes_for(relationship, read, base) do
    [
      %Route{
        type: :related,
        relationship: relationship.name,
        action: read,
        route: "#{base}/:id/#{relationship.name}",
        primary?: true
      },
      %Route{
        type: :relationship,
        relationship: relationship.name,
        action: read,
        route: "#{base}/:id/relationships/#{relationship.name}",
        primary?: true
      }
    ]
  end

  defp base(dsl_state) do
    with nil <- AshHateoas.Resource.Info.base(dsl_state),
         type when is_binary(type) <- AshHateoas.Resource.Info.type(dsl_state),
         domain when is_binary(domain) <- domain_short_name(dsl_state) do
      "/#{domain}/#{type}"
    else
      declared when is_binary(declared) -> declared
      _ -> nil
    end
  end

  defp domain_short_name(dsl_state) do
    case Transformer.get_persisted(dsl_state, :domain) do
      nil -> nil
      domain -> module_short_name(domain)
    end
  end

  defp module_short_name(domain) do
    domain
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  rescue
    _ -> nil
  end

  defp primary_read(dsl_state) do
    case Ash.Resource.Info.primary_action(dsl_state, :read) do
      nil -> nil
      action -> action.name
    end
  rescue
    _ -> nil
  end

  # During compilation the destination module is typically still compiling, so
  # a `Code.ensure_loaded?` guard would answer false and skip every
  # relationship silently. `AshHateoas.Resource.Info.type/1` reads the DSL (or
  # infers from the module name) and works anyway.
  defp has_type?(destination) do
    not is_nil(AshHateoas.Resource.Info.type(destination))
  rescue
    _ -> false
  end
end
