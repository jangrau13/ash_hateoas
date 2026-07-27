defmodule AshHateoas.Navigation do
  @moduledoc """
  Structural navigation — the other half of HATEOAS.

  Affordances answer *"what can I do with this?"*. Navigation answers *"where am
  I, what else exists, and where do I start?"*. A client must be able to
  hardcode **one** entry point and from there reach every type, every collection
  and every record, being told at each stop what it may do.

  Like affordances, nothing here is new author config: it is the same
  principle — read what is already declared — extended from actions to
  structure.

  | Navigation need | Derived from |
  |---|---|
  | which types exist | `Ash.Domain.Info.resources/1` + declared routes |
  | collection URL per type | the resource's `:index` route |
  | record → its collection | route introspection |
  | record → its domain | `Ash.Resource.Info.domain/1` |

  ## Authorization applies to navigation too

  Structural links MUST NOT reveal types or collections the actor may not
  access. An unreachable branch is omitted, not rendered-and-rejected — the same
  posture the authorization gate takes. A type is reachable when the actor may
  run *any* of its routed actions; in practice that is usually its `:read`.
  """

  alias AshHateoas.Index

  @doc """
  The root entry document: every type the actor can reach, with its collection
  link.

  This is the one URL a client hardcodes. Types the actor cannot access are
  omitted entirely.

  Returns `%{type_string => %{"href" => collection_url, "rel" => "collection"}}`.
  """
  @spec root(module() | [module()], term(), keyword()) :: %{String.t() => map()}
  def root(domains, actor, opts \\ []) do
    domains = List.wrap(domains)

    domains
    |> Index.build()
    |> Enum.filter(fn {_type, resource} -> reachable?(resource, actor, domains, opts) end)
    |> Map.new(fn {type, resource} ->
      {type,
       %{
         "href" => collection_href(resource, domains, opts),
         "rel" => "collection"
       }}
    end)
  end

  @doc """
  Structural links for a single record: its collection and its owning domain.

  `collection` and `up` are registered IANA relation types, so navigation and
  affordances arrive together in one `links` object without colliding.
  """
  @spec record_links(struct(), [module()], keyword()) :: %{String.t() => map() | String.t()}
  def record_links(record, domains, opts \\ []) when is_struct(record) do
    resource = record.__struct__

    %{}
    |> put_collection(resource, domains, opts)
    |> put_domain(resource, domains, opts)
  end

  @doc """
  The collection URL for a resource, from its declared `:index` route.

  Returns `nil` when the resource has no index route — it is not reachable as a
  collection, so no link should be emitted.
  """
  @spec collection_href(module(), [module()], keyword()) :: String.t() | nil
  def collection_href(resource, domains, opts \\ []) do
    case index_route(resource, domains) do
      nil -> nil
      route -> prefix(opts, domains) <> route.route
    end
  end

  # A collection link is followable only if the actor may READ the collection —
  # the action a client performs when it follows the link. Testing "any routed
  # action" is wrong and produces exactly the failure to avoid: a resource
  # whose :create is public but whose :read is restricted would be advertised
  # and then 403 on arrival, which is rendering-and-rejecting.
  defp reachable?(resource, actor, domains, _opts) do
    case index_action(resource, domains) do
      nil -> false
      action -> can?(resource, action, actor)
    end
  end

  defp index_action(resource, domains) do
    with %{action: action_name} <- index_route(resource, domains),
         action when not is_nil(action) <- Ash.Resource.Info.action(resource, action_name) do
      action
    else
      _ -> nil
    end
  end

  defp can?(resource, action, actor) do
    Ash.can?({resource, action}, actor)
  rescue
    _ -> false
  end

  defp put_collection(links, resource, domains, opts) do
    case collection_href(resource, domains, opts) do
      nil -> links
      href -> Map.put(links, "collection", %{"href" => href, "rel" => "collection"})
    end
  end

  # `up` is the IANA relation for a parent resource. The domain is the record's
  # owning collection-of-collections, which is the closest honest reading.
  defp put_domain(links, resource, domains, opts) do
    case domain_of(resource) do
      nil ->
        links

      _domain ->
        Map.put(links, "up", %{
          "href" => prefix(opts, domains) <> "/",
          "rel" => "up"
        })
    end
  end

  defp domain_of(resource) do
    Ash.Resource.Info.domain(resource)
  rescue
    _ -> nil
  end

  # The canonical collection, when a type has more than one index route.
  #
  # A resource with collection reads beyond its primary — a `search`, a
  # `recent` — now derives an `:index` per read: the primary read's at the
  # resource base and each named one at `base <> "/<name>"`. All are indexes,
  # but exactly one is THE collection a client reaches by following `collection`
  # from the entry point: the primary read's, at the base path.
  #
  # A named index's path ends with its own action name (`/inventory/process`
  # vs `/inventory/process/semantic_search`); the canonical one does not. So the
  # index whose route does NOT end in `/<its action>` is preferred, with
  # `List.first` as the fallback for the ordinary single-index case. This is a
  # pure read of the routes already in the DSL — no re-derivation of which read
  # is primary.
  defp index_route(resource, domains) do
    indexes =
      resource
      |> routes(domains)
      |> Enum.filter(&(&1.type == :index))

    Enum.find(indexes, &canonical_index?/1) || List.first(indexes)
  end

  defp canonical_index?(%{route: route, action: action}) when is_atom(action) do
    not String.ends_with?(route, "/#{action}")
  end

  defp canonical_index?(_route), do: true

  defp routes(resource, _domains) do
    AshHateoas.Resource.Info.routes(resource)
  rescue
    _ -> []
  end

  # Every link in a document MUST resolve against the same base.
  #
  # Affordance hrefs are rendered with the domain's mount `prefix`, so
  # navigation must use it too. Emitting `/orders` beside
  # `/api/orders/{id}/confirm` produces a document whose two link families need
  # different bases, with nothing on the wire saying which is which — a client
  # that follows `collection` lands on a 404, and the only way to know better is
  # out-of-band knowledge of the mount point. Serving one consistent base is
  # what removes that need.
  #
  # An explicit `:prefix` still wins, for a host that forwards the router
  # somewhere the domain does not describe.
  defp prefix(opts, _domains) do
    case Keyword.get(opts, :prefix) do
      nil -> ""
      prefix -> String.trim_trailing(prefix, "/")
    end
  end
end
