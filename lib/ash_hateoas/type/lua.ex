defmodule AshHateoas.Type.Lua do
  @moduledoc """
  A string attribute whose value is a Lua script, parsed on write.

      attribute :formula, AshHateoas.Type.Lua, public?: true

      attribute :rule, AshHateoas.Type.Lua,
        public?: true,
        constraints: [form: :chunk]

  The value is stored as an ordinary string. What the type adds is that the
  string is **source code**: it is parsed when it is written, so a syntax error
  is a `422` at the moment an author makes it rather than a failure at whatever
  later point something tries to read it.

  ## Why the type rather than a validation

  A validation would reject the same values. What it would not do is *say* so on
  the wire — and that is the half a client needs.

  An attribute typed `:string` is declared `owl:DatatypeProperty` with
  `rdfs:range xsd:string`, which is true and useless: it tells a consumer the
  value is text, so a client reading a formula sees prose. To render
  `variable["MI_Li"]` as a link it would have to *guess* that this particular
  string contains references, that subscripts are how they are spelled, and
  which resource each names — three domain facts a generic client must not know,
  and cannot correctly infer (a `description` may contain brackets too).

  Declaring the type moves that from inference to statement, the same move
  `AshHateoas.Type.ResourceLink` makes for URLs: the wire says *this value is a
  script*, and a client renders it as one because the server marked it.

  ## Nothing is executed

  `AshHateoas.Lua.Parser` uses `luerl`'s scanner and parser and never its
  virtual machine. A script is analysed the way a compiler analyses source —
  read for its structure, never run — so the questions a sandbox answers do not
  arise. See that module for why Lua's syntax was adopted rather than a grammar
  of our own.

  ## Constraints

    * `:form` — `:expression` (the default) or `:chunk`. An expression is a
      single value, which is the form a formula takes; a chunk is an ordinary
      Lua program. The distinction is Lua's own, which is why it is a constraint
      here rather than a domain concern.

  A narrower rule than "it parses" — no `local`, no loops, only these functions
  — is a *subset*, and belongs to whatever declares the attribute rather than to
  the type. `AshHateoas.LuaScript` is where that lives.

  ## What reaches the wire

  The ontology declares the property `owl:DatatypeProperty` with
  `rdfs:range ah:Script` and `ah:scriptLanguage "lua"`, rather than the
  `xsd:string` an untyped attribute would get. That is the capability a client
  discovers: the value is source code, and here is the grammar to read it with.
  """

  use Ash.Type.NewType, subtype_of: :string

  @doc """
  The language this type's values are written in.

  Read by the ontology emitter to declare `ah:scriptLanguage`. A second script
  type answers differently and needs no change to the emitter.
  """
  @spec script_language() :: String.t()
  def script_language, do: "lua"

  alias AshHateoas.Lua.Parser

  @constraints [
    form: [
      type: {:one_of, [:expression, :chunk]},
      default: :expression,
      doc:
        "Whether the value is a single Lua expression (the form a formula takes) or a full chunk."
    ]
  ]

  @impl Ash.Type
  def constraints, do: @constraints ++ Ash.Type.String.constraints()

  @impl Ash.Type
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(value, constraints) do
    with {:ok, source} when is_binary(source) <- super(value, string_constraints(constraints)) do
      case Parser.parse(source, form(constraints)) do
        {:ok, _ast} -> {:ok, source}
        {:error, reason} -> {:error, message: reason}
      end
    end
  end

  # Stored values were parsed when they were written, so re-parsing every row on
  # read would spend the cost again to learn what the write already established.
  # A value that is somehow invalid in the database is a defect to find, not one
  # to hide behind a read-time failure that makes the row unreadable.
  @impl Ash.Type
  def cast_stored(value, constraints), do: super(value, string_constraints(constraints))

  @impl Ash.Type
  def dump_to_native(value, constraints), do: super(value, string_constraints(constraints))

  defp form(constraints), do: Keyword.get(constraints || [], :form, :expression)

  # `:form` is ours; everything else belongs to the underlying string type,
  # which raises on a constraint it does not know.
  defp string_constraints(constraints), do: Keyword.delete(constraints || [], :form)
end
