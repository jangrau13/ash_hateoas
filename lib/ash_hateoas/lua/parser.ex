defmodule AshHateoas.Lua.Parser do
  @moduledoc """
  Parses Lua source into an AST. **Nothing is ever executed.**

  `luerl` ships a scanner and a parser alongside its virtual machine; this
  module uses the first two and never the third. A script stored in an
  `AshHateoas.Type.Lua` attribute is source code the way a migration or a query
  is source code — read, analysed, rendered and edited, but not run. So the
  questions a sandbox exists to answer (what may it call, how long may it run,
  what may it see) do not arise here, because there is no execution to confine.

  ## Why Lua rather than a grammar of our own

  A domain that stores expressions needs a syntax, and writing one means writing
  a parser, an error reporter, an escaping rule for names, and a convention for
  saying which class a name refers to. Lua supplies all four, and its subscript
  syntax carries the class in the expression itself:

      author["Ada Lovelace"] * publisher["Ada Lovelace"]

  A name with spaces or punctuation needs no escaping, being a string key; two
  classes may hold the same name without a prefix convention, being different
  subscripts. Neither property comes free in a bespoke syntax, and both are
  otherwise paid for with machinery each domain has to write again.

  ## Expression or chunk

  `parse/2` takes `:expression` or `:chunk`.

  An **expression** is a single value — the form a formula takes. It is parsed
  by wrapping the source in `return`, so the parser's own grammar decides what
  counts rather than a rule of ours.

  A **chunk** is an ordinary Lua program: statements, assignments, control flow.

  The distinction is Lua's, not any domain's, which is why it lives here. What a
  *particular* attribute admits is narrower still and belongs to the caller —
  see `AshHateoas.Lua.Subset`, which is what refuses `local` and `for` inside an
  expression that would otherwise parse.

  ## Errors are for an author

  `luerl`'s own messages are charlists in Erlang's idiom (`"syntax error before:
  'end'"`). They are returned as binaries, unchanged in wording: they say where
  the parse stopped, which is the one thing an author can act on.
  """

  @typedoc "A parsed Lua AST, in `luerl`'s own node shapes."
  @type ast :: term()

  @typedoc "What the source is expected to be."
  @type form :: :expression | :chunk

  @doc """
  Parses `source`, returning `luerl`'s AST.

  `form` is `:expression` (the default) or `:chunk`.

      iex> {:ok, _ast} = AshHateoas.Lua.Parser.parse("1 + 2")

      iex> AshHateoas.Lua.Parser.parse("1 +")
      {:error, "syntax error before: "}

  An expression is parsed as `return <source>`, so anything Lua accepts in value
  position is accepted here — and a statement is not, since `return local x = 1`
  does not parse.
  """
  @spec parse(String.t(), form()) :: {:ok, ast()} | {:error, String.t()}
  def parse(source, form \\ :expression)

  def parse(source, :expression) when is_binary(source) do
    case chunk("return " <> source) do
      # `return <expr>` is the only shape this can take when the source really
      # was one expression. Anything else parsed, but parsed as something a
      # formula is not — `return 1; return 2`, say.
      {:ok, {:functiondef, _line, _params, [{:return, _, [expression]}]}} ->
        {:ok, expression}

      {:ok, _other} ->
        {:error, "expected a single expression"}

      {:error, _reason} = error ->
        error
    end
  end

  def parse(source, :chunk) when is_binary(source), do: chunk(source)

  defp chunk(source) do
    # **Bytes, not codepoints.** `String.to_charlist/1` yields codepoints, and
    # the scanner writes each back as a single byte — so `née` returns as
    # Latin-1 and every accented name is silently corrupted. Handing it the
    # bytes makes the scanner byte-transparent, and a UTF-8 literal survives
    # unchanged.
    #
    # Measured, not reasoned about: an ASCII name round-trips identically under
    # either, which is why this needs a test with an accent in it.
    with {:ok, tokens, _line} <- :luerl_scan.string(:binary.bin_to_list(source)) do
      case :luerl_parse.chunk(exact_numerals(tokens, source)) do
        {:ok, ast} -> {:ok, ast}
        {:error, reason} -> {:error, format(reason)}
      end
    else
      {:error, reason, _line} -> {:error, format(reason)}
    end
  end

  # **The scanner computes exponents rather than parsing them**, so a numeral in
  # scientific notation can come back a ULP wrong: `luerl_scan.xrl:255` evaluates
  # `DF * math:pow(10, Exp)`, and `9.22e5` becomes `922000.0000000001` where
  # Erlang's own `list_to_float/1` yields exactly `922000.0`. Measured: 54 of 891
  # two-digit mantissa/exponent pairs are affected — 6%, not a rare corner.
  #
  # It matters because a numeral is *stored*: a value parsed on write and
  # rendered on read comes back with the error baked into its text, so the
  # corruption is permanent rather than a rounding artefact of one calculation.
  #
  # The tokens are re-read against the source rather than recomputed, since the
  # scanner is the only thing that knows where each numeral began.
  defp exact_numerals(tokens, source) do
    # Only an exponent literal can be wrong, so a source without one is left
    # alone entirely — which is every formula the seed carries but three.
    case Regex.scan(~r/\d+\.?\d*[eE][+-]?\d+/, source) do
      [] ->
        tokens

      literals ->
        # Keyed by what the *scanner* made of each literal, not by position: a
        # numeral token carries no text, and pairing the nth literal with the nth
        # float token desyncs on the first ordinary decimal — `2013 + 9.22e5 *
        # 1.5` would hand `1.5` the repair meant for `9.22e5`. Measured, and it
        # silently produced a wrong tree.
        repairs =
          literals
          |> List.flatten()
          |> Map.new(fn literal -> {scanned(literal), exact(literal)} end)

        Enum.map(tokens, fn
          {:NUMERAL, line, value} = token when is_float(value) ->
            case Map.get(repairs, value) do
              nil -> token
              exact -> {:NUMERAL, line, exact}
            end

          other ->
            other
        end)
    end
  end

  # What the scanner computes for a literal, and what it should be. A literal
  # both agree on maps to itself, so the lookup is a no-op rather than a special
  # case — and one Erlang cannot read is left exactly as the scanner had it.
  defp scanned(literal) do
    case :luerl_scan.string(:binary.bin_to_list(literal)) do
      {:ok, [{:NUMERAL, _line, value}], _end} -> value
      _other -> :none
    end
  end

  defp exact(literal) do
    case Float.parse(literal) do
      {value, ""} -> value
      _other -> scanned(literal)
    end
  end

  # Both the scanner and the parser report `{line, module, reason}`, and each
  # module owns the wording for its own failures. Ask the module rather than
  # matching on the reason term, which is private to it.
  defp format({_line, module, reason}) when is_atom(module) do
    module
    |> apply(:format_error, [reason])
    |> to_string()
  rescue
    _ -> inspect(reason)
  end

  defp format(other), do: inspect(other)
end
