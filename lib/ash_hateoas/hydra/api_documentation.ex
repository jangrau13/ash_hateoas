defmodule AshHateoas.Hydra.ApiDocumentation do
  @moduledoc """
  Builds the `hydra:ApiDocumentation` — the machine-readable description of the
  API a generic client discovers first (via the `Link` header) and dereferences
  to learn the API's classes, their properties, and their operations.

  Everything here is derived from what the resources already declare, per R1:

    * `hydra:entrypoint` — the API's base URL.
    * `hydra:supportedClass` — one `hydra:Class` per resource carrying the
      extension, with `hydra:supportedProperty` from its public attributes and
      `hydra:supportedOperation` from its derived routes.

  ## Catalogue vs. availability

  `supportedOperation` describes the operations a class *supports* — their
  method, expected input and returned type. It is actor-independent and asserts
  no availability: whether an operation may be invoked *now*, on *this* record,
  by *this* actor is answered by the per-node `hydra:operation` the backbone
  gates. The documentation is the stable catalogue; the node is the live offer.
  """

  alias AshHateoas.Hydra.{Context, Renderer, TypeMapper}
  alias AshHateoas.{Index, Route}

  @doc """
  Build the full `ApiDocumentation` document for `domains`.

  ## Options

    * `:entrypoint` — the API base URL (`hydra:entrypoint`).
    * `:id` — the document's own `@id` (its URL, e.g. `/doc`).
  """
  @spec build([module()], keyword()) :: map()
  def build(domains, opts \\ []) do
    classes =
      domains
      |> Index.build()
      |> Enum.sort_by(fn {type, _resource} -> type end)
      |> Enum.map(fn {type, resource} -> supported_class(resource, type) end)

    %{
      "@context" => Context.context(),
      "@type" => "ApiDocumentation",
      "hydra:supportedClass" => classes
    }
    |> put_unless_nil("@id", Keyword.get(opts, :id))
    |> put_unless_nil("hydra:entrypoint", Keyword.get(opts, :entrypoint))
  end

  @doc "Build one `hydra:Class` for a resource."
  @spec supported_class(module(), String.t()) :: map()
  def supported_class(resource, type) do
    %{
      "@id" => Context.class_iri(type),
      "@type" => "Class",
      "hydra:title" => type,
      "hydra:supportedProperty" => supported_properties(resource, type),
      "hydra:supportedOperation" => supported_operations(resource)
    }
    |> put_unless_nil("hydra:description", description(resource))
    |> put_equivalent_class(AshHateoas.Resource.Info.semantic_type(resource))
  end

  # A declared well-known type (e.g. schema.org) is advertised as an
  # `owl:equivalentClass`, so a client that knows that vocabulary can treat this
  # class as the well-known one.
  defp put_equivalent_class(class, nil), do: class

  defp put_equivalent_class(class, semantic_type) do
    Map.put(class, "owl:equivalentClass", %{"@id" => semantic_type})
  end

  @doc """
  The `hydra:SupportedProperty` list from a resource's public attributes.
  """
  @spec supported_properties(module(), String.t()) :: [map()]
  def supported_properties(resource, type) do
    semantic = AshHateoas.Resource.Info.semantic_properties(resource)

    resource
    |> public_attributes()
    |> Enum.map(fn attribute ->
      # A mapped attribute advertises the well-known property IRI directly, so a
      # client that knows the vocabulary reads the value as that property.
      property_id =
        Map.get(semantic, attribute.name) || Context.property_iri(type, attribute.name)

      %{
        "@type" => "SupportedProperty",
        "hydra:property" => %{
          "@id" => property_id,
          "@type" => TypeMapper.to_datatype(AshHateoas.TypeMapper.to_wire(attribute.type))
        },
        "hydra:title" => to_string(attribute.name),
        "hydra:required" => not Map.get(attribute, :allow_nil?, true),
        "hydra:readable" => true,
        "hydra:writeable" => Map.get(attribute, :writable?, true)
      }
      |> put_unless_nil("hydra:description", Map.get(attribute, :description))
    end)
  end

  @doc """
  The `hydra:supportedOperation` list from a resource's derived routes.

  Actor-independent: it describes operation shape, not availability. Reads the
  route table directly rather than the gated backbone.
  """
  @spec supported_operations(module()) :: [map()]
  def supported_operations(resource) do
    resource
    |> routes()
    |> Enum.reject(&(&1.type in [:related, :relationship]))
    |> Enum.map(fn %Route{} = route ->
      action = Ash.Resource.Info.action(resource, route.action)

      %{
        "@type" => "Operation",
        "hydra:method" => method(route, action) |> to_string() |> String.upcase()
      }
      |> put_unless_nil("hydra:title", action && Map.get(action, :description))
      |> put_expects(action, resource)
    end)
  end

  defp put_expects(op, nil, _resource), do: op

  defp put_expects(op, action, resource) do
    affordance = AshHateoas.Descriptor.build(action, nil, resource)

    case affordance.fields do
      [] -> op
      _fields -> Map.put(op, "hydra:expects", Renderer.operation(affordance)["hydra:expects"])
    end
  end

  defp method(%Route{method: method}, _action) when not is_nil(method), do: method
  defp method(%Route{type: :get}, _action), do: :get
  defp method(%Route{type: :index}, _action), do: :get
  defp method(%Route{type: :post}, _action), do: :post
  defp method(%Route{type: :patch}, _action), do: :patch
  defp method(%Route{type: :delete}, _action), do: :delete
  defp method(_route, %{type: :read}), do: :get
  defp method(_route, %{type: :create}), do: :post
  defp method(_route, %{type: :update}), do: :patch
  defp method(_route, %{type: :destroy}), do: :delete
  defp method(_route, _action), do: :post

  defp public_attributes(resource) do
    resource
    |> Ash.Resource.Info.public_attributes()
  rescue
    _ -> []
  end

  defp routes(resource) do
    AshHateoas.Resource.Info.routes(resource)
  rescue
    _ -> []
  end

  defp description(resource) do
    Ash.Resource.Info.description(resource)
  rescue
    _ -> nil
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
