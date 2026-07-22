defmodule AshHateoas.JsonApi.Renderer do
  @moduledoc """
  Renders affordances as JSON:API **link objects** (§5.1).

  JSON:API 1.1 does not restrict link names — "a link's relation type should be
  inferred from the name of the link" — and a link object may carry `href`,
  `rel`, `title`, `type`, `hreflang` and `meta`. Affordances *are* links, so
  this is the correct slot; serializing them into `attributes` would not be.

      "links": {
        "approve": {
          "href": "/documents/123/approve",
          "rel": "https://ash-hateoas.org/rels/approve",
          "title": "Approve this document so it can be published.",
          "meta": {
            "method": "PATCH",
            "fields": [
              {"name": "notify", "type": "boolean", "required": false}
            ]
          }
        }
      }

  The vocabulary aligns with prior art — `spring-hateoas-jsonapi` renders
  affordances as link `meta` with `name`, `httpMethod` and
  `inputProperties[{name,type,required}]` — and with HAL-FORMS / Siren
  `actions`.

  Note `required` in the output: `AshHateoas.Field` carries Ash's `allow_nil?`,
  and the inversion to the wire's `required` happens here, at the edge.
  """

  alias AshHateoas.{Affordance, Field}

  @rel_base "https://ash-hateoas.org/rels"

  @doc """
  Render an affordance envelope as a map of link name → link object.

  `path_params` substitutes route parameters — `"/documents/:id/approve"` with
  `%{"id" => "123"}` becomes `"/documents/123/approve"`. A prefix (the domain's
  JSON:API `prefix`) is prepended when given.
  """
  @spec render(%{atom() => Affordance.t()}, keyword()) :: %{String.t() => map()}
  def render(affordances, opts \\ []) do
    path_params = Keyword.get(opts, :path_params, %{})
    prefix = Keyword.get(opts, :prefix)

    Map.new(affordances, fn {name, affordance} ->
      {to_string(name), link_object(affordance, path_params, prefix)}
    end)
  end

  @doc """
  The relation type URI for an action name.

  Giving each affordance a real hypermedia relation type is what makes it
  self-describing rather than a private convention.
  """
  @spec rel(atom() | String.t()) :: String.t()
  def rel(action_name), do: "#{@rel_base}/#{action_name}"

  defp link_object(%Affordance{} = affordance, path_params, prefix) do
    %{
      "href" => href(affordance.href, path_params, prefix),
      "rel" => rel(affordance.name),
      "meta" => meta(affordance)
    }
    |> put_unless_nil("title", affordance.description)
  end

  defp meta(%Affordance{} = affordance) do
    %{
      "method" => affordance.method |> to_string() |> String.upcase(),
      "fields" => Enum.map(affordance.fields, &field/1)
    }
    |> put_if(affordance.multi_step?, "multiStep", true)
    |> put_if(affordance.not_delegable?, "notDelegable", true)
  end

  defp field(%Field{} = field) do
    %{
      "name" => to_string(field.name),
      "type" => field.type,
      # The polarity inversion lives here: Ash says allow_nil?, the wire says
      # required. Everything upstream of this line reads like the resource DSL.
      "required" => not field.allow_nil?
    }
    |> put_unless_nil("description", field.description)
    |> put_default(field.default)
    |> put_constraints(field.constraints)
  end

  # A sensitive argument's default is :error and must never reach the wire (R4).
  defp put_default(map, {:ok, value}), do: Map.put(map, "default", encodable(value))
  defp put_default(map, :error), do: map

  defp put_constraints(map, constraints) when map_size(constraints) == 0, do: map

  defp put_constraints(map, constraints) do
    Map.put(
      map,
      "constraints",
      Map.new(constraints, fn {key, value} -> {to_string(key), encodable(value)} end)
    )
  end

  defp href(nil, _path_params, _prefix), do: nil

  defp href(path, path_params, prefix) do
    path
    |> substitute(path_params)
    |> prepend(prefix)
  end

  # Route paths carry `:id`-style params; the serialized record supplies values.
  defp substitute(path, path_params) when map_size(path_params) == 0, do: path

  defp substitute(path, path_params) do
    Enum.reduce(path_params, path, fn {key, value}, acc ->
      String.replace(acc, ":#{key}", to_string(value))
    end)
  end

  defp prepend(path, nil), do: path
  defp prepend(path, ""), do: path

  defp prepend(path, prefix) do
    String.trim_trailing(prefix, "/") <> path
  end

  # Atoms and other terms must survive Jason.encode!/1 after the merge.
  defp encodable(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: to_string(value)

  defp encodable(value) when is_list(value), do: Enum.map(value, &encodable/1)
  defp encodable(value), do: value

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp put_if(map, false, _key, _value), do: map
  defp put_if(map, _true, key, value), do: Map.put(map, key, value)
end
