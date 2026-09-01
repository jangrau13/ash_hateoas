defmodule AshHateoas.Hydra.Collection do
  @moduledoc """
  Wraps a set of member nodes into a `hydra:Collection`.

  A collection references its members via `hydra:member`, states its size with
  `hydra:totalItems`, says what its members *are* with `hydra:memberAssertion`,
  and — when paginated — carries a `hydra:PartialCollectionView` under
  `hydra:view` with `first` / `previous` / `next` / `last` navigation.
  """

  @doc """
  Build a `hydra:Collection` node.

  ## Options

    * `:id` — the collection's `@id` (its URL).
    * `:total_items` — `hydra:totalItems`; omitted when nil.
    * `:class` — the collection's own class IRI, added to `@type` beside the
      bare `Collection`; omitted when nil.
    * `:member_class` — the class IRI every member has, stated as a
      `hydra:memberAssertion`; omitted when nil.
    * `:operations` — collection-level operations (e.g. `create`) to attach.
    * `:view` — a page-links keyword (`first`/`previous`/`next`/`last`) turned
      into a `PartialCollectionView`; omitted when empty.
    * `:view_map` — an already-built `PartialCollectionView` map (or nil); wins
      over `:view` when given.
  """
  @spec wrap([map()], keyword()) :: map()
  def wrap(members, opts \\ []) do
    %{
      "@type" => collection_type(Keyword.get(opts, :class)),
      "hydra:member" => members
    }
    |> put_unless_nil("@id", Keyword.get(opts, :id))
    |> put_unless_nil("hydra:totalItems", Keyword.get(opts, :total_items))
    |> put_member_assertion(Keyword.get(opts, :member_class))
    |> merge_operations(Keyword.get(opts, :operations, %{}))
    |> put_view(Keyword.get(opts, :view_map) || view(Keyword.get(opts, :view, [])))
  end

  @doc """
  The `hydra:memberAssertion` saying every member of a collection is an instance
  of `member_class`.

  One function, called from two places, because it is **one statement**. The
  catalogue's collection class carries it so a client reading
  `hydra:returns: <Class>/Collection` learns what is inside; the response carries
  it so a client holding only the response learns the same thing without a second
  fetch. Written out twice they would be free to drift, and a client comparing
  the two would be comparing this package against itself.

  The spec's normative constraint — "a memberAssertion MUST use two and only two
  of the subject, property and object predicates" — is met by the
  property/object pair. `hydra:subject` is the third and is deliberately absent:
  on a class it would name one specific parent record, which is an instance-level
  fact; on a response it would restate the collection's own `@id`.
  """
  @spec member_assertion(String.t()) :: map()
  def member_assertion(member_class) when is_binary(member_class) do
    %{
      "hydra:property" => %{"@id" => "rdf:type"},
      "hydra:object" => %{"@id" => member_class}
    }
  end

  # **Which class this collection is an instance of.**
  #
  # The bare `Collection` says it is a collection and nothing more, so a client
  # holding one response had to match its URL against the catalogue to find the
  # entry that describes it. The catalogue now files collection-level operations
  # under `<Class>/Collection` — create, list — and naming that class here is what
  # joins the response to them: a client reads the second `@type` and looks it up,
  # exactly as it does for a record.
  #
  # `Collection` stays first, so a consumer reading position 0 is unaffected. See
  # `documentation/hydra-conformance-notes.md` §8.
  defp collection_type(nil), do: "Collection"
  defp collection_type(class), do: ["Collection", class]

  defp put_member_assertion(collection, nil), do: collection

  defp put_member_assertion(collection, member_class),
    do: Map.put(collection, "hydra:memberAssertion", member_assertion(member_class))

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
