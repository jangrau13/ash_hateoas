defmodule AshHateoas.TypeMapperTest do
  use ExUnit.Case, async: true

  alias AshHateoas.TypeMapper

  describe "atom shorthands" do
    test "resolve through Ash.Type.get_type/1" do
      assert TypeMapper.to_wire(:string) == "string"
      assert TypeMapper.to_wire(:integer) == "integer"
      assert TypeMapper.to_wire(:boolean) == "boolean"
      assert TypeMapper.to_wire(:decimal) == "number"
      assert TypeMapper.to_wire(:utc_datetime) == "datetime"
      assert TypeMapper.to_wire(:date) == "date"
      assert TypeMapper.to_wire(:map) == "map"
    end
  end

  describe "module forms" do
    test "map to the same wire type as their shorthand" do
      assert TypeMapper.to_wire(Ash.Type.String) == TypeMapper.to_wire(:string)
      assert TypeMapper.to_wire(Ash.Type.Integer) == TypeMapper.to_wire(:integer)
      assert TypeMapper.to_wire(Ash.Type.Float) == "number"
    end

    test "never leak the module name onto the wire" do
      for {module, wire} <- TypeMapper.table() do
        refute wire =~ "Elixir.",
               "#{inspect(module)} maps to #{inspect(wire)}, which leaks a module name"
      end
    end
  end

  describe "arrays" do
    test "collapse to array regardless of inner type" do
      assert TypeMapper.to_wire({:array, :string}) == "array"
      assert TypeMapper.to_wire({:array, Ash.Type.Integer}) == "array"
    end
  end

  describe "the link type" do
    test "survives NewType unwrapping" do
      # ResourceLink is a NewType over :string, and `lookup/1` unwraps NewTypes
      # via `subtype_of/0`. If the table were consulted after that unwrapping,
      # this would render as "string" and the wire format would lose the only
      # thing that makes the value followable.
      assert TypeMapper.to_wire(AshHateoas.Type.ResourceLink) == "link"
      assert AshHateoas.Type.ResourceLink.subtype_of() == Ash.Type.String
    end
  end

  describe "fallback" do
    test "unknown types fall back rather than raising" do
      assert TypeMapper.to_wire(:no_such_type_exists) == TypeMapper.fallback()
      assert TypeMapper.to_wire(SomeUndefinedModule) == TypeMapper.fallback()
    end

    test "nil and non-type values fall back" do
      assert TypeMapper.to_wire(nil) == TypeMapper.fallback()
      assert TypeMapper.to_wire("not a type") == TypeMapper.fallback()
      assert TypeMapper.to_wire(123) == TypeMapper.fallback()
    end
  end
end
