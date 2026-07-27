defmodule AshHateoas.Hydra.TypeMapper do
  @moduledoc """
  Maps a wire-format type name to a JSON-LD datatype IRI.

  `AshHateoas.TypeMapper` remains the single authority for Ash type → wire name
  (`:string` → `"string"`, `Ash.Type.Integer` → `"integer"`, …). This module
  only carries the second half — wire name → the datatype IRI a Hydra property
  advertises — so the Ash→wire mapping is never duplicated.

  Scalars map to `xsd:` datatypes. A `link` maps to `@id`: JSON-LD's marker that
  the value is itself an IRI (a followable resource), which is exactly what the
  `link` wire type means. Structural types (`map`, `array`, `union`) have no
  single xsd datatype and map to an `ah:` term, so the information is not lost.
  """

  alias AshHateoas.Hydra.Context

  @table %{
    "string" => "xsd:string",
    "integer" => "xsd:integer",
    "number" => "xsd:decimal",
    "boolean" => "xsd:boolean",
    "date" => "xsd:date",
    "time" => "xsd:time",
    "datetime" => "xsd:dateTime",
    "duration" => "xsd:duration",
    # A followable IRI, not a literal — JSON-LD's own marker for "value is a link".
    "link" => "@id"
  }

  @doc """
  The JSON-LD datatype IRI for a wire-format type name.

      iex> AshHateoas.Hydra.TypeMapper.to_datatype("integer")
      "xsd:integer"

      iex> AshHateoas.Hydra.TypeMapper.to_datatype("link")
      "@id"
  """
  @spec to_datatype(String.t()) :: String.t()
  def to_datatype(wire) when is_binary(wire) do
    case Map.fetch(@table, wire) do
      {:ok, datatype} -> datatype
      :error -> Context.vocab_iri(wire)
    end
  end

  @doc "The wire-name → datatype table, for tests and documentation."
  @spec table() :: %{String.t() => String.t()}
  def table, do: @table
end
