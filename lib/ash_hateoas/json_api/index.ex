defmodule AshHateoas.JsonApi.Index do
  @moduledoc """
  Maps a JSON:API `type` string back to the Ash resource that produced it.

  The serialized document identifies each resource object by `type` + `id`, so
  merging affordances into it means reversing `AshJsonApi.Resource.Info.type/1`.

  The index is built per request from the domains in play. That sounds wasteful
  but is pure in-memory DSL reading — no I/O — and it keeps the module free of
  the cache-invalidation problem a persistent index would carry when resources
  are recompiled in dev.
  """

  @doc """
  Build `%{type_string => resource_module}` for every JSON:API resource in
  `domains`.

  Resources without the `AshJsonApi.Resource` extension are skipped: they have
  no `type`, so nothing in a document can refer to them.
  """
  @spec build([module()]) :: %{String.t() => module()}
  def build(domains) do
    domains
    |> List.wrap()
    |> Enum.flat_map(&resources/1)
    |> Enum.filter(&json_api_resource?/1)
    |> Enum.reduce(%{}, fn resource, acc ->
      case type_of(resource) do
        nil -> acc
        type -> Map.put(acc, to_string(type), resource)
      end
    end)
  end

  @doc "Look up the resource for a JSON:API type string."
  @spec fetch(%{String.t() => module()}, String.t()) :: {:ok, module()} | :error
  def fetch(index, type) when is_binary(type), do: Map.fetch(index, type)
  def fetch(_index, _type), do: :error

  defp resources(domain) do
    Ash.Domain.Info.resources(domain)
  rescue
    _ -> []
  end

  # The idiom AshJsonApi itself uses to decide whether a resource is routable.
  defp json_api_resource?(resource) do
    AshJsonApi.Resource in Spark.extensions(resource)
  rescue
    _ -> false
  end

  defp type_of(resource) do
    AshJsonApi.Resource.Info.type(resource)
  rescue
    _ -> nil
  end
end
