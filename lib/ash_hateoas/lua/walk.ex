defmodule AshHateoas.Lua.Walk do
  @moduledoc """
  Reads a parsed script for the things a caller can act on: what it references,
  what it calls, and whether either names something undeclared.

  This is the generic half of `AshHateoas.LuaScript`. It knows that a subscript
  under a bound name is a reference and that a call names a function; it never
  learns what a reference *means* or what a function *does*. Both are the
  domain's, and both are reached by asking rather than by this module deciding.

  ## The node shapes, since `luerl` reuses one for two things

  A subscript and a call are both spelled `:.`, told apart by what follows the
  name:

      author["Ada"]   →  {:., line, {:NAME, _, ~c"author"}, {:key_field, _, {:LITERALSTRING, _, ~c"Ada"}}}
      round(x)        →  {:., line, {:NAME, _, ~c"round"},  {:functioncall, _, args}}

  Matching on `:functioncall` alone finds nothing, because the call is the
  *second* element rather than the node's own tag. Worth stating: the obvious
  reading is wrong, and it fails by finding zero calls rather than by raising.

  ## Why a reference is a subscript and not a call

  `author("Ada")` parses too, and reads more like a lookup. It was measured and
  rejected: it produces the **same `:functioncall` node** a real call does, so a
  reference and a call stop being distinguishable by shape and can only be told
  apart by checking the name against the bind list. A bind sharing a name with a
  function would then be ambiguous with no way to state which was meant, and
  every error message would have to hedge about which one the author intended.

  The subscript keeps the two apart structurally, so neither can shadow the
  other and each error says one thing.

  Quoting is not what decides this — it is unavoidable either way. `author(Ada
  Lovelace)` fails exactly as `author[Ada Lovelace]` does, because Lua reads a
  bare word as a variable and two in a row is a syntax error.

  ## Why the key is quoted

  Three unquoted spellings parse, and none of them survives contact with real
  names:

    * `author[Ada]` — `Ada` is a *variable reference*, not a string. Accepting
      it would mean silently reinterpreting one construct as another.
    * `author.Ada` — a genuine single-identifier key, and the only unquoted form
      that means what it looks like.
    * `author.Ada-Lovelace` — parses, and is the trap: it is `author.Ada` minus
      a variable `Lovelace`. A hyphenated name would quietly become subtraction.

  So the usable unquoted form is `author.Name`, restricted to identifiers. On a
  real corpus of 495 names, **82% cannot be written that way** — spaces,
  parentheses, punctuation. Offering it would mean two spellings for one thing
  and an author having to know which bucket each name falls in.

  One rule that always works beats a shorter one that works for a sixth of
  cases.
  """

  alias AshHateoas.Lua.Parser

  @typedoc "A reference: the bound name, and the key it names."
  @type reference_node :: {atom(), String.t()}

  @typedoc "A call: the function name, and how many arguments it was given."
  @type call :: {String.t(), non_neg_integer()}

  @doc """
  Every reference in `ast`, as `{bind_name, key}`, in source order.

  A subscript whose name is not bound is **not** a reference and is not
  returned — it is an error, which `check/2` reports. This function answers what
  the script cites; it does not judge.
  """
  @spec references(Parser.ast(), [atom()]) :: [reference_node()]
  def references(ast, bound) do
    ast
    |> nodes()
    |> Enum.flat_map(fn
      {:., _line, {:NAME, _, name}, {:key_field, _, {:LITERALSTRING, _, key}}} ->
        name = atom(name)
        if name in bound, do: [{name, text(key)}], else: []

      _other ->
        []
    end)
  end

  @doc """
  Every call in `ast`, as `{name, arity}`, in source order.
  """
  @spec calls(Parser.ast()) :: [call()]
  def calls(ast) do
    ast
    |> nodes()
    |> Enum.flat_map(fn
      {:., _line, {:NAME, _, name}, {:functioncall, _, args}} ->
        [{text(name), length(args)}]

      _other ->
        []
    end)
  end

  @doc """
  Checks every name in `ast` against what is declared.

  `opts`:

    * `:binds` — the bound subscript names. A subscript under any other name is
      refused, because a name nothing binds cannot resolve to anything and
      would otherwise fail silently at whatever later point something tried.
    * `:functions` — `%{name => [arity]}`. A call to an undeclared function, or
      at an arity it does not accept, is refused here rather than at the point
      something tries to evaluate it.
    * `:normalize` — how a written function name is matched against that map.
      Defaults to identity, because **Lua is case-sensitive and this library
      must not adopt any engine's convention**. A domain whose backend folds
      case passes `&String.downcase/1` and keys its map the same way — which is
      a statement about that backend, made where it is true.

  Returns `:ok` or `{:error, [message]}` — every problem, not the first, since
  an author fixing one at a time learns about the next only by trying again.
  """
  @spec check(Parser.ast(), keyword()) :: :ok | {:error, [String.t()]}
  def check(ast, opts) do
    bound = Keyword.get(opts, :binds, [])
    functions = Keyword.get(opts, :functions, %{})
    normalize = Keyword.get(opts, :normalize, & &1)

    errors = unbound_errors(ast, bound) ++ call_errors(ast, functions, normalize)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp unbound_errors(ast, bound) do
    # The name in `author["Ada"]` and in `round(x)` is a child node like any
    # other, so the walk reaches it — and reading it as a *bare* name would
    # report every valid reference and every valid call as an error. Collect
    # the heads first and exclude them.
    #
    # Found by probing rather than by reading: the clause looked right, and the
    # failure is that correct scripts are refused.
    heads = head_nodes(ast)

    ast
    |> nodes()
    |> Enum.reject(&(&1 in heads))
    |> Enum.flat_map(fn
      {:., _line, {:NAME, _, name}, {:key_field, _, {:LITERALSTRING, _, key}}} ->
        name = atom(name)

        if name in bound do
          []
        else
          ["#{name}[#{inspect(text(key))}] — #{name} is not bound#{suggest(bound)}"]
        end

      # A bare name — `x` rather than `x["…"]`. In an expression there is
      # nothing for it to be: no variable was declared, and a reference needs a
      # key. Say what was probably meant rather than leaving the author to guess
      # why a name they can see is not allowed.
      {:NAME, _line, name} ->
        ["#{name} is not a reference — write #{name}[\"…\"]#{suggest(bound)}"]

      _other ->
        []
    end)
  end

  defp call_errors(ast, functions, normalize) do
    ast
    |> calls()
    |> Enum.flat_map(fn {name, arity} ->
      case Map.fetch(functions, normalize.(name)) do
        {:ok, arities} ->
          if arity in arities do
            []
          else
            ["#{name} takes #{Enum.join(Enum.sort(arities), " or ")} arguments, given #{arity}"]
          end

        :error ->
          ["there is no function named #{name}"]
      end
    end)
  end

  # The `{:NAME, …}` node standing at the head of a subscript or a call. It
  # names the bind or the function rather than standing on its own, so it is not
  # a bare name and must not be reported as one.
  defp head_nodes(ast) do
    ast
    |> nodes()
    |> Enum.flat_map(fn
      {:., _line, {:NAME, _, _} = head, {tail, _, _}} when tail in [:key_field, :functioncall] ->
        [head]

      _other ->
        []
    end)
  end

  defp suggest([]), do: ""

  defp suggest(bound) do
    " — bound: #{Enum.map_join(Enum.sort(bound), ", ", &to_string/1)}"
  end

  @doc """
  Every node of the AST, depth first.

  `luerl`'s nodes are tuples whose tail elements are child nodes or lists of
  them, uniformly enough that one walk covers the whole grammar. That matters:
  the alternative is a clause per construct, and a construct nobody wrote a
  clause for goes *unchecked* rather than unparsed — a reference inside it would
  simply not be found.
  """
  @spec nodes(Parser.ast()) :: [tuple()]
  def nodes(ast), do: ast |> collect([]) |> Enum.reverse()

  # `collect/2` prepends as it descends, so it builds the list backwards and
  # `nodes/1` reverses it. Not cosmetic: every caller reports in the order it
  # receives, so without the reverse an author reading a list of errors is sent
  # to the end of their formula first.
  #
  # A subscript's key and a call's argument list are children like any other, so
  # the walk descends into both — which is what makes a reference inside a call
  # (`round(author["Ada"])`) reachable.
  defp collect(node, acc) when is_tuple(node) do
    children = node |> Tuple.to_list() |> Enum.drop(1)
    Enum.reduce(children, [node | acc], &collect/2)
  end

  defp collect(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect/2)
  defp collect(_leaf, acc), do: acc

  # `luerl` hands back a charlist of **codepoints**, and `to_string/1` on one
  # writes each as a single byte — so `née` comes back as Latin-1 and every
  # accented name is silently corrupted. `List.to_string/1` encodes as UTF-8.
  #
  # Found by testing a name with an accent, which is the only way this shows:
  # an ASCII name round-trips identically under either.
  defp text(charlist) when is_list(charlist), do: List.to_string(charlist)
  defp text(binary) when is_binary(binary), do: binary

  defp atom(charlist) do
    charlist |> text() |> String.to_existing_atom()
  rescue
    # A subscript naming something no bind ever declared. Not an error here —
    # the caller reports it — but it must not mint an atom from user input.
    ArgumentError -> :__unbound__
  end
end
