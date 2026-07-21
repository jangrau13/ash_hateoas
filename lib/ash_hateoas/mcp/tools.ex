defmodule AshHateoas.Mcp.Tools do
  @moduledoc """
  Projects affordances into MCP tool descriptors (§5.2).

  An MCP tool *is* an affordance: "which tools should this agent be offered,
  given the current state?" is the question the backbone already answers. The
  tool list at any moment is the affordance set for the session's position.

  ## Why not `AshAi.exposed_tools/1`

  `exposed_tools/1` filters by `Ash.can?` but not by state, so unmodified it
  offers a transition from states it is not legal from. It also passes
  `maybe_is: true, run_queries?: false, pre_flight?: false`, a deliberately
  laxer posture suited to advisory listing.

  The adapter therefore renders the **backbone's** set rather than delegating.
  That is §5's rule — an adapter contains no affordance logic of its own — and
  it is what brings the state gate to MCP.

  ## inputSchema shape

  `ash_ai` nests action inputs under a single top-level `input` property rather
  than splicing them at the root, and round-trips the schema through
  `Jason.encode!/1` + `Jason.decode!/1` to normalise atom keys to strings. This
  module produces the same shape so a client cannot tell our tools from
  ash_ai's.
  """

  alias AshHateoas.{Affordance, Field}

  @doc """
  Render an affordance envelope as MCP tool descriptors.

  `prefix` namespaces the tool names, so `:approve` on a `document` becomes
  `"document_approve"` — MCP tool names are flat and must not collide across
  resources.
  """
  @spec render(%{atom() => Affordance.t()}, String.t() | nil, keyword()) :: [map()]
  def render(affordances, prefix \\ nil, opts \\ []) do
    subject = Keyword.get(opts, :subject)

    affordances
    |> Enum.sort_by(fn {name, _affordance} -> name end)
    |> Enum.map(fn {_name, affordance} -> tool(affordance, prefix, subject) end)
  end

  defp tool(%Affordance{} = affordance, prefix, subject) do
    %{
      "name" => name(affordance.name, prefix),
      "description" => description(affordance),
      "inputSchema" => input_schema(affordance, subject)
    }
  end

  defp name(action_name, nil), do: to_string(action_name)
  defp name(action_name, prefix), do: "#{prefix}_#{action_name}"

  # MCP clients show this to a model, so an action with no description still
  # needs something actionable rather than an empty string.
  defp description(%Affordance{description: nil, name: name}), do: "Run the #{name} action."
  defp description(%Affordance{description: description}), do: String.trim(description)

  # Built with atom keys then round-tripped, exactly as ash_ai does — post
  # processing that expects string keys would silently no-op otherwise.
  defp input_schema(%Affordance{fields: []}, subject) do
    %{
      type: :object,
      properties: subject_property(subject),
      required: subject_required(subject),
      additionalProperties: false
    }
    |> normalize()
  end

  defp input_schema(%Affordance{fields: fields}, subject) do
    properties = Map.new(fields, fn field -> {field.name, property(field)} end)

    required =
      fields
      |> Enum.reject(& &1.allow_nil?)
      |> Enum.map(& &1.name)

    %{
      type: :object,
      properties:
        Map.merge(
          %{
            input: %{
              type: :object,
              properties: properties,
              additionalProperties: false,
              required: required
            }
          },
          subject_property(subject)
        ),
      required: [:input] ++ subject_required(subject),
      additionalProperties: false
    }
    |> normalize()
  end

  # A record-level affordance must say WHICH record it acts on.
  #
  # The session knows — that is what focus is for — but the session is ours,
  # while `tools/call` is executed by ash_ai, which has no view of it. A tool
  # rendered without an identifier therefore advertises a call that can never
  # resolve its subject, and fails with "could not be found". So the identity
  # travels in the schema, where the executor can actually see it.
  defp subject_property(nil), do: %{}

  defp subject_property(%{field: field, value: value}) do
    %{
      field => %{
        type: :string,
        description: "Identifies the record this acts on.",
        const: to_string(value)
      }
    }
  end

  defp subject_required(nil), do: []
  defp subject_required(%{field: field}), do: [field]

  defp property(%Field{} = field) do
    %{type: json_type(field.type)}
    |> put_unless_nil(:description, field.description)
    |> put_enum(field.constraints)
    |> put_default(field.default)
  end

  # The wire types the type mapper produces, expressed as JSON Schema types.
  defp json_type("integer"), do: :integer
  defp json_type("number"), do: :number
  defp json_type("boolean"), do: :boolean
  defp json_type("array"), do: :array
  defp json_type("map"), do: :object
  defp json_type(_other), do: :string

  defp put_enum(property, %{enum: values}) when is_list(values) do
    Map.put(property, :enum, Enum.map(values, &to_string/1))
  end

  defp put_enum(property, _constraints), do: property

  # A sensitive argument's default is :error and must never be emitted (R4).
  defp put_default(property, {:ok, value}), do: Map.put(property, :default, encodable(value))
  defp put_default(property, :error), do: property

  defp encodable(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: to_string(value)

  defp encodable(value) when is_list(value), do: Enum.map(value, &encodable/1)
  defp encodable(value), do: value

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp normalize(schema), do: schema |> Jason.encode!() |> Jason.decode!()
end
