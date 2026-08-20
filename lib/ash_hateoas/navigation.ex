defmodule AshHateoas.Navigation do
  @moduledoc """
  Structural navigation — the other half of HATEOAS.

  Affordances answer *"what can I do with this?"*. Navigation answers *"where am
  I, and what is this part of?"* — a record's place in the structure, so a
  client holding one resource can move from it.

  Like affordances, nothing here is new author config: it is the same
  principle — read what is already declared — extended from actions to
  structure.

  | Navigation need | Derived from |
  |---|---|
  | collection URL for a type | the resource's `:index` route |
  | record → its collection | route introspection |

  ## There is no entry point to derive

  **A client does not need a place to start.** Every response carries
  `Link: <…/doc>; rel="apiDocumentation"`, so the full description of the API is
  one hop from whatever resource a client happens to hold — a record reached
  from a bookmark, a search result, another service's link. That makes *every*
  URL a valid beginning rather than privileging one.

  A listing of every collection would be a rung above the top: a
  "collection-of-collections" that no domain has. A record's parent is its
  collection, and `collection` says that already.

  This is about what can be *derived*, not about what the root path answers.
  `AshHateoas.Hydra.Plug` sends `303 See Other` there, pointing at the
  documentation — a courtesy to a client following `hydra:entrypoint`, not a
  structural link, and nothing here derives it.

  ## Authorization applies to navigation too

  Structural links MUST NOT reveal what the actor may not access. An unreachable
  branch is omitted, not rendered-and-rejected — the same posture the
  authorization gate takes. A record's `collection` link needs no separate check:
  it is emitted on a record the actor has already read, in the same domain and
  under the same policies.
  """

  @doc """
  Structural links for a single record: its collection.

  Transport-neutral, keyed by relation name (`"collection"`), each value a
  `%{url:, kind:}` the rendering transport shapes. The name mirrors the
  registered IANA relation type, so navigation and affordances arrive together
  without colliding.

  ## There is no `up` beyond the collection

  **A collection-of-collections is not a resource** — nothing in any domain
  corresponds to it, so there is nothing for an `up` link to point at.

  A record's parent is its collection, which `collection` already names.
  The listing added a rung above the top, and being at the root path made it
  look like a required starting point — which it never was. A client may begin
  at *any* URL: every response carries a `Link: rel="apiDocumentation"` header,
  so the whole API is discoverable from whichever resource a client happens to
  hold. That, not a hardcoded index, is what makes the surface navigable.
  """
  @spec record_links(struct(), [module()], keyword()) :: %{String.t() => map()}
  def record_links(record, domains, opts \\ []) when is_struct(record) do
    resource = record.__struct__

    put_collection(%{}, resource, domains, opts)
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

  # Gone with the root listing: a per-actor reachability filter, which decided
  # which types that listing named. The rule it encoded is worth keeping in
  # view even though its caller is gone — **a link is followable only if the
  # actor may perform the action following it performs**. Testing "any routed
  # action" advertises a resource whose `:create` is public but whose `:read` is
  # restricted, and the client gets a 403 on arrival: rendering-and-rejecting.
  #
  # A record's own `collection` link needs no such filter. It is emitted on a
  # record the actor has already read, in the same domain and under the same
  # policies, so a reader of the record is a reader of its collection.

  defp put_collection(links, resource, domains, opts) do
    case collection_href(resource, domains, opts) do
      nil -> links
      href -> Map.put(links, "collection", %{url: href, kind: :collection})
    end
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
