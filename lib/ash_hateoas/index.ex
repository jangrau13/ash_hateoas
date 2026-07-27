defmodule AshHateoas.Index do
  @moduledoc """
  Maps a `type` string back to the Ash resource that produced it.

  A serialized node identifies its resource by `type` (+ id), so resolving a
  node back to a resource means reversing `AshHateoas.Resource.Info.type/1`.

  The index is built per request from the domains in play. That sounds wasteful
  but is pure in-memory DSL reading — no I/O — and it keeps the module free of
  the cache-invalidation a persistent index would carry when resources are
  recompiled in dev.
  """

  @doc """
  Build `%{type_string => resource_module}` for every resource in `domains`
  that carries the `AshHateoas.Resource` extension.

  Resources without the extension are skipped: nothing routes them, so nothing
  in a document refers to them.
  """
  @spec build([module()]) :: %{String.t() => module()}
  def build(domains) do
    domains
    |> List.wrap()
    |> Enum.flat_map(&resources/1)
    |> Enum.filter(&AshHateoas.Resource.Info.extension?/1)
    |> Enum.reduce(%{}, fn resource, acc ->
      case type_of(resource) do
        nil -> acc
        type -> Map.put(acc, to_string(type), resource)
      end
    end)
  end

  @doc "Look up the resource for a type string."
  @spec fetch(%{String.t() => module()}, String.t()) :: {:ok, module()} | :error
  def fetch(index, type) when is_binary(type), do: Map.fetch(index, type)
  def fetch(_index, _type), do: :error

  defp resources(domain) do
    Ash.Domain.Info.resources(domain)
  rescue
    _ -> []
  end

  defp type_of(resource) do
    AshHateoas.Resource.Info.type(resource)
  rescue
    _ -> nil
  end
end
