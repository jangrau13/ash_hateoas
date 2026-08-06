defmodule AshHateoas.TypeMapper do
  @moduledoc """
  Maps an Ash type to the string that appears in an affordance's wire format.

  Deliberately an **explicit table**, per the `ash_typescript` precedent: an Ash
  type may arrive as an atom shorthand (`:string`) or a module
  (`Ash.Type.String`), and calling `to_string/1` on the module form would leak
  `Elixir.Ash.Type.String` into the wire format.

  Normalisation of the atom form is delegated to `Ash.Type.get_type/1` rather
  than duplicated here — Ash owns that mapping and it changes as types are
  added. This module owns only the module → wire-name half.

  Unmapped types fall back to `"string"`, which every transport can represent,
  rather than raising: a resource must not fail to render affordances because it
  uses a custom type.
  """

  @typedoc "The wire-format type name for a field"
  @type wire_type :: String.t()

  @table %{
    # Checked before the NewType unwrapping below, which would otherwise
    # resolve this to its `:string` subtype and discard the one thing the
    # wire format needs to carry: that the value is followable.
    AshHateoas.Type.ResourceLink => "link",
    # Same reason, and the same placement: unwrapped this is a `:string`, and
    # "string" is exactly the state that leaves a client reading a formula as
    # prose. The wire has to keep the fact that the value is source code.
    AshHateoas.Type.Lua => "script",
    Ash.Type.String => "string",
    Ash.Type.CiString => "string",
    Ash.Type.Atom => "string",
    Ash.Type.UUID => "string",
    Ash.Type.UUIDv7 => "string",
    Ash.Type.Binary => "string",
    Ash.Type.UrlEncodedBinary => "string",
    Ash.Type.File => "string",
    Ash.Type.Module => "string",
    Ash.Type.Function => "string",
    Ash.Type.Term => "string",
    Ash.Type.DurationName => "string",
    Ash.Type.Integer => "integer",
    Ash.Type.Float => "number",
    Ash.Type.Decimal => "number",
    Ash.Type.Boolean => "boolean",
    Ash.Type.Date => "date",
    Ash.Type.Time => "time",
    Ash.Type.TimeUsec => "time",
    Ash.Type.UtcDatetime => "datetime",
    Ash.Type.UtcDatetimeUsec => "datetime",
    Ash.Type.NaiveDatetime => "datetime",
    Ash.Type.Duration => "duration",
    Ash.Type.Map => "map",
    Ash.Type.Keyword => "map",
    Ash.Type.Struct => "map",
    Ash.Type.Union => "union",
    Ash.Type.Tuple => "array",
    Ash.Type.Vector => "array"
  }

  @fallback "string"

  @doc """
  Returns the wire-format type name for an Ash type.

  Accepts atom shorthands, type modules, `{:array, type}` tuples, and
  `Ash.Type.NewType` subtypes (which are unwrapped to their underlying type).

      iex> AshHateoas.TypeMapper.to_wire(:string)
      "string"

      iex> AshHateoas.TypeMapper.to_wire(Ash.Type.Integer)
      "integer"

      iex> AshHateoas.TypeMapper.to_wire({:array, :boolean})
      "array"
  """
  @spec to_wire(term()) :: wire_type()
  def to_wire({:array, _inner}), do: "array"

  def to_wire(type) when is_atom(type) and not is_nil(type) do
    type
    |> normalize()
    |> lookup()
  end

  def to_wire(_other), do: @fallback

  # Ash.Type.get_type/1 resolves short names (:string -> Ash.Type.String) and
  # passes modules through. It raises for unknown atoms, so guard with a rescue
  # rather than letting a custom type break rendering.
  defp normalize(type) do
    Ash.Type.get_type(type)
  rescue
    _ -> type
  end

  defp lookup(module) do
    case Map.fetch(@table, module) do
      {:ok, wire} ->
        wire

      :error ->
        # NewType subtypes wrap a built-in; unwrap once and retry.
        if function_exported?(module, :subtype_of, 0) do
          module |> apply(:subtype_of, []) |> to_wire()
        else
          @fallback
        end
    end
  end

  @doc """
  The language a script type's values are written in, or `nil`.

  Asked of the *type*, by calling `script_language/0` on it, rather than
  matched against a module name — so a second script type is understood here
  with no edit.

  This is the other half of `to_wire/1` for a script. `to_wire/1` answers "is
  it code", which stops a client rendering a formula as prose; this answers
  "which grammar", which is what a client needs before it can parse, highlight
  or complete one. Neither is recoverable from the other.

  An array of scripts reports its element's language, matching `to_wire/1`'s
  own unwrapping: an array is a container, and the language belongs to what it
  contains.

      iex> AshHateoas.TypeMapper.script_language(AshHateoas.Type.Lua)
      "lua"

      iex> AshHateoas.TypeMapper.script_language(:string)
      nil
  """
  @spec script_language(term()) :: String.t() | nil
  def script_language({:array, inner}), do: script_language(inner)

  def script_language(type) when is_atom(type) and not is_nil(type) do
    module = normalize(type)

    cond do
      exports?(module, :script_language) ->
        module.script_language()

      # A NewType over a script is still a script. Unwrap once and retry, the
      # same descent `lookup/1` makes for the wire name.
      exports?(module, :subtype_of) ->
        module |> apply(:subtype_of, []) |> script_language()

      true ->
        nil
    end
  rescue
    _ -> nil
  end

  def script_language(_other), do: nil

  # `function_exported?/3` answers for a *loaded* module and says false for one
  # merely compiled, so under lazy loading a type is asked before it is loaded
  # and reports no language — leaving the wire silent about a script while
  # `to_wire/1`, which is a table lookup, still calls it one. Loading first is
  # what makes the two agree.
  defp exports?(module, function) do
    Code.ensure_loaded?(module) and function_exported?(module, function, 0)
  end

  @doc "The full module → wire-name table, for tests and documentation."
  @spec table() :: %{module() => wire_type()}
  def table, do: @table

  @doc "The wire type used when a type is not in the table."
  @spec fallback() :: wire_type()
  def fallback, do: @fallback
end
