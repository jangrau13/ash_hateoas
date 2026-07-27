defmodule AshHateoas.Hydra.Renderer do
  @moduledoc """
  Projects the affordance envelope onto a resource node's Hydra operations.

  Each affordance becomes a `hydra:Operation` (`@type: "Operation"`,
  `hydra:method`, and — for a write — a `hydra:expects` describing the input as
  a `hydra:Class` with one `hydra:SupportedProperty` per field). A collection
  read with query arguments becomes a `hydra:IriTemplate`.

  ## Where an operation attaches

  Hydra's `Operation` has no target-URL property: a client invokes an operation
  against the resource node it hangs on (`@id`). Two shapes follow from that:

    * an operation whose href is the record's own URL (the REST `patch` /
      `delete` at `/:id`) attaches directly to the node's `hydra:operation` — the
      client invokes it against the node `@id`;
    * a named sub-action (`/:id/approve`) needs a distinct URL, so it becomes a
      link property (`ah:<action>`) whose `@id` is the href and whose
      `hydra:operation` carries the operation. The distinct URL stays followable.

  ## The edge inversions

  `AshHateoas.Field` carries Ash's `allow_nil?`; Hydra says `hydra:required`, so
  the inversion happens here. A sensitive field's `default` is never emitted.
  Atoms are stringified so the map survives `Jason.encode!/1`.
  """

  alias AshHateoas.{Affordance, Field}
  alias AshHateoas.Hydra.{Context, TypeMapper}

  @doc """
  Render an affordance envelope into the members to merge onto a node.

  Returns a map with a `"hydra:operation"` list for same-URL operations, plus one
  `"ah:<action>"` link-node member per named sub-action.

  ## Options

    * `:node_id` — the resource node's `@id` (its own URL). An operation whose
      href equals this attaches inline; others become link nodes.
    * `:type` — the resource type string, used to build property IRIs.
    * `:path_params` — substituted into hrefs (`%{"id" => "123"}`).
    * `:prefix` — external mount prefix prepended to every href.
  """
  @spec render(%{atom() => Affordance.t()}, keyword()) :: map()
  def render(affordances, opts \\ []) do
    node_id = Keyword.get(opts, :node_id)

    {inline, linked} =
      affordances
      |> Enum.map(fn {_name, affordance} -> {affordance, href(affordance, opts)} end)
      |> Enum.split_with(fn {_affordance, href} -> inline?(href, node_id) end)

    base = %{}

    base =
      case inline do
        [] -> base
        pairs -> Map.put(base, "hydra:operation", Enum.map(pairs, &operation(elem(&1, 0), opts)))
      end

    Enum.reduce(linked, base, fn {affordance, href}, acc ->
      Map.put(acc, "ah:#{affordance.name}", link_node(affordance, href, opts))
    end)
  end

  @doc "Render one affordance as a `hydra:Operation` node."
  @spec operation(Affordance.t(), keyword()) :: map()
  def operation(%Affordance{} = affordance, opts \\ []) do
    %{
      "@type" => "Operation",
      "hydra:method" => affordance.method |> to_string() |> String.upcase()
    }
    |> put_unless_nil("hydra:title", affordance.description)
    |> put_expects(affordance, opts)
    |> put_if(affordance.multi_step?, "multiStep", true)
    |> put_if(affordance.not_delegable?, "notDelegable", true)
  end

  # A named sub-action: a link node carrying the distinct URL and the operation.
  defp link_node(%Affordance{} = affordance, href, opts) do
    %{
      "@id" => href,
      "hydra:operation" => [operation(affordance, opts)]
    }
  end

  # A GET affordance with fields is a query interface — an IriTemplate — rather
  # than a body-carrying operation. Everything else expects a request body.
  defp put_expects(op, %Affordance{fields: []}, _opts), do: op

  defp put_expects(op, %Affordance{method: :get} = affordance, opts) do
    Map.put(op, "hydra:expects", iri_template(affordance, opts))
  end

  defp put_expects(op, %Affordance{} = affordance, opts) do
    type = Keyword.get(opts, :type)

    expected = %{
      "@type" => "Class",
      "hydra:supportedProperty" => Enum.map(affordance.fields, &supported_property(&1, type))
    }

    Map.put(op, "hydra:expects", expected)
  end

  @doc "Render one field as a `hydra:SupportedProperty`."
  @spec supported_property(Field.t(), String.t() | nil) :: map()
  def supported_property(%Field{} = field, type \\ nil) do
    %{
      "@type" => "SupportedProperty",
      "hydra:property" => property_node(field, type),
      # Ash says allow_nil?; the wire says required. The inversion lives here.
      "hydra:required" => not field.allow_nil?,
      "hydra:readable" => false,
      "hydra:writeable" => true
    }
    |> put_unless_nil("hydra:title", to_string_or_nil(field.name))
    |> put_unless_nil("hydra:description", field.description)
    |> put_default(field.default)
    |> put_constraints(field.constraints)
  end

  @doc "Render a query/search read's fields as a `hydra:IriTemplate`."
  @spec iri_template(Affordance.t(), keyword()) :: map()
  def iri_template(%Affordance{} = affordance, opts) do
    href = href(affordance, opts) || ""
    variables = Enum.map(affordance.fields, &to_string(&1.name))
    type = Keyword.get(opts, :type)

    %{
      "@type" => "IriTemplate",
      "hydra:template" => href <> template_suffix(variables),
      "hydra:variableRepresentation" => "BasicRepresentation",
      "hydra:mapping" => Enum.map(affordance.fields, &iri_template_mapping(&1, type))
    }
  end

  @doc "Render one field as a `hydra:IriTemplateMapping`."
  @spec iri_template_mapping(Field.t(), String.t() | nil) :: map()
  def iri_template_mapping(%Field{} = field, type \\ nil) do
    %{
      "@type" => "IriTemplateMapping",
      "hydra:variable" => to_string(field.name),
      "hydra:property" => property_node(field, type),
      "hydra:required" => not field.allow_nil?
    }
  end

  # A property node carries its datatype so a client knows how to read the value.
  # Without a resource type we still emit the datatype under a bare name.
  defp property_node(%Field{} = field, type) do
    id = if type, do: Context.property_iri(type, field.name), else: to_string(field.name)

    %{
      "@id" => id,
      "@type" => TypeMapper.to_datatype(field.type)
    }
  end

  defp template_suffix([]), do: ""
  defp template_suffix(variables), do: "{?" <> Enum.join(variables, ",") <> "}"

  # A sensitive argument's default is :error and must never reach the wire.
  defp put_default(map, {:ok, value}), do: Map.put(map, "ah:default", encodable(value))
  defp put_default(map, :error), do: map

  defp put_constraints(map, constraints) when map_size(constraints) == 0, do: map

  defp put_constraints(map, constraints) do
    Map.put(
      map,
      "ah:constraints",
      Map.new(constraints, fn {key, value} -> {to_string(key), encodable(value)} end)
    )
  end

  # An operation attaches inline when its href is the node's own URL (or it has
  # no href at all — the fallback path, where the node URL is all a client has).
  defp inline?(nil, _node_id), do: true
  defp inline?(href, node_id), do: href == node_id

  defp href(%Affordance{href: nil}, _opts), do: nil

  defp href(%Affordance{href: path}, opts) do
    path
    |> substitute(Keyword.get(opts, :path_params, %{}))
    |> prepend(Keyword.get(opts, :prefix))
  end

  defp substitute(path, path_params) when map_size(path_params) == 0, do: path

  defp substitute(path, path_params) do
    Enum.reduce(path_params, path, fn {key, value}, acc ->
      String.replace(acc, ":#{key}", to_string(value))
    end)
  end

  defp prepend(path, nil), do: path
  defp prepend(path, ""), do: path
  defp prepend(path, prefix), do: String.trim_trailing(prefix, "/") <> path

  # Atoms and other terms must survive Jason.encode!/1.
  defp encodable(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: to_string(value)

  defp encodable(value) when is_list(value), do: Enum.map(value, &encodable/1)
  defp encodable(value), do: value

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp put_if(map, false, _key, _value), do: map
  defp put_if(map, _true, key, value), do: Map.put(map, key, value)
end
