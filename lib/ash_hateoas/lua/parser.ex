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
    charlist = String.to_charlist(source)

    with {:ok, tokens, _line} <- :luerl_scan.string(charlist) do
      case :luerl_parse.chunk(tokens) do
        {:ok, ast} -> {:ok, ast}
        {:error, reason} -> {:error, format(reason)}
      end
    else
      {:error, reason, _line} -> {:error, format(reason)}
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
