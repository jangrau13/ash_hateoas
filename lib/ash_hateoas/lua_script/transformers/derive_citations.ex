defmodule AshHateoas.LuaScript.Transformers.DeriveCitations do
  @moduledoc """
  Generates the resource that holds a script's citations, from its `bind`
  declarations.

  A script names things — `author["Ada Lovelace"]` — and those names are only as
  trustworthy as what backs them. Stored as text inside the source, a reference
  is something a parser can see and the database cannot: nothing stops the
  cited record being deleted, and nothing follows it on a rename.

  This makes each one a **row with a real foreign key**. The shape is entirely
  determined by the binds, so the domain declares

      lua do
        script :source
        bind :author, MyApp.Author
        bind :publisher, MyApp.Publisher
      end

  and gets a citation resource with `author_id`, `publisher_id`, a validation
  that at most one is set, and a link back to the script.

  ## Why generated rather than hand-written

  Every column is a restatement of a bind. Written by hand, the two drift: a
  bind added without its column is a reference that cannot be stored, and a
  column left behind after a bind is removed is a foreign key to something no
  script can name. Neither is visible until a write fails.

  Ash has no precedent for generating a resource — even `many_to_many` requires
  the join resource hand-written and named through `through` — so this was
  verified before being built: `Module.create/3` produces a genuine resource,
  one `belongs_to` per bind yields exactly the intended columns, and it works
  from inside a transformer with the generated module's link resolving back to
  the still-compiling parent.

  ## One column per bind, and at most one set

  Six nullable `belongs_to` rather than a `type` + `id` pair, because Ash needs
  a distinct column per destination and a discriminator beside an id is a cache
  that can disagree with what it describes.

  **At most one**, not exactly one: a cited record may be deleted, and the
  column is nilified rather than the citation vanishing. The name survives, so
  a script keeps a visible hole instead of silently losing a reference. Two set
  is nonsense either way — one citation names one thing.

  That rule is a **validation on the resource**, so it holds on every data
  layer. It was a Postgres check constraint and nothing else, which meant a
  citation resource stored anywhere else had the columns and none of the
  meaning. Postgres still gets the constraint as well — a guarantee the
  database keeps is worth having where it is available — but it is no longer
  the only thing keeping it.

  **`at_most` is what makes the two safely interchangeable.** A constraint reads
  the finished row; a validation reads a changeset mid-flight, and the two do
  not see the same thing — a citation created through `manage_relationship` from
  the cited record's side has its foreign key filled in *after* validations run,
  so at validation time the column is still nil. Counting fewer targets than the
  write will end up with is harmless under `at_most` and fatal under `exactly`,
  which would refuse exactly the writes it exists to permit. The residue is a
  gap rather than a false refusal: two targets where one arrives late are
  invisible to the changeset, and there Postgres's constraint is doing real work
  that SQLite has nothing to offer in place of.

  ## Where a citation is stored

  Postgres and SQLite both, and neither is a dependency of this package: the
  data layer is recognised by name and its DSL section written accordingly.
  Everything the two share — the table, the repo, the cascades — is emitted
  once. What they do not share is enforcement: ash_sqlite has no
  `check_constraints`, so on SQLite the validation above is the whole of the
  rule.

  A data layer this does not recognise gets no storage block at all, which is
  what lets the generation be tested on ETS with no database anywhere.

  ## What the domain still writes

  Two things, neither about columns:

    * the generated module must appear in the domain's `resources` block, or
      the data layer never sees it and no migration is generated;
    * the binds themselves.

  ## The trap

  **Do not set `after_compile?: true` on this transformer.** The transform then
  never runs — no error, no module, and the failure surfaces later as
  "not a Spark DSL module" from whatever first touches the citation resource,
  which reads like a generation bug and is not one.
  """

  use Spark.Dsl.Transformer

  alias AshHateoas.LuaScript.Info
  alias Spark.Dsl.Transformer

  @doc false
  def transform(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)
    binds = Info.binds(dsl_state)

    if Info.script?(dsl_state) and generatable?(binds) do
      generate(module, binds, dsl_state)
    end

    {:ok, dsl_state}
  end

  # A transformer runs *before* the verifiers, so a declaration this cannot
  # build must be left alone rather than built badly. Duplicate binds would
  # generate two relationships of one name, and Ash raises on that with a
  # message about fields sharing a name — burying `VerifyScript`'s account of
  # what is actually wrong, which is the bind list.
  #
  # Skipping is safe because the build fails either way; the only question is
  # which error an author reads.
  defp generatable?(binds) do
    names = Enum.map(binds, & &1.name)

    names != [] and names == Enum.uniq(names)
  end

  defp generate(module, binds, dsl_state) do
    citation = Module.concat(module, Citation)

    # Already built — a recompile of the same resource must not raise on a
    # module that is simply still there from the last pass.
    unless function_exported?(citation, :__info__, 1) do
      Module.create(
        citation,
        body(module, binds, dsl_state),
        file: __ENV__.file,
        line: __ENV__.line
      )
    end
  end

  defp body(module, binds, dsl_state) do
    # **Two lists, deliberately.** A bind's *name* is what a script writes and
    # what `kind` records; its *column* is storage, named after the resource. The
    # two were one list, so a subscript chosen for readability became a database
    # column name — see the `belongs_to` below.
    kinds = Enum.map(binds, & &1.name)
    columns = Enum.map(binds, &column_for(&1.resource))

    references =
      for %{name: name} <- binds do
        # A *cited* record going away leaves the citation with its name and no
        # target, which is a state a script may be in. It is not a state a write
        # may create — the write refuses a citation naming nothing.
        #
        # Named by *relationship*, which is the bind's name: `references` is an
        # Ash-level declaration, not a column list.
        quote do: reference(unquote(name), on_delete: :nilify)
      end

    relationships =
      for %{name: name, resource: resource} <- binds do
        # **Public**, or the foreign key cannot be written at all: `:*` accepts
        # only public attributes, so a non-public `belongs_to` generates a
        # column no create can set — every citation write refused, for a reason
        # that reads as a missing input rather than a missing declaration.
        #
        # **The column is named after the resource, not the bind.** A bind's
        # name is the Lua subscript an author types — a spelling, chosen to read
        # well inside a formula — while the column is storage. Left to default
        # (`<name>_id`) the two were one thing, so renaming `variable` to `var`
        # for readability silently renamed a database column and broke every
        # caller deriving it from the element's kind. Stated explicitly, a
        # subscript rename touches nothing but text.
        quote do
          belongs_to(unquote(name), unquote(resource),
            public?: true,
            source_attribute: unquote(column_for(resource))
          )
        end
      end

    quote do
      use Ash.Resource,
        domain: unquote(Transformer.get_persisted(dsl_state, :domain)),
        validate_domain_inclusion?: false,
        data_layer: unquote(Transformer.get_persisted(dsl_state, :data_layer)),
        extensions: [AshHateoas.Resource]

      @moduledoc """
      One thing #{inspect(unquote(module))}'s script names, as a row with a real
      foreign key.

      Generated from that resource's `bind` declarations by
      `AshHateoas.LuaScript.Transformers.DeriveCitations` — one nullable
      relationship per bind, and a validation that at most one is set (plus,
      on Postgres, a check constraint saying the same thing).

      Each relationship carries the **bind's** name, since that is what a script
      writes; its column carries the **resource's**, since that is storage. So
      `bind :var, Variable` yields the relationship `var` over the column
      `variable_id`, and renaming the subscript does not move the column.
      """

      unquote(data_layer_block(module, columns, references, dsl_state))

      hateoas do
        warn_on_missing_authorizers?(false)

        # Cast with the script it belongs to, never created standalone: a
        # citation with no script around it references nothing.
        unrouted(:create)
        unrouted(:update)
        unrouted(:destroy)
      end

      attributes do
        uuid_primary_key(:id)

        # What the script wrote, which outlives the record it named. While the
        # citation resolves this is redundant with the target's own name, and
        # that is not what it is for: it is what the script still says once the
        # target is gone.
        attribute(:name, :string, public?: true, allow_nil?: false)

        attribute(:kind, :atom,
          public?: true,
          allow_nil?: false,
          constraints: [one_of: unquote(kinds)]
        )

        # Where in the source this appears, so rows come back in reading order.
        attribute(:position, :integer, public?: true, allow_nil?: false, default: 0)
      end

      relationships do
        # `script`, not the script attribute's name: this is the citation's
        # link back to the record holding the source, and that record is a
        # script whatever its domain calls the field. Naming it after the field
        # would put a domain's word — `value`, `formula`, `rule` — in a
        # generated relationship every consumer has to read.
        belongs_to(:script, unquote(module), public?: true, allow_nil?: false)
        unquote_splicing(relationships)
      end

      actions do
        defaults([:read, :destroy, create: :*, update: :*])
      end

      validations do
        # **At most one target, whatever this is stored in.** The rule used to
        # live only in a Postgres check constraint, so a resource on any other
        # data layer had the columns and none of the meaning: two set was
        # nonsense the database happened to catch, and on SQLite or ETS nothing
        # caught it at all. Stated here it holds everywhere, and the check
        # constraint becomes a backstop rather than the only guard.
        #
        # `at_most`, not `exactly`: a cited record may be deleted and its column
        # nilified, leaving a citation with a name and nothing behind it. That
        # is a state a script may be in — it is not a state a write may create.
        validate(present(unquote(columns), at_most: 1),
          message: "a citation names at most one thing"
        )
      end
    end
  end

  # A citation's storage is the script's own, and both SQL data layers state it
  # the same way — a table, a repo, and the cascades that keep a citation from
  # outliving the script it is part of. What differs is the section name and
  # what the database can be asked to enforce, so the shared part is written
  # once and each branch adds only its difference.
  #
  # A data layer with no such section gets no block at all, and that is
  # deliberate: on ETS (the test fixtures) the citation resource is otherwise
  # identical, which is what lets the generation itself be tested without a
  # database.
  #
  # Stated rather than assumed: a `postgres` block on an ETS resource is not a
  # no-op, it fails to compile.
  defp data_layer_block(module, columns, references, dsl_state) do
    case section(dsl_state) do
      :postgres ->
        quote do
          postgres do
            unquote(storage(module, references, dsl_state))

            # The rule twice over: here as something the database itself
            # refuses to break, and in `validations` for the data layers that
            # have nothing of the kind to offer.
            check_constraints do
              check_constraint(unquote(columns),
                check: unquote(at_most_one(columns)),
                name: unquote("#{table(module, dsl_state)}_one_target"),
                message: "a citation names at most one thing"
              )
            end
          end
        end

      :sqlite ->
        # **No `check_constraints`** — ash_sqlite's DSL has no such section, and
        # SQLite cannot add a CHECK to a table after the fact anyway. Here the
        # validation is the only thing holding the rule, which is why it is
        # declared unconditionally rather than only where the database is silent.
        quote do
          sqlite do
            unquote(storage(module, references, dsl_state))
          end
        end

      nil ->
        nil
    end
  end

  # Table, repo and cascades — the same three statements under either section.
  defp storage(module, references, dsl_state) do
    quote do
      table(unquote(table(module, dsl_state)))
      # The script resource's own repo — read from its DSL rather than from
      # a persisted key, which `repo` is not.
      repo(unquote(Transformer.get_option(dsl_state, [section(dsl_state)], :repo)))

      references do
        # A citation has no meaning without the script it is part of.
        reference(:script, on_delete: :delete)
        unquote_splicing(references)
      end
    end
  end

  # The DSL section a data layer keeps its table and repo under, and `nil` for
  # one that keeps neither.
  #
  # **Matched as a bare module name on purpose.** Neither ash_postgres nor
  # ash_sqlite is a dependency of this package and neither should become one —
  # a consumer brings whichever it uses, and recognising the name costs nothing
  # at build time.
  defp section(dsl_state) do
    case Transformer.get_persisted(dsl_state, :data_layer) do
      AshPostgres.DataLayer -> :postgres
      AshSqlite.DataLayer -> :sqlite
      _ -> nil
    end
  end

  # Derived from the script resource's **own table**, so the two sit together
  # under whatever prefix that domain uses — `simulation_value` yields
  # `simulation_value_citation`, not `value_citation`.
  #
  # Read from the section that data layer actually uses, rather than from
  # `[:postgres]` whatever the data layer is: under SQLite that path answers
  # `nil`, and the fallback below then names the citation table after the module
  # — putting it outside the domain's namespace, which a generated migration
  # makes permanent. A silent rename is the worst shape this can fail in.
  #
  # The module name is the fallback and not the source, for that same reason.
  defp table(module, dsl_state) do
    base =
      case Transformer.get_option(dsl_state, [section(dsl_state)], :table) do
        table when is_binary(table) -> table
        _ -> module |> Module.split() |> List.last() |> Macro.underscore()
      end

    base <> "_citation"
  end

  # Postgres's own spelling. A comparison yields a boolean there and has to be
  # cast before it can be summed; SQLite's already yields 0 or 1, so the same
  # expression without the casts would be the SQLite form — which nothing needs,
  # since there is no `check_constraints` section to put it in.
  defp at_most_one(columns) do
    columns
    |> Enum.map_join(" + ", &"(#{&1} IS NOT NULL)::int")
    |> Kernel.<>(" <= 1")
  end

  # The column a citation to this resource is stored in.
  #
  # Named after the **resource**, so it is stable under a rename of the Lua
  # subscript: `bind :var, Variable` and `bind :variable, Variable` both store
  # `variable_id`. That separation is the whole point — a subscript is a
  # spelling an author reads, a column is storage, and letting one name the
  # other made a readability change into a migration.
  defp column_for(resource) do
    :"#{resource |> Module.split() |> List.last() |> Macro.underscore()}_id"
  end
end
