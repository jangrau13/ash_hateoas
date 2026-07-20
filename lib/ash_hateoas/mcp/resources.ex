defmodule AshHateoas.Mcp.Resources do
  @moduledoc """
  MCP navigation via the `resources` primitive (§5.2, R9).

  MCP separates two concerns and the split maps onto ours exactly:

    * **tools** are *actions you invoke* — affordances
    * **resources** are *addressable data you read and navigate* — navigation

  So navigation is modelled with `resources/*`, never as tools. A type becomes
  an RFC 6570 **URI template** (`order://{id}`), which advertises the type
  without enumerating every record — what makes "enter anywhere" tractable for
  a large collection.

  URIs encode the type/record hierarchy; custom schemes are explicitly
  permitted by the MCP specification.

  ## Authorization

  As with JSON:API navigation, a type the actor cannot read is omitted rather
  than advertised-and-refused (R9). `resources/read` re-checks on dereference,
  so a stale template degrades to an error rather than a leak.
  """

  @doc """
  URI templates for every type the actor can reach.

  Shaped for the `resources/templates/list` result.
  """
  @spec templates([module()], term(), keyword()) :: [map()]
  def templates(resources, actor, opts \\ []) do
    resources
    |> List.wrap()
    |> Enum.filter(&readable?(&1, actor, opts))
    |> Enum.map(&template/1)
  end

  @doc """
  Concrete addressable entries for the types the actor can reach.

  `resources/list` is for enumerating records where that is meaningful. It is
  deliberately bounded: a large collection is navigated by template, not by
  enumeration.
  """
  @spec list([module()], term(), keyword()) :: [map()]
  def list(resources, actor, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    resources
    |> List.wrap()
    |> Enum.filter(&readable?(&1, actor, opts))
    |> Enum.flat_map(&entries(&1, actor, opts, limit))
  end

  @doc """
  Dereference a URI produced by `templates/3` or `list/3`.

  Returns `{:ok, contents}` shaped for the `resources/read` result, or
  `{:error, reason}`. Authorization is re-checked here: a URI a client kept from
  an earlier session must not bypass the policy that hid it.
  """
  @spec read(String.t(), [module()], term(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(uri, resources, actor, opts \\ []) do
    with {:ok, scheme, id} <- parse(uri),
         {:ok, resource} <- resolve(scheme, resources),
         {:ok, record} <- fetch(resource, id, actor, opts) do
      {:ok,
       %{
         "uri" => uri,
         "mimeType" => "application/json",
         "text" => Jason.encode!(serialize(record))
       }}
    end
  end

  @doc "The URI scheme for a resource — its JSON:API type, or its module name."
  @spec scheme(module()) :: String.t()
  def scheme(resource) do
    case json_api_type(resource) do
      nil -> resource |> Module.split() |> List.last() |> Macro.underscore()
      type -> to_string(type)
    end
  end

  @doc "The URI for a specific record."
  @spec uri(module(), term()) :: String.t()
  def uri(resource, id), do: "#{scheme(resource)}://#{id}"

  defp template(resource) do
    %{
      "uriTemplate" => "#{scheme(resource)}://{id}",
      "name" => scheme(resource),
      "description" => description(resource),
      "mimeType" => "application/json"
    }
  end

  defp description(resource) do
    case Ash.Resource.Info.description(resource) do
      nil -> "A #{scheme(resource)} record, addressed by id."
      description -> description
    end
  rescue
    _ -> "A #{scheme(resource)} record, addressed by id."
  end

  defp entries(resource, actor, opts, limit) do
    resource
    |> Ash.read!(actor: actor, tenant: opts[:tenant], authorize?: true)
    |> Enum.take(limit)
    |> Enum.map(fn record ->
      %{
        "uri" => uri(resource, primary_key(record)),
        "name" => "#{scheme(resource)} #{primary_key(record)}",
        "mimeType" => "application/json"
      }
    end)
  rescue
    _ -> []
  end

  # A type is navigable only if its read action is permitted — advertising one
  # the actor cannot read is the rendering-and-rejecting R9 forbids.
  defp readable?(resource, actor, _opts) do
    case Ash.Resource.Info.primary_action(resource, :read) do
      nil -> false
      action -> Ash.can?({resource, action}, actor)
    end
  rescue
    _ -> false
  end

  defp parse(uri) when is_binary(uri) do
    case String.split(uri, "://", parts: 2) do
      [scheme, id] when scheme != "" and id != "" -> {:ok, scheme, id}
      _ -> {:error, :invalid_uri}
    end
  end

  defp parse(_uri), do: {:error, :invalid_uri}

  defp resolve(scheme, resources) do
    resources
    |> List.wrap()
    |> Enum.find(&(scheme(&1) == scheme))
    |> case do
      nil -> {:error, :unknown_resource}
      resource -> {:ok, resource}
    end
  end

  defp fetch(resource, id, actor, opts) do
    case Ash.get(resource, id, actor: actor, tenant: opts[:tenant], authorize?: true) do
      {:ok, record} -> {:ok, record}
      {:error, _reason} -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  # Only public attributes reach the wire, mirroring the field rules for
  # affordances (R4).
  defp serialize(%resource{} = record) do
    resource
    |> Ash.Resource.Info.public_attributes()
    |> Map.new(fn attribute -> {attribute.name, Map.get(record, attribute.name)} end)
  end

  defp primary_key(%resource{} = record) do
    case Ash.Resource.Info.primary_key(resource) do
      [key] -> Map.get(record, key)
      keys -> keys |> Enum.map(&Map.get(record, &1)) |> Enum.join(",")
    end
  end

  defp json_api_type(resource) do
    if Code.ensure_loaded?(AshJsonApi.Resource.Info) do
      AshJsonApi.Resource.Info.type(resource)
    end
  rescue
    _ -> nil
  end
end
