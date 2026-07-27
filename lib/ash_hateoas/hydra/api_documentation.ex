defmodule AshHateoas.Hydra.ApiDocumentation do
  @moduledoc """
  Builds the `hydra:ApiDocumentation` — the machine-readable description of the
  API a generic client discovers first (via the `Link` header) and dereferences
  to learn the API's classes, their properties, and their operations.

  Everything here is derived from what the resources already declare, per R1:

    * `hydra:entrypoint` — the API's base URL.
    * `hydra:supportedClass` — one `hydra:Class` per resource carrying the
      extension, with `hydra:supportedProperty` from its public attributes and
      `hydra:supportedOperation` from its derived routes. A resource that
      declares a well-known (e.g. schema.org) type yields a **second** class
      entry keyed by that IRI too — mirroring the record node's dual `@type`, so
      a client indexing by either IRI finds a described class.

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
      |> Enum.flat_map(fn {type, resource} -> supported_classes(resource, type) end)

    %{
      "@context" => Context.context(),
      "@type" => "ApiDocumentation",
      "hydra:supportedClass" => classes
    }
    |> put_unless_nil("@id", Keyword.get(opts, :id))
    |> put_unless_nil("hydra:entrypoint", Keyword.get(opts, :entrypoint))
  end

  # A resource yields its own `vocab#` class, and — when it declares a well-known
  # (e.g. schema.org) type — a companion class keyed by that IRI too. A record
  # node is dual-typed `[vocab#Class, schema:Class]`, so a client indexing the
  # documentation by *either* IRI must find a fully-described class; the companion
  # is that second entry. Both carry `owl:equivalentClass` pointing at the other,
  # so they are declared genuinely equivalent, not merely duplicated.
  defp supported_classes(resource, type) do
    vocab_iri = Context.class_iri(type)

    case AshHateoas.Resource.Info.semantic_type(resource) do
      nil ->
        [supported_class(resource, type)]

      semantic_type ->
        primary = supported_class(resource, type)

        companion =
          primary
          |> Map.put("@id", semantic_type)
          |> Map.put("owl:equivalentClass", %{"@id" => vocab_iri})

        [primary, companion]
    end
  end

  @doc "Build one `hydra:Class` for a resource."
  @spec supported_class(module(), String.t()) :: map()
  def supported_class(resource, type) do
    %{
      "@id" => Context.class_iri(type),
      "@type" => "Class",
      "hydra:title" => type,
      "hydra:supportedProperty" => supported_properties(resource, type),
      "hydra:supportedOperation" => supported_operations(resource, type)
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
  The `hydra:SupportedProperty` list from a resource's public attributes, plus a
  `hydra:Link` property per to-many relationship the resource routes.
  """
  @spec supported_properties(module(), String.t()) :: [map()]
  def supported_properties(resource, type) do
    semantic = AshHateoas.Resource.Info.semantic_properties(resource)

    attribute_properties =
      resource
      |> public_attributes()
      |> Enum.map(fn attribute ->
        # A mapped attribute advertises the well-known property IRI directly, so a
        # client that knows the vocabulary reads the value as that property.
        property_id =
          Map.get(semantic, attribute.name) || Context.property_iri(type, attribute.name)

        %{
          "@type" => "SupportedProperty",
          # `hydra:property` ranges over rdf:Property — a reference to the
          # property. The value's datatype is a fact about the property, carried
          # alongside under an `ah:` term rather than by mistyping the reference.
          "hydra:property" => %{"@id" => property_id},
          "ah:datatype" => TypeMapper.to_datatype(AshHateoas.TypeMapper.to_wire(attribute.type)),
          "hydra:title" => to_string(attribute.name),
          "hydra:required" => not Map.get(attribute, :allow_nil?, true),
          "hydra:readable" => true,
          "hydra:writeable" => Map.get(attribute, :writable?, true)
        }
        |> put_unless_nil("hydra:description", Map.get(attribute, :description))
      end)

    attribute_properties ++ link_properties(resource, type)
  end

  # A to-many relationship (a routed `:related`) is advertised as a
  # `hydra:Link` — its `hydra:property` is a node typed `hydra:Link`, so a client
  # knows the key on a record is a followable link to a related collection, not a
  # literal value.
  defp link_properties(resource, type) do
    resource
    |> routes()
    |> Enum.filter(&(&1.type == :related))
    |> Enum.map(fn %Route{relationship: name} ->
      %{
        "@type" => "SupportedProperty",
        "hydra:property" => %{
          "@id" => Context.property_iri(type, name),
          "@type" => "hydra:Link"
        },
        "hydra:title" => to_string(name),
        "hydra:readable" => true,
        "hydra:writeable" => false
      }
    end)
  end

  @doc """
  The `hydra:supportedOperation` list from a resource's derived routes.

  Actor-independent: it describes operation shape, not availability. Reads the
  route table directly rather than the gated backbone.
  """
  @spec supported_operations(module(), String.t()) :: [map()]
  def supported_operations(resource, type) do
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
      |> put_shape(action, resource, type)
      |> put_possible_status(route, action, resource)
    end)
  end

  # The statuses an operation may return, derived from the gate chain — the
  # catalogue counterpart to the node's live gating. A resource with authorizers
  # can refuse with 403; a write can fail validation with 422; a member-targeted
  # operation can 404. Actor-independent: it lists what *could* happen, not what
  # will for a given request.
  defp put_possible_status(op, route, action, resource) do
    statuses =
      []
      |> maybe_status(authorized?(resource), 403, "Forbidden — the actor may not perform this.")
      |> maybe_status(write?(action), 422, "Unprocessable — the input failed validation.")
      |> maybe_status(member_route?(route), 404, "Not Found — no such record.")

    case statuses do
      [] -> op
      list -> Map.put(op, "hydra:possibleStatus", Enum.reverse(list))
    end
  end

  defp maybe_status(list, false, _code, _title), do: list

  defp maybe_status(list, true, code, title) do
    [%{"@type" => "Status", "hydra:statusCode" => code, "hydra:title" => title} | list]
  end

  defp authorized?(resource) do
    Ash.Resource.Info.authorizers(resource) != []
  rescue
    _ -> false
  end

  defp write?(%{type: type}) when type in [:create, :update, :destroy, :action], do: true
  defp write?(_action), do: false

  # A route addressing a specific record (`:id` in its path) can 404; a
  # collection-level route (create, index) cannot.
  defp member_route?(%Route{route: route}) when is_binary(route),
    do: String.contains?(route, ":id")

  defp member_route?(_route), do: false

  # Reuse the renderer's `expects`/`returns` derivation so the documentation
  # catalogue and the live per-node operations describe input/output identically.
  defp put_shape(op, nil, _resource, _type), do: op

  defp put_shape(op, action, resource, type) do
    rendered =
      AshHateoas.Descriptor.build(action, nil, resource)
      |> Renderer.operation(
        type: type,
        semantic_actions: AshHateoas.Resource.Info.semantic_actions(resource)
      )

    op
    |> put_unless_nil("hydra:expects", Map.get(rendered, "hydra:expects"))
    |> put_unless_nil("hydra:returns", Map.get(rendered, "hydra:returns"))
    |> put_unless_nil("schema:potentialAction", Map.get(rendered, "schema:potentialAction"))
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
