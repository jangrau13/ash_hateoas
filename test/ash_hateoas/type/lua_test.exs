defmodule AshHateoas.Type.LuaTest do
  @moduledoc """
  A script attribute, and what it puts on the wire.

  Three things are asserted, and the third is the one that matters: a validation
  could reject the same values, but only a *type* can say on the wire that the
  value is source code. That statement is what lets a generic client render a
  formula as something it can parse, without knowing anything about the domain
  the formula belongs to.
  """

  use ExUnit.Case, async: true

  alias AshHateoas.Hydra.ApiDocumentation
  alias AshHateoas.Lua.Parser
  alias AshHateoas.Test.JsonLd

  @vocab "https://ash-hateoas.org/vocab#"
  @hydra "http://www.w3.org/ns/hydra/core#"

  defp document, do: ApiDocumentation.build([AshHateoas.Test.Domain])

  defp declared(id) do
    Enum.find(document()["@included"], &(&1["@id"] == id))
  end

  defp create(attrs) do
    AshHateoas.Test.Document
    |> Ash.Changeset.for_create(:create, Map.merge(%{title: "t"}, attrs))
    |> Ash.create(authorize?: false)
  end

  describe "parsing" do
    test "an expression parses" do
      assert {:ok, _ast} = Parser.parse("variable[\"MI_Li\"] * 2")
    end

    test "a syntax error says where the parse stopped" do
      # An author can act on this. `luerl`'s own wording is kept for exactly
      # that reason — it names the token the parser choked on.
      assert {:error, message} = Parser.parse("1 +")
      assert message =~ "syntax error"
    end

    test "a statement is not an expression" do
      # Not a blocklist: `return local x = 1` simply does not parse, so Lua's
      # own grammar refuses this and no rule of ours has to.
      assert {:error, _} = Parser.parse("local x = 1")
      assert {:error, _} = Parser.parse("for i = 1, 10 do end")
    end

    test "a chunk admits what an expression does not" do
      # The distinction is Lua's, which is why it lives in the parser rather
      # than in any domain. An attribute wanting programs asks for `:chunk`.
      assert {:ok, _ast} = Parser.parse("local x = 1", :chunk)
    end

    test "a numeral in scientific notation keeps its exact value" do
      # `luerl_scan.xrl:255` *computes* `DF * math:pow(10, Exp)` rather than
      # reading the literal, so `9.22e5` scans as `922000.0000000001`. Measured:
      # 54 of 891 two-digit mantissa/exponent pairs are affected.
      #
      # It matters because the value is **stored**. Rendering a parsed numeral
      # writes the error back into the text, so it is permanent rather than a
      # rounding artefact of one calculation.
      assert {:ok, {:NUMERAL, _line, 922_000.0}} = Parser.parse("9.22e5")
      assert {:ok, {:NUMERAL, _line, 1.0e-8}} = Parser.parse("1e-8")
    end

    test "repairing one numeral does not disturb another" do
      # The pairing is keyed on what the scanner made of each literal, not on
      # position: a numeral token carries no text, so matching the nth literal
      # to the nth float token hands `1.5` the repair meant for `9.22e5`. That
      # produced a wrong tree silently, which is why the assertion is on every
      # numeral in one expression rather than on a single value.
      assert {:ok, ast} = Parser.parse("2013 + 9.22e5 * 1.5 + 3.3e6")

      assert {:op, _, :+,
              {:op, _, :+, {:NUMERAL, _, 2013},
               {:op, _, :*, {:NUMERAL, _, 922_000.0}, {:NUMERAL, _, 1.5}}},
              {:NUMERAL, _, 3_300_000.0}} = ast
    end
  end

  describe "the cast" do
    test "a parsing script is stored unchanged" do
      assert {:ok, document} = create(%{formula: "stock[\"Prey\"] * 2"})
      assert document.formula == "stock[\"Prey\"] * 2"
    end

    test "a syntax error is refused at the moment it is written" do
      # The point of the type over a later check: this fails on the write, not
      # at whatever future moment something tries to read the value.
      assert {:error, %Ash.Error.Invalid{} = error} = create(%{formula: "1 +"})
      assert Exception.message(error) =~ "syntax error"
    end

    test "nil is allowed" do
      assert {:ok, document} = create(%{formula: nil})
      assert is_nil(document.formula)
    end

    test "a stored value reads back without re-parsing" do
      # Re-parsing on read would spend the cost again to learn what the write
      # already established, and would make a bad row unreadable rather than
      # findable.
      {:ok, written} = create(%{formula: "1 + 2"})
      assert {:ok, read} = Ash.get(AshHateoas.Test.Document, written.id, authorize?: false)
      assert read.formula == "1 + 2"
    end
  end

  describe "the wire says the value is a script" do
    test "ah:Script is declared as a datatype restricting xsd:string" do
      # A datatype rather than a class: the values are literals. A consumer that
      # does not know the term still reads a string, because that is what it is
      # declared to restrict.
      script = declared("ah:Script")

      assert script["@type"] == "rdfs:Datatype"
      assert script["owl:onDatatype"] == %{"@id" => "xsd:string"}
    end

    test "a script property ranges on ah:Script, not xsd:string" do
      property = declared("#{@vocab}document/formula")

      assert property["@type"] == "owl:DatatypeProperty"
      assert property["rdfs:range"] == %{"@id" => "ah:Script"}
    end

    test "the property states which language it is" do
      # "It is code" is not actionable on its own — a client that wants to
      # parse, highlight or complete needs to know the grammar.
      assert declared("#{@vocab}document/formula")["ah:scriptLanguage"] == "lua"
    end

    test "an ordinary string property still ranges on xsd:string" do
      # The negative half: this must narrow scripts specifically, not widen
      # every string into a script.
      assert declared("#{@vocab}document/body")["rdfs:range"] == %{"@id" => "xsd:string"}
    end

    test "the declaration survives expansion as triples" do
      # The standing rule, and the reason for it: `"ah:Script"` is a *string*
      # until a processor resolves the prefix, and an unbound prefix is dropped
      # in silence — leaving JSON that reads perfectly and means nothing.
      property =
        document()
        |> JsonLd.nodes()
        |> Enum.find(&(&1["@id"] == "#{@vocab}document/formula" and map_size(&1) > 1))

      assert JsonLd.values(property, "http://www.w3.org/2000/01/rdf-schema#range") ==
               ["#{@vocab}Script"]

      assert JsonLd.values(property, "#{@vocab}scriptLanguage") == ["lua"]
    end

    test "ah:Script resolves to a datatype in the graph" do
      node =
        document()
        |> JsonLd.nodes()
        |> Enum.find(&(&1["@id"] == "#{@vocab}Script" and map_size(&1) > 1))

      assert "http://www.w3.org/2000/01/rdf-schema#Datatype" in List.wrap(node["@type"])

      assert JsonLd.values(node, "http://www.w3.org/2002/07/owl#onDatatype") ==
               ["http://www.w3.org/2001/XMLSchema#string"]
    end
  end

  describe "the wire type" do
    test "a script does not collapse to string" do
      # `Lua` is a `NewType` over `:string`, so it sits *before* the unwrapping
      # in the table — exactly as `ResourceLink` does. Unwrapped it would be
      # "string", which is the state that leaves a client reading prose.
      assert AshHateoas.TypeMapper.to_wire(AshHateoas.Type.Lua) == "script"
    end

    test "a write input advertises the script datatype" do
      # A class property's `sh:datatype` moved to the ontology in stage 2, but
      # an argument is not a property of any class — so an input keeps its own,
      # and without this a formula written through an operation would advertise
      # plain text.
      assert AshHateoas.Hydra.TypeMapper.type_info("script") == {:sh_datatype, "ah:Script"}
    end
  end

  describe "a write input states its language too" do
    # The datatype and the language are one statement split in half, and an
    # input was getting only the first half. A client reading `ah:Script`
    # learned the value is code and not which grammar to read it with — enough
    # to stop rendering it as prose, not enough to parse, highlight or
    # complete it.
    #
    # It cannot be recovered from the ontology the way a class property's
    # range is: an argument is not a property of any class, so nothing
    # declares it. The language travels on the usage site for the same reason
    # `sh:datatype` does.
    defp inputs(title) do
      document()["hydra:supportedClass"]
      |> Enum.flat_map(&List.wrap(&1["hydra:supportedOperation"]))
      |> Enum.flat_map(fn operation ->
        operation["hydra:expects"]
        |> List.wrap()
        |> Enum.flat_map(&List.wrap(&1["hydra:supportedProperty"]))
      end)
      |> Enum.filter(&(&1["hydra:title"] == title))
    end

    test "a script input names the language beside the datatype" do
      properties = inputs("formula")
      assert properties != [], "the fixture no longer writes a script through an operation"

      for property <- properties do
        assert property["sh:datatype"] == "ah:Script"
        assert property["ah:scriptLanguage"] == "lua"
      end
    end

    test "every operation accepting it says so, not merely the first" do
      # `formula` is accepted by both `create` and `update`, and the failure
      # mode here is one emitter path left silent while another is fixed.
      assert length(inputs("formula")) >= 2
    end

    test "an ordinary string input names no language" do
      # The negative half. `body` is prose and must stay prose — a language on
      # it would tell a client to parse a description as Lua.
      for property <- inputs("body") do
        refute Map.has_key?(property, "ah:scriptLanguage")
      end
    end

    test "the language survives expansion as a triple" do
      # The standing rule: `"ah:scriptLanguage"` is a string until a processor
      # resolves the prefix, and an unbound prefix is dropped in silence —
      # leaving JSON that reads perfectly and says nothing.
      #
      # Anchored to the *input* node specifically, by the property it describes
      # and by `hydra:writable`, so the class property's own declaration cannot
      # satisfy it. That declaration states the same fact from the ontology
      # side and is asserted separately above; this is the usage site, which is
      # the only place an argument's language can live.
      inputs =
        document()
        |> JsonLd.nodes()
        |> Enum.filter(fn node ->
          "#{@vocab}document/formula" in JsonLd.values(node, "#{@hydra}property") and
            JsonLd.values(node, "#{@hydra}writable") == [true] and
            JsonLd.values(node, "#{@hydra}readable") == [false]
        end)

      assert inputs != [], "the formula input did not survive expansion at all"

      for node <- inputs do
        assert JsonLd.values(node, "#{@vocab}scriptLanguage") == ["lua"]
      end
    end
  end
end
