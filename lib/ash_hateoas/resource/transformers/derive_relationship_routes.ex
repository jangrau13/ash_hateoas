defmodule AshHateoas.Resource.Transformers.DeriveRelationshipRoutes do
  @moduledoc """
  Derives a `related` route for each public to-many relationship, so a record's
  collections are addressable and pageable — walking the data graph.

  `/articles/7/comments` addresses **this article's comments**: a real resource,
  and the read `Ash.read(Comment)` narrowed to one source record. That is what
  makes it different from nesting a *member* under its owner
  (`/articles/7/comments/3`), which states the same edge the member's own
  `comments`/`article` link already carries and gives one record two addresses.
  A relationship's collection has no address of its own without this route;
  a member always does.

  It also gives an inline collection something to be. A `hydra:Collection` on a
  node carries a bounded page of member references plus `hydra:totalItems`, and
  its `hydra:view` has to page against *some* URL — this one. Without it a
  collection could only ever be complete or silent.

  The JSON:API-style `/relationships/<name>` route is deliberately **not**
  derived. It existed to return linkage without the members; the reference list
  the node now carries says exactly that, in place, at no extra request.

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
    existing = Transformer.get_persisted(dsl_state, @persisted_routes_key, [])

    with read when not is_nil(read) <- primary_read(dsl_state),
         base when not is_nil(base) <- base(existing),
         [_ | _] = relationships <- routable(dsl_state) do
      derived = Enum.flat_map(relationships, &routes_for(&1, read, base))
      {:ok, Transformer.persist(dsl_state, @persisted_routes_key, existing ++ derived)}
    else
      _ -> {:ok, dsl_state}
    end
  rescue
    _ -> {:ok, dsl_state}
  end

  # The base **`DeriveActionRoutes` already derived**, read off the member route
  # it persisted, rather than derived a second time here.
  #
  # This module used to re-derive it — declared `base`, else the domain's short
  # name plus `type` — and the copy was subtly wrong: its `domain_short_name/1`
  # read `Transformer.get_persisted(:domain)`, which is nil for a resource whose
  # domain is set the ordinary way. So **every resource that did not declare
  # `base` explicitly got no related routes at all**, silently. In this repo's
  # own fixtures that was `Ledger` but not `Article`, which is exactly the kind
  # of split that reads as "works" until someone looks.
  #
  # Reading the member route removes the duplication rather than fixing it:
  # there is now one derivation of a resource's base, and this cannot disagree
  # with the routes it is appending to.
  defp base(routes) do
    Enum.find_value(routes, fn
      %Route{type: :get, route: route} when is_binary(route) ->
        String.replace_suffix(route, "/:id", "")

      _ ->
        nil
    end)
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
      }
    ]
  end

  defp primary_read(dsl_state) do
    case Ash.Resource.Info.primary_action(dsl_state, :read) do
      nil -> nil
      action -> action.name
    end
  rescue
    _ -> nil
  end

  # Whether the destination can be addressed as a node at all — because a
  # relationship pointing at something with no URL would derive a route whose
  # members cannot be linked to.
  #
  # `module_type/1` rather than `type/1`, and the difference is load-bearing.
  # `type/1` reads the DSL before falling back to the module name, and that
  # first step **forces the destination module to finish compiling**. During its
  # own compilation the destination usually has not, so the call raised and the
  # `rescue` answered *false* — silently dropping the relationship.
  #
  # Which relationships survived then depended on **compile order**: in this
  # repo's own fixtures `Article`→`Comment` derived its routes and
  # `Ledger`→`Entry` did not, for no reason visible in either resource. A
  # `Code.ensure_loaded?` guard has the same defect, which is what the previous
  # comment here warned about while the code went on to hit it anyway.
  #
  # `module_type/1` reads `Module.split/1` and forces nothing. The cost is that
  # a destination **declaring** a `type` different from its module name is not
  # honoured here — the same limitation, and the same trade, that
  # `DeriveActionRoutes.owner_prefix/2` documented before it was removed.
  defp has_type?(destination) do
    not is_nil(AshHateoas.Resource.Info.module_type(destination))
  rescue
    _ -> false
  end
end
