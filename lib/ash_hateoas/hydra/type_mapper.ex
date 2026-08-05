defmodule AshHateoas.Hydra.TypeMapper do
  @moduledoc """
  Maps a wire-format type name to JSON-LD type metadata using standard
  ontologies: `sh:datatype` for XSD scalars, `sh:nodeKind` for link references,
  `rdfs:range` with `jsonschema:` for structural types (`ArraySchema`,
  `ObjectSchema`), and `schema:rangeIncludes` for unions.

  One term is this package's own: a script's `sh:datatype` is `ah:Script`,
  declared in `AshHateoas.Hydra.Ontology` as an `rdfs:Datatype` restricting
  `xsd:string`. There is no published datatype for "source code", and
  `xsd:string` is the statement that leaves a client reading a formula as prose.

  `AshHateoas.TypeMapper` remains the single authority for Ash type → wire name.
  This module carries only the wire-name → standard-ontology-IRI mapping.
  """

  @sh_datatype_table %{
    "string" => "xsd:string",
    "integer" => "xsd:integer",
    "number" => "xsd:decimal",
    "boolean" => "xsd:boolean",
    "date" => "xsd:date",
    "time" => "xsd:time",
    "datetime" => "xsd:dateTime",
    "duration" => "xsd:duration"
  }

  @doc """
  Returns a tagged tuple describing the type to the renderer.

      iex> type_info("integer")
      {:sh_datatype, "xsd:integer"}

      iex> type_info("link")
      {:sh_node_kind, "sh:IRI"}

      iex> type_info("array")
      {:rdfs_range, "jsonschema:ArraySchema"}

      iex> type_info("union")
      :union

      iex> type_info("unknown_thing")
      :none
  """
  @spec type_info(String.t()) ::
          {:sh_datatype, String.t()}
          | {:sh_node_kind, String.t()}
          | {:rdfs_range, String.t()}
          | :union
          | :none
  def type_info(wire) when is_binary(wire) do
    cond do
      Map.has_key?(@sh_datatype_table, wire) ->
        {:sh_datatype, @sh_datatype_table[wire]}

      wire == "link" ->
        {:sh_node_kind, "sh:IRI"}

      # A script's values are literals, so this is a datatype like any other —
      # but a *narrower* one than `xsd:string`, which is what tells a client the
      # value is source code rather than prose. The ontology declares
      # `ah:Script` as an `rdfs:Datatype` restricting `xsd:string`, so a
      # consumer that does not know the term still reads a string.
      #
      # This matters most on an operation's **inputs**, which keep their
      # `sh:datatype` (a class property's moved to the ontology in stage 2, but
      # an argument is not a property of any class). Without it, writing a
      # formula through a save operation would advertise plain text.
      wire == "script" ->
        {:sh_datatype, "ah:Script"}

      wire == "array" ->
        {:rdfs_range, "jsonschema:ArraySchema"}

      wire == "map" ->
        {:rdfs_range, "jsonschema:ObjectSchema"}

      wire == "union" ->
        :union

      true ->
        :none
    end
  end

  @doc """
  Maps a wire type to its IRI for use in `schema:rangeIncludes`.

  Unions list their member types via this function so each member's IRI can be
  included in the rangeIncludes array.

      iex> wire_to_iri("string")
      "xsd:string"

      iex> wire_to_iri("link")
      "rdfs:Resource"

      iex> wire_to_iri("map")
      "jsonschema:ObjectSchema"
  """
  @spec wire_to_iri(String.t()) :: String.t() | nil
  def wire_to_iri(wire) when is_binary(wire) do
    cond do
      Map.has_key?(@sh_datatype_table, wire) -> @sh_datatype_table[wire]
      wire == "link" -> "rdfs:Resource"
      wire == "script" -> "ah:Script"
      wire == "array" -> "jsonschema:ArraySchema"
      wire == "map" -> "jsonschema:ObjectSchema"
      true -> nil
    end
  end

  @doc "The wire-name → XSD datatype table, for tests and documentation."
  @spec sh_datatype_table() :: %{String.t() => String.t()}
  def sh_datatype_table, do: @sh_datatype_table
end
