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

  and gets a citation resource with `author_id`, `publisher_id`, a check
  constraint that at most one is set, and a link back to the script.

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
    kinds = Enum.map(binds, & &1.name)

    references =
      for %{name: name} <- binds do
        # A *cited* record going away leaves the citation with its name and no
        # target, which is a state a script may be in. It is not a state a write
        # may create — the write refuses a citation naming nothing.
        quote do: reference(unquote(name), on_delete: :nilify)
      end

    relationships =
      for %{name: name, resource: resource} <- binds do
        # **Public**, or the foreign key cannot be written at all: `:*` accepts
        # only public attributes, so a non-public `belongs_to` generates a
        # column no create can set — every citation write refused, for a reason
        # that reads as a missing input rather than a missing declaration.
        quote do: belongs_to(unquote(name), unquote(resource), public?: true)
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
      relationship per bind, and a check constraint that at most one is set.
      """

      unquote(data_layer_block(module, kinds, references, dsl_state))

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
    end
  end

  # The cascades and the check constraint are Postgres's to enforce, and a
  # resource on another data layer has neither — so the block is emitted only
  # where it means something. On ETS (the test fixtures) the citation resource
  # is otherwise identical, which is what lets the generation itself be tested
  # without a database.
  #
  # Stated rather than assumed: a `postgres` block on an ETS resource is not a
  # no-op, it fails to compile.
  defp data_layer_block(module, kinds, references, dsl_state) do
    if Transformer.get_persisted(dsl_state, :data_layer) == AshPostgres.DataLayer do
      quote do
        postgres do
          table(unquote(table(module)))
          # The script resource's own repo — read from its DSL rather than from
          # a persisted key, which `repo` is not.
          repo(unquote(Transformer.get_option(dsl_state, [:postgres], :repo)))

          references do
            # A citation has no meaning without the script it is part of.
            reference(:script, on_delete: :delete)
            unquote_splicing(references)
          end

          check_constraints do
            check_constraint(unquote(Enum.map(kinds, &:"#{&1}_id")),
              check: unquote(at_most_one(kinds)),
              name: unquote("#{table(module)}_one_target"),
              message: "a citation names at most one thing"
            )
          end
        end
      end
    end
  end

  # Derived from the script resource's own table, so the two stay together
  # without the domain naming either.
  defp table(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> Kernel.<>("_citation")
  end

  defp at_most_one(kinds) do
    kinds
    |> Enum.map_join(" + ", &"(#{&1}_id IS NOT NULL)::int")
    |> Kernel.<>(" <= 1")
  end
end
