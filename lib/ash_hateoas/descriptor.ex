defmodule AshHateoas.Descriptor do
  @moduledoc """
  Builds an `AshHateoas.Affordance` from a surviving action — stage 4.

  Everything here is in-memory DSL reading: no I/O, no authorization. By the
  time a descriptor is built the gates have already decided the action belongs
  in the set.

  ## Self-documenting

  Ash already collects `description` on actions and arguments, and arguments
  carry `default`, `constraints` and `sensitive?`. Those are surfaced verbatim
  rather than re-described, under two rules:

    * only **public** arguments become fields
    * a `sensitive?` argument's `default` is **never** emitted — the field still
      appears so the client knows to supply it, without leaking the value
  """

  alias AshHateoas.{Affordance, Field, TypeMapper}

  @doc """
  Build the affordance for `action`, exposed by `route` (which may be `nil`).

  `overrides` is the author's per-action deviation map; currently only
  `:href` is honoured.
  """
  @spec build(struct(), struct() | nil, module(), keyword()) :: Affordance.t()
  def build(action, route, resource, overrides \\ []) do
    %Affordance{
      name: action.name,
      href: href(route, resource, overrides),
      method: method(route, action),
      description: action.description,
      fields: fields(action, resource),
      not_delegable?: not_delegable?(action, resource)
    }
  end

  # Declared, not derived, and read the same for every actor. The gates
  # have already decided the action belongs in the set; this only says who may
  # execute it once offered.
  defp not_delegable?(action, resource) do
    AshHateoas.Resource.Info.extension?(resource) and
      AshHateoas.Resource.Info.not_delegable?(resource, action.name)
  end

  # An author's `override :action, href: "..."` wins. Otherwise the route's
  # declared path is the href. Callers needing it host-qualified (the Hydra
  # plug, `AshHateoas.Hydra.Plug`) prefix it themselves; the backbone stays
  # transport-agnostic and emits the declared path.
  defp href(route, _resource, overrides) do
    case Keyword.get(List.wrap(overrides), :href) do
      nil -> route_path(route)
      override -> override
    end
  end

  defp route_path(route) when is_map(route), do: Map.get(route, :route)
  defp route_path(_route), do: nil

  defp method(%{method: method}, _action) when not is_nil(method), do: method
  defp method(_route, %{type: :read}), do: :get
  defp method(_route, %{type: :create}), do: :post
  defp method(_route, %{type: :update}), do: :patch
  defp method(_route, %{type: :destroy}), do: :delete
  defp method(_route, _action), do: :post

  # An action's inputs are its public ARGUMENTS plus the ATTRIBUTES it accepts.
  # Reading only arguments would tell a client to send nothing to a `create`
  # that accepts `[:title]` — the commonest shape there is.
  #
  # Attributes come first: they are the action's substance, while arguments
  # usually modify it.
  defp fields(action, resource) do
    accepted_attributes(action, resource) ++ public_arguments(action)
  end

  defp public_arguments(action) do
    action
    |> Map.get(:arguments, [])
    |> Enum.filter(&public?/1)
    |> Enum.map(&to_field/1)
  end

  defp accepted_attributes(action, resource) do
    action
    |> Map.get(:accept, [])
    |> List.wrap()
    |> Enum.map(&attribute(resource, &1))
    |> Enum.filter(&(&1 && public?(&1)))
    |> Enum.map(&to_field/1)
  end

  defp attribute(resource, name) do
    Ash.Resource.Info.attribute(resource, name)
  rescue
    _ -> nil
  end

  defp public?(input), do: Map.get(input, :public?, false)

  defp to_field(argument) do
    %Field{
      name: argument.name,
      type: TypeMapper.to_wire(argument.type),
      allow_nil?: Map.get(argument, :allow_nil?, true),
      description: Map.get(argument, :description),
      default: default_for(argument),
      constraints: constraints_for(argument)
    }
  end

  # Never emit a sensitive argument's default. Wrapped as {:ok, value} |
  # :error because nil is itself a legitimate default and the two must differ.
  defp default_for(%{sensitive?: true}), do: :error

  defp default_for(argument) do
    case Map.get(argument, :default) do
      nil -> :error
      default -> {:ok, default}
    end
  end

  # `constraints.enum` is derived from `one_of`. Other constraints are
  # passed through as a map so a client can validate up front.
  defp constraints_for(argument) do
    argument
    |> Map.get(:constraints, [])
    |> List.wrap()
    |> Enum.reduce(%{}, fn
      {:one_of, values}, acc -> Map.put(acc, :enum, values)
      {:min, value}, acc -> Map.put(acc, :min, value)
      {:max, value}, acc -> Map.put(acc, :max, value)
      {:min_length, value}, acc -> Map.put(acc, :min_length, value)
      {:max_length, value}, acc -> Map.put(acc, :max_length, value)
      {:match, %Regex{} = regex}, acc -> Map.put(acc, :pattern, Regex.source(regex))
      _other, acc -> acc
    end)
  end
end
