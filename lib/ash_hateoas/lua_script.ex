defmodule AshHateoas.LuaScript do
  alias AshHateoas.LuaScript.Bind

  @bind %Spark.Dsl.Entity{
    name: :bind,
    target: Bind,
    args: [:name, :resource],
    identifier: {:auto, :unique_integer},
    describe: """
    A name a script may reference, and the resource it resolves to.
    """,
    examples: [~s(bind :author, MyApp.People.Author)],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The Lua subscript this binds — `author[\"…\"]`."
      ],
      resource: [
        type: {:spark, Ash.Resource},
        required: true,
        doc: "The resource a reference under this name resolves to."
      ],
      key: [
        type: :atom,
        default: :name,
        doc: """
        The attribute a subscript matches on. Defaults to `:name` — the
        resource's own naming key, so a script cites what a client can write.
        """
      ]
    ]
  }

  @lua %Spark.Dsl.Section{
    name: :lua,
    describe: """
    Declares which attribute holds a script and what that script may reference.
    """,
    examples: [
      """
      lua do
        script :formula
        bind :author, MyApp.People.Author
        bind :publisher, MyApp.People.Publisher
        functions MyApp.Formulas.Function
      end
      """
    ],
    schema: [
      script: [
        type: :atom,
        required: true,
        doc: """
        The attribute holding the source. Must be typed
        `AshHateoas.Type.Lua` — the type is what parses, and what puts
        `ah:Script` on the wire.
        """
      ],
      functions: [
        type: {:spark, Ash.Resource},
        required: false,
        doc: """
        A resource whose records are the functions a script may call — name,
        arity and whatever else the domain attaches. Publishing the callable
        set as a resource is what lets a client *fetch* the signatures instead
        of being handed bare names it cannot check against.
        """
      ]
    ],
    entities: [@bind]
  }

  @moduledoc """
  Marks an attribute as a script, and declares what that script may reference.

      use Ash.Resource,
        domain: MyApp.Formulas,
        extensions: [AshHateoas.Resource, AshHateoas.LuaScript]

      lua do
        script :formula
        bind :author, MyApp.People.Author
        bind :publisher, MyApp.People.Publisher
        functions MyApp.Formulas.Function
      end

  `AshHateoas.Type.Lua` already parses the source and already tells the wire it
  is a script. What it cannot do is say what the *names inside* refer to — and
  without that a reference is a string that happens to look structured.

  This extension supplies the missing half. `bind` maps a Lua subscript to a
  resource, so `author["Ada Lovelace"]` is a reference that resolves, and a
  subscript naming nothing bound is refused where it is written.

  ## Why binding beats sniffing

  A consumer could look for bracketed names in a string and try to resolve them.
  That guesses twice: whether *this* string contains references at all (prose
  contains brackets), and which resource each names (two classes may hold the
  same name). Both guesses are wrong often enough to matter, and a wrong guess
  is worse than none — it produces a link that goes somewhere plausible.

  A binding states it. The resource says which names mean something and what
  they mean, and every consumer reads the same answer.

  ## The subset is the type's, not this extension's

  There is deliberately **no `subset` option here.** `AshHateoas.Type.Lua`
  carries `constraints: [form: :expression | :chunk]`, and that is the whole
  statement — adding one here would let the two disagree about the same
  attribute, and the type is the one that actually parses.

  What an *expression* buys is worth stating, since it looks like a restriction
  and is a consequence. Every construct an expression admits — a reference, a
  literal, an operator, a declared function — has a rule the domain can state
  for it, so a walk over the AST is **total**: there is no node where the answer
  is "cannot tell". Admitting `local` and `for` would each introduce a node
  whose meaning is not statically decidable, and any guarantee built on the walk
  would become partial. A domain that wants programs rather than expressions
  asks for `form: :chunk` and gives up that totality knowingly.

  ## Nothing is executed

  Only `luerl`'s scanner and parser are used. A script is read for its
  structure — references extracted, functions checked, whatever the domain
  computes computed — and never run. See `AshHateoas.Lua.Parser`.

  ## What is generic and what is the domain's

  This extension walks the AST and resolves what it finds. It never learns what
  the domain *means* by any of it: a function's effect, a reference's
  significance, and any check over the two are the domain's, reached by
  callback. The traversal is the library's; the meaning never is.

  ## The citations are a resource, and it is generated

  A script's references are stored as rows with real foreign keys, in a
  resource this extension **generates** from the binds — `MyApp.Formula` gets
  `MyApp.Formula.Citation`, with one nullable relationship per bind and a check
  constraint that at most one is set.

  Generated rather than hand-written because every column is a restatement of a
  bind, and the two drift: a bind with no column is a reference that cannot be
  stored, a column with no bind is a foreign key to something no script can
  name, and neither shows until a write fails.

  **A relationship is named after its bind; its column after the resource.** A
  bind's name is the subscript an author types and may be shortened to read well
  in a formula — `bind :var, Variable` — while `variable_id` is where the row
  lives. Deriving the column from the name made those one thing, so a
  readability change became a migration and broke every caller that had derived
  the same column from the record's kind.

  The domain still lists it in its `resources` block — otherwise the data layer
  never sees it and no migration is generated. See
  `AshHateoas.LuaScript.Transformers.DeriveCitations`.
  """

  use Spark.Dsl.Extension,
    sections: [@lua],
    transformers: [AshHateoas.LuaScript.Transformers.DeriveCitations],
    verifiers: [AshHateoas.LuaScript.Verifiers.VerifyScript]
end
