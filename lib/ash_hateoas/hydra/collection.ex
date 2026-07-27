defmodule AshHateoas.Hydra.Collection do
  @moduledoc """
  Wraps a set of member nodes into a `hydra:Collection`.

  A collection references its members via `hydra:member`, states its size with
  `hydra:totalItems`, and — when paginated — carries a
  `hydra:PartialCollectionView` under `hydra:view` with `first` / `previous` /
  `next` / `last` navigation.
  """

  @doc """
  Build a `hydra:Collection` node.

  ## Options

    * `:id` — the collection's `@id` (its URL).
    * `:total_items` — `hydra:totalItems`; omitted when nil.
    * `:operations` — collection-level operations (e.g. `create`) to attach.
    * `:view` — a page-links keyword (`first`/`previous`/`next`/`last`) turned
      into a `PartialCollectionView`; omitted when empty.
  """
  @spec wrap([map()], keyword()) :: map()
  def wrap(members, opts \\ []) do
    %{
      "@type" => "Collection",
      "hydra:member" => members
    }
    |> put_unless_nil("@id", Keyword.get(opts, :id))
    |> put_unless_nil("hydra:totalItems", Keyword.get(opts, :total_items))
    |> merge_operations(Keyword.get(opts, :operations, %{}))
    |> put_view(view(Keyword.get(opts, :view, [])))
  end

  @doc """
  Build a `hydra:PartialCollectionView` from page links, or `nil` when there are
  none.
  """
  @spec view(keyword()) :: map() | nil
  def view(links) do
    present =
      links
      |> Keyword.take([:id, :first, :previous, :next, :last])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case present do
      [] ->
        nil

      pairs ->
        base = %{"@type" => "PartialCollectionView"}

        Enum.reduce(pairs, base, fn
          {:id, value}, acc -> Map.put(acc, "@id", value)
          {key, value}, acc -> Map.put(acc, "hydra:#{key}", value)
        end)
    end
  end

  defp merge_operations(collection, operations) when map_size(operations) == 0, do: collection
  defp merge_operations(collection, operations), do: Map.merge(collection, operations)

  defp put_view(collection, nil), do: collection
  defp put_view(collection, view), do: Map.put(collection, "hydra:view", view)

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
