defmodule AshHateoas.LuaScriptTest do
  @moduledoc """
  Declaring what a script may reference, and reading a script for what it does.

  The type parses; this extension says what the *names inside* mean. Without it
  a reference is a string that happens to look structured, and every consumer
  has to guess — which is the state the whole stage exists to end.
  """

  use ExUnit.Case, async: true

  alias AshHateoas.Lua.{Parser, Walk}
  alias AshHateoas.LuaScript.Info
  alias AshHateoas.Test.Scripted.{Author, Formula, Function}

  defp ast!(source) do
    {:ok, ast} = Parser.parse(source)
    ast
  end

  describe "the declaration" do
    test "the script attribute is readable" do
      assert Info.script(Formula) == :body
      assert Info.script?(Formula)
    end

    test "a resource without the extension answers rather than raising" do
      # Every accessor answers for a resource that never opted in, so a caller
      # does not have to check for the extension first.
      refute Info.script?(Author)
      assert Info.script(Author) == nil
      assert Info.binds(Author) == []
      assert Info.functions(Author) == nil
    end

    test "binds name their resource and key" do
      assert [%{name: :author, resource: Author, key: :name}] = Info.binds(Formula)
    end

    test "the callable functions are a resource, not a list" do
      # A resource can be *fetched*, so a client reads the signatures instead of
      # being handed names it cannot check against.
      assert Info.functions(Formula) == Function
    end

    test "binds are keyed for the walk" do
      assert %{author: %{resource: Author}} = Info.bind_map(Formula)
    end
  end

  describe "reading a script" do
    test "a reference is extracted with its bind and key" do
      ast = ast!(~s|author["Ada Lovelace"] * 2|)
      assert Walk.references(ast, [:author]) == [author: "Ada Lovelace"]
    end

    test "a name with spaces and punctuation needs no escaping" do
      # It is a string key, which is most of why Lua's syntax was adopted: 82%
      # of real names cannot be written as bare identifiers.
      ast = ast!(~s|author["Ada (née Byron), Lovelace"]|)
      assert Walk.references(ast, [:author]) == [author: "Ada (née Byron), Lovelace"]
    end

    test "an accented name survives as UTF-8" do
      # The regression this needs a test for: `luerl`'s scanner takes a
      # charlist and writes each element back as one *byte*, so a codepoint
      # list turns `née` into Latin-1 and every accented name is silently
      # corrupted. Handing it the bytes instead keeps UTF-8 intact.
      #
      # Invisible on ASCII — which is why the assertion is on validity, not
      # only on equality.
      ast = ast!(~s|author["Ada née Byron"]|)
      assert [{:author, name}] = Walk.references(ast, [:author])

      assert String.valid?(name)
      assert name == "Ada née Byron"
    end

    test "two binds may hold the same name without collision" do
      # The kind is in the syntax, so no prefix convention is needed to keep
      # `author["Ada"]` and `publisher["Ada"]` apart.
      ast = ast!(~s|author["Ada"] + publisher["Ada"]|)

      assert Walk.references(ast, [:author, :publisher]) == [
               author: "Ada",
               publisher: "Ada"
             ]
    end

    test "a reference inside a call is still found" do
      # The walk descends into argument lists, so nesting does not hide a
      # reference. A clause-per-construct walk would miss this by finding
      # nothing rather than by failing.
      ast = ast!(~s|round(author["Ada"])|)
      assert Walk.references(ast, [:author]) == [author: "Ada"]
    end

    test "a call is read with its arity" do
      assert Walk.calls(ast!(~s|min(1, 2, 3)|)) == [{"min", 3}]
    end

    test "a subscript and a call are told apart" do
      # `luerl` spells both `:.`, distinguished by what follows the name. This
      # is the trap: matching on `:functioncall` alone finds zero calls, and
      # fails by finding nothing rather than by raising.
      ast = ast!(~s|sqrt(author["Ada"])|)

      assert Walk.references(ast, [:author]) == [author: "Ada"]
      assert Walk.calls(ast) == [{"sqrt", 1}]
    end
  end

  describe "checking a script" do
    test "a bound reference and a declared call pass" do
      ast = ast!(~s|sqrt(author["Ada"]) * 2|)
      assert Walk.check(ast, binds: [:author], functions: %{"sqrt" => [1]}) == :ok
    end

    test "an unbound subscript is refused, and says what is bound" do
      ast = ast!(~s|publisher["Ada"]|)

      assert {:error, [message]} = Walk.check(ast, binds: [:author], functions: %{})
      assert message =~ "publisher is not bound"
      assert message =~ "bound: author"
    end

    test "a bare name is refused with the spelling that would work" do
      # In an expression there is nothing a bare name can be: no variable was
      # declared, and a reference needs a key.
      ast = ast!(~s|author + 1|)

      assert {:error, [message]} = Walk.check(ast, binds: [:author], functions: %{})
      assert message =~ ~s|write author["…"]|
    end

    test "a valid reference is not reported as a bare name" do
      # The head of a subscript is a `{:NAME, …}` node the walk reaches like any
      # other child, so reading it as a bare name refuses every correct script.
      # Found by probing, and the failure is that valid input is rejected.
      ast = ast!(~s|author["Ada"] * sqrt(2)|)
      assert Walk.check(ast, binds: [:author], functions: %{"sqrt" => [1]}) == :ok
    end

    test "an unknown function is refused" do
      ast = ast!(~s|frobnicate(1)|)

      assert {:error, [message]} = Walk.check(ast, binds: [], functions: %{"sqrt" => [1]})
      assert message =~ "there is no function named frobnicate"
    end

    test "a wrong arity is refused, naming what is accepted" do
      ast = ast!(~s|min(1)|)

      assert {:error, [message]} = Walk.check(ast, binds: [], functions: %{"min" => [2, 3]})
      assert message =~ "min takes 2 or 3 arguments, given 1"
    end

    test "every problem is reported, not the first" do
      # An author fixing one at a time learns about the next only by trying
      # again, which turns one round trip into several.
      ast = ast!(~s|publisher["Ada"] + frobnicate(1)|)

      assert {:error, messages} = Walk.check(ast, binds: [:author], functions: %{})
      assert length(messages) == 2
    end

    test "no function declared means no call is allowed" do
      # The honest default: an unchecked call is a failure deferred to whoever
      # reads the script next.
      ast = ast!(~s|sqrt(1)|)
      assert {:error, [_]} = Walk.check(ast, binds: [], functions: %{})
    end
  end

  describe "the citation resource is generated from the binds" do
    alias AshHateoas.Test.Scripted.Formula.Citation

    test "a resource is generated beside the script" do
      # Ash has no precedent for generating a resource — even `many_to_many`
      # requires the join resource hand-written and named via `through` — so
      # this asserts the generated module really is one, rather than a module
      # that merely exists.
      assert Ash.Resource.Info.resource?(Citation)
    end

    test "each bind becomes a relationship and a foreign key" do
      # The reason for generating rather than hand-writing: every column here
      # restates a bind, and written by hand the two drift. A bind with no
      # column is a reference that cannot be stored; a column with no bind is a
      # foreign key to something no script can name. Neither shows until a
      # write fails.
      assert %{destination: Author} = Ash.Resource.Info.relationship(Citation, :author)

      names = Citation |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)
      assert :author_id in names
    end

    test "the citation links back to the script it belongs to" do
      # Not to the *cited* resource's owner: a citation names a record, and the
      # script belongs to one too, so hanging both off the same columns would
      # make `author_id` mean two things at once.
      # Named `script` rather than after the script *attribute*: the attribute
      # is a domain's word — `value`, `body`, `rule` — and putting it in a
      # generated relationship would make every consumer read a different name
      # for the same edge.
      assert %{destination: Formula} = Ash.Resource.Info.relationship(Citation, :script)
    end

    test "every generated foreign key is writable" do
      # `:*` accepts only *public* attributes, so a non-public `belongs_to`
      # generates a column no create can set — every citation write refused,
      # reported as a missing input rather than a missing declaration. Found by
      # writing one: the resource looked correct in every other respect.
      for name <- [:script, :author] do
        assert %{public?: true} = Ash.Resource.Info.relationship(Citation, name),
               "#{name} must be public, or its foreign key cannot be written"
      end
    end

    test "kind is constrained to exactly the declared binds" do
      kind = Ash.Resource.Info.attribute(Citation, :kind)

      assert kind.constraints[:one_of] == [:author]
    end

    test "the name outlives the record it named" do
      # While the citation resolves this is redundant with the target's own
      # name, and that is not what it is for: a cited record may be deleted,
      # the foreign key nilified, and the script still says what it referred to
      # — a visible hole rather than a silently lost reference.
      assert %{allow_nil?: false} = Ash.Resource.Info.attribute(Citation, :name)
    end

    test "a citation is not creatable over HTTP" do
      # Cast with the script it belongs to. A citation with no script around it
      # references nothing.
      actions = Citation |> AshHateoas.Resource.Info.routes() |> Enum.map(& &1.action)

      assert Enum.uniq(actions) == [:read]
    end
  end

  describe "what the declaration refuses at compile time" do
    # Each of these is a way the section could be configured and inert — a
    # script that looks bound and resolves to nothing, or to the wrong record.

    # Spark reports a verifier failure through the parallel module checker, so
    # it reaches stderr rather than raising at the compile call — the idiom
    # `derive_action_routes_test` already uses.
    #
    # **`capture_io(:stderr, …)` captures the group leader, not this module.**
    # Under `async: true` another file compiling a module at the same moment
    # writes into the same capture, so the output is this compile's *plus*
    # whatever a neighbour happened to emit. Harmless for a positive match —
    # a `DslError` naming this module is still in there — and fatal for a
    # `refute`, which reads a stray warning from an unrelated test as a
    # failure here. Measured: seed 226336 caught `AshHateoasBogusUnrouted1991`
    # and `AshHateoas.ResourceTest.SoleGet` in this capture.
    #
    # So the module's own name comes back with the output, and an assertion
    # that must be sure the compile was *clean* scopes to it.
    defp compile(body) do
      name = "AshHateoasBadScript#{System.unique_integer([:positive])}"

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule #{name} do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshHateoas.Resource, AshHateoas.LuaScript]

            hateoas do
              warn_on_missing_authorizers?(false)
            end

          #{body}
          end
          """)
        end)

      {name, stderr}
    end

    # The whole capture. Safe for a *positive* match: this module's own error
    # is in there, and a neighbour cannot supply the wording being asserted —
    # every message below names the offending attribute or bind.
    defp stderr({_name, stderr}), do: stderr

    # The lines of `stderr` belonging to `name`'s own compilation.
    #
    # A message is one or more lines, and only the first names the module —
    # so a blank line ends the message rather than the next line starting a
    # new one. Anything naming a *different* module starts a message this
    # compile did not produce.
    defp own_output({name, stderr}) do
      stderr
      |> String.split("\n")
      |> Enum.reduce({[], false}, fn line, {kept, mine?} ->
        cond do
          String.trim(line) == "" -> {kept, false}
          String.contains?(line, name) -> {[line | kept], true}
          mine? -> {[line | kept], true}
          true -> {kept, false}
        end
      end)
      |> elem(0)
      |> Enum.reverse()
      |> Enum.join("\n")
    end

    test "a script naming no attribute fails the build" do
      compiled =
        compile("""
          lua do
            script :missing
          end

          attributes do
            uuid_primary_key :id
          end
        """)

      assert stderr(compiled) =~ "DslError"
      assert stderr(compiled) =~ "does not exist"
      assert stderr(compiled) =~ ":missing", "the diagnostic must name the offending attribute"
    end

    test "a script on a plain string fails the build" do
      # The type is what parses and what declares `ah:Script`. Pointed at a
      # `:string` the section would be configured and do nothing at all — every
      # value unparsed, and the wire saying the value is prose.
      compiled =
        compile("""
          lua do
            script :body
          end

          attributes do
            uuid_primary_key :id
            attribute :body, :string
          end
        """)

      assert stderr(compiled) =~ "DslError"
      assert stderr(compiled) =~ "AshHateoas.Type.Lua"
    end

    test "two binds sharing a name fail the build" do
      compiled =
        compile("""
          lua do
            script :body
            bind :author, AshHateoas.Test.Scripted.Author
            bind :author, AshHateoas.Test.Scripted.Function
          end

          attributes do
            uuid_primary_key :id
            attribute :body, AshHateoas.Type.Lua
          end
        """)

      assert stderr(compiled) =~ "DslError"
      assert stderr(compiled) =~ "More than one `bind`"
      assert stderr(compiled) =~ ":author"
    end

    test "a bind keyed on a missing attribute fails the build" do
      compiled =
        compile("""
          lua do
            script :body
            bind :author, AshHateoas.Test.Scripted.Author, key: :nickname
          end

          attributes do
            uuid_primary_key :id
            attribute :body, AshHateoas.Type.Lua
          end
        """)

      assert stderr(compiled) =~ "DslError"
      assert stderr(compiled) =~ "does not declare"
      assert stderr(compiled) =~ ":nickname"
    end

    test "a bind keyed on a non-unique attribute fails the build" do
      # The one that matters most, and the reason this is compile-time rather
      # than a runtime error. A reference names *one* record; if two can share
      # the key it resolves to whichever comes back first, so the same script
      # means different things at different times and nothing reports it.
      #
      # `Formula.name` carries no identity, which is exactly that shape.
      compiled =
        compile("""
          lua do
            script :body
            bind :formula, AshHateoas.Test.Scripted.Formula
          end

          attributes do
            uuid_primary_key :id
            attribute :body, AshHateoas.Type.Lua
          end
        """)

      assert stderr(compiled) =~ "DslError"
      assert stderr(compiled) =~ "is not unique"
    end

    test "a unique key is accepted" do
      # The positive half, so the check above is not passing for an unrelated
      # reason. `Author.name` carries `identity :unique_name`.
      compiled =
        compile("""
          lua do
            script :body
            bind :author, AshHateoas.Test.Scripted.Author
          end

          attributes do
            uuid_primary_key :id
            attribute :body, AshHateoas.Type.Lua
          end
        """)

      refute own_output(compiled) =~ "DslError",
             "a unique key must be accepted, got: #{own_output(compiled)}"
    end
  end
end
