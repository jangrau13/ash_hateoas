defmodule AshHateoas.Req.R1R2R5Test do
  @moduledoc """
  Independent conformance tests for three requirements, read directly from REQ.md:

    * **R1** — Automatic. A resource author never writes affordances. They are
      derived from which actions exist, which are exposed (routes), which the
      actor may run (`Ash.can?/3`), and what is legal from the current state.
      Zero per-resource config.

    * **R2** — The DSL is override-only: `exclude` and `override` carry
      deviations only, there are no per-action "enable" entries, and a
      compile-time verifier rejects an `exclude`/`override` naming an action
      that does not exist.

    * **R5** — The output envelope has a fixed, documented shape: a map of
      action name → Affordance, where an Affordance carries `href`, `method`,
      `description`, a list of Fields and an optional `multi_step` flag, and a
      Field carries `name`, `type`, `required`, `description`, `default`
      (omitted when sensitive) and `constraints`. Only the SET of keys is
      dynamic; everything below a key is fixed.

  These are written against the requirement text, not against the
  implementation's current behaviour.
  """

  use ExUnit.Case, async: true

  require Spark.Test

  alias AshHateoas.{Affordance, Field}

  alias AshHateoas.Test.{
    Actor,
    Article,
    Derived,
    Document,
    Domain,
    Order,
    PublicNote,
    Unrouted
  }

  @admin %Actor{id: "r-admin", role: :admin}
  @viewer %Actor{id: "r-viewer", role: :viewer}

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp afford(subject, actor, opts \\ []) do
    AshHateoas.affordances(subject, actor, Keyword.put_new(opts, :domain, Domain))
  end

  defp create!(resource, attrs) do
    resource
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(authorize?: false)
  end

  defp keys(envelope), do: envelope |> Map.keys() |> MapSet.new()

  defp field(%Affordance{fields: fields}, name), do: Enum.find(fields, &(&1.name == name))

  # ------------------------------------------------------------------
  # R1 — automatic derivation, zero config
  # ------------------------------------------------------------------

  describe "R1: affordances are derived with zero per-resource config" do
    setup do
      derived = create!(Derived, %{label: "d"})
      %{derived: derived}
    end

    test "a resource that writes no `hateoas` block still gets affordances", %{derived: derived} do
      # Derived carries the extension but declares NO hateoas section at all.
      # R1: "Zero per-resource config."
      envelope = afford(derived, @admin)

      assert map_size(envelope) > 0,
             "a resource with no hateoas block must still be given derived affordances"

      assert MapSet.member?(keys(envelope), :touch)
    end

    test "a resource that does not carry the extension is still derivable" do
      # Document carries only AshJsonApi.Resource. R1 derives from what is
      # already declared, so the backbone must not require the extension.
      doc = create!(Document, %{title: "T", owner_id: @admin.id})

      assert map_size(afford(doc, @admin)) > 0
    end

    test "the candidate set is the ROUTED actions, not every declared action", %{
      derived: derived
    } do
      # R1: "which are exposed -> the resource's existing AshJsonApi routes".
      # :unrouted_touch is a real, authorized update action with no route.
      envelope_keys = keys(afford(derived, @admin))

      declared =
        Derived |> Ash.Resource.Info.actions() |> MapSet.new(& &1.name)

      assert MapSet.member?(declared, :unrouted_touch),
             "precondition: :unrouted_touch must exist as an action"

      refute MapSet.member?(envelope_keys, :unrouted_touch),
             "an action that exists and is authorized but is NOT routed must not be advertised"

      refute MapSet.member?(envelope_keys, :admin_only),
             "an unrouted action must not be advertised regardless of policy"
    end

    test "every advertised action really exists on the resource", %{derived: derived} do
      declared = Derived |> Ash.Resource.Info.actions() |> MapSet.new(& &1.name)

      for name <- Map.keys(afford(derived, @admin)) do
        assert MapSet.member?(declared, name),
               "the envelope advertised :#{name}, which is not a declared action"
      end
    end

    test "authorization filters the derived set (Ash.can?/3)", %{derived: _derived} do
      # Document's :approve requires role :admin; :destroy likewise.
      doc = create!(Document, %{title: "T", owner_id: unique("owner")})

      admin_keys = keys(afford(doc, @admin))
      viewer_keys = keys(afford(doc, @viewer))

      assert MapSet.member?(admin_keys, :approve)
      refute MapSet.member?(viewer_keys, :approve)
      refute MapSet.member?(viewer_keys, :destroy)
    end

    test "state legality filters the derived set (AshStateMachine)" do
      # Order's policies are `authorize_if always()`, so anything withheld here
      # is the state gate, not authorization. From :pending, :confirm and
      # :cancel are legal; :ship and :deliver are not.
      order = create!(Order, %{reference: "r1"})

      assert order.state == :pending, "precondition: a new order starts :pending"

      names = keys(afford(order, @admin))

      assert MapSet.member?(names, :confirm)
      assert MapSet.member?(names, :cancel), "a :* wildcard transition is legal from any state"

      refute MapSet.member?(names, :ship),
             ":ship is only legal from :confirmed — authorization alone must not advertise it"

      refute MapSet.member?(names, :deliver)
    end

    test "the derived set follows the record's state as it changes" do
      order = create!(Order, %{reference: "r2"})

      confirmed =
        order
        |> Ash.Changeset.for_update(:confirm, %{})
        |> Ash.update!(authorize?: false)

      assert confirmed.state == :confirmed

      names = keys(afford(confirmed, @admin))

      assert MapSet.member?(names, :ship), ":ship becomes legal once the order is :confirmed"

      refute MapSet.member?(names, :confirm),
             ":confirm is only legal from :pending, so it must drop after confirming"
    end

    test "a resource with no state machine is unaffected by the state gate", %{derived: derived} do
      # Derived has no AshStateMachine extension. Every routed, authorized
      # action must survive.
      names = keys(afford(derived, @admin))

      assert MapSet.member?(names, :touch)
      assert MapSet.member?(names, :read)
    end

    test "hrefs and methods are derived from the declared routes, not invented", %{
      derived: derived
    } do
      envelope = afford(derived, @admin)

      assert envelope[:touch].href == "/deriveds/:id/touch"
      assert envelope[:touch].method == :patch
      assert envelope[:read].href == "/deriveds/:id"
    end

    test "descriptions are derived from the action's own description", %{derived: derived} do
      assert afford(derived, @admin)[:touch].description == "Touch this record."
    end

    test "collection-level derivation needs no record and applies no state gate" do
      # R1/R9: the cold-start case. Order's :confirm is a transition, but with
      # no record there is no state, so only the collection route types are
      # eligible in the first place.
      names = keys(afford(Order, @admin))

      assert MapSet.member?(names, :create),
             "a client entering at a collection must be told it may create"

      refute MapSet.member?(names, :confirm),
             "record-level transitions are not collection-level affordances"
    end

    test "a resource with no routes at all falls back to its actions (no config)" do
      record = create!(Unrouted, %{label: "x"})

      envelope = afford(record, @admin)

      assert map_size(envelope) > 0,
             "the fallback path must still derive affordances with zero config"
    end
  end

  # ------------------------------------------------------------------
  # R2 — override-only DSL + compile-time verifier
  # ------------------------------------------------------------------

  describe "R2: the DSL carries deviations only" do
    setup do
      article = create!(Article, %{title: "A"})
      %{article: article}
    end

    test "there is no per-action `enable` entry in the section" do
      # R2: "There are no per-action 'enable' entries."
      entity_names =
        Spark.Dsl.Extension.get_entities(Article, [:hateoas])
        |> Enum.map(&(&1.__struct__ |> Module.split() |> List.last()))
        |> Enum.uniq()

      refute "Inclusion" in entity_names
      refute "Enable" in entity_names

      section_entity_names =
        AshHateoas.Resource.sections()
        |> Enum.find(&(&1.name == :hateoas))
        |> Map.fetch!(:entities)
        |> Enum.map(& &1.name)
        |> MapSet.new()

      assert section_entity_names == MapSet.new([:exclude, :override]),
             "the section must expose exclude/override only, got: #{inspect(section_entity_names)}"
    end

    test "exclude withholds a routed action from advertisement", %{article: article} do
      envelope = afford(article, @admin)

      refute Map.has_key?(envelope, :internal_reconcile),
             "the resource's own `exclude` must apply with no caller options"
    end

    test "exclude hides the affordance but does not remove the route" do
      routes = AshJsonApi.Resource.Info.routes(Article, [Domain])

      assert Enum.any?(routes, &(&1.action == :internal_reconcile)),
             "exclude is an advertisement deviation, not a routing change"
    end

    test "override replaces only the derived href, leaving siblings alone", %{article: article} do
      envelope = afford(article, @admin)

      assert envelope[:publish].href == "/custom/publish/:id"
      assert envelope[:update].href == "/articles/:id"
    end

    test "an override does not change anything but href", %{article: article} do
      envelope = afford(article, @admin)
      publish = envelope[:publish]

      assert publish.method == :patch, "override :href must not disturb the derived method"
      assert publish.description == "Publish this article."
      assert publish.name == :publish
    end

    test "a resource carrying the extension with no block behaves as if fully derived" do
      # Derived has no hateoas block: no exclusions, no overrides.
      assert AshHateoas.Resource.Info.exclusions(Derived) == []
      assert AshHateoas.Resource.Info.overrides(Derived) == %{}
    end

    # R2: "A compile-time verifier rejects an exclude/override naming an
    # action that does not exist."
    #
    # HOW THIS SURFACES, and why these tests assert on stderr:
    #
    # Ash resources run Spark verifiers from `@after_verify` (spark/lib/spark/
    # dsl.ex:464), which Elixir invokes AFTER the module is already compiled.
    # By then `Code.compile_string/1` has returned successfully, so Elixir
    # downgrades the failure to a diagnostic on stderr. This holds whether the
    # verifier raises or returns {:error, _} — it is Ash's architecture, not a
    # property of our verifier.
    #
    # VerifyActions returns {:error, _} rather than raising, per the documented
    # Spark.Dsl.Verifier contract, so a host app compiling normally through
    # `mix compile` gets a real build failure. The diagnostic below is what the
    # same condition looks like under `Code.compile_string/1`.
    #
    # What is actually guaranteed, and asserted here: the condition is detected,
    # reported loudly, and names both the offending entry and the known actions.
    # A silent success would fail these tests.
    test "the verifier rejects an `exclude` naming a nonexistent action" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          compile_resource(
            "AshHateoasReqTest.BadExclude#{System.unique_integer([:positive])}",
            "exclude :no_such_action",
            "defaults [:read]"
          )
        end)

      assert stderr =~ "DslError",
             "a bogus `exclude` must be reported as a DslError, got: #{stderr}"

      assert stderr =~ "does not exist"
      assert stderr =~ "no_such_action", "the diagnostic must name the offending action"
    end

    test "the verifier rejects an `override` naming a nonexistent action" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          compile_resource(
            "AshHateoasReqTest.BadOverride#{System.unique_integer([:positive])}",
            ~s(override :also_not_real, href: "/x"),
            "defaults [:read]"
          )
        end)

      assert stderr =~ "DslError"
      assert stderr =~ "does not exist"
      assert stderr =~ "also_not_real"
    end

    test "VerifyActions returns {:error, _} rather than raising" do
      # The contract that makes the above a real build failure under `mix
      # compile`: Spark collects a RETURNED error into final_errors and raises
      # it (spark/lib/spark/dsl.ex:509-541); a RAISED one is rescued into the
      # same list but cannot be observed as data. Calling the verifier directly
      # asserts the contract without depending on compilation timing.
      name = "AshHateoasReqTest.DirectVerify#{System.unique_integer([:positive])}"

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        compile_resource(name, "exclude :nope_not_here", "defaults [:read]")
      end)

      dsl_state = Module.concat([name]).spark_dsl_config()

      assert {:error, %Spark.Error.DslError{} = error} =
               AshHateoas.Resource.Verifiers.VerifyActions.verify(dsl_state)

      assert Exception.message(error) =~ "does not exist"
    end

    test "a resource whose exclude/override are all valid compiles cleanly" do
      # The happy-path counterpart: the verifier must not be so eager that a
      # correct declaration fails. Also covers the edge case that the
      # verifier's contract is "the action exists", not "the action is
      # routed" — excluding an unrouted action is a harmless no-op.
      name = "AshHateoasReqTest.ExcludesUnrouted#{System.unique_integer([:positive])}"

      Spark.Test.refute_dsl_errors do
        compile_resource(name, "exclude :destroy", "defaults [:read, :destroy]")
      end

      assert Module.concat([name]) |> AshHateoas.Resource.Info.exclusions() == [:destroy]
    end

    test "the verifier error names the offending action and the known actions" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          compile_resource(
            "AshHateoasReqTest.BadExcludeMessage#{System.unique_integer([:positive])}",
            "exclude :typo_action",
            "defaults [:read]"
          )
        end)

      assert stderr =~ "typo_action", "the error must name the offending entry"
      assert stderr =~ "read", "the error must list the known actions to aid the fix"

      assert stderr =~ "renamed" or stderr =~ "removed",
             "the error should say what to do about it, not just what is wrong"
    end

    test "a build carrying a bogus exclude does not SILENTLY succeed" do
      # The consequence R2 exists to prevent: "a renamed action fails the build
      # rather than silently losing its deviation."
      #
      # `silently` is the operative word. Under `Code.compile_string/1` the
      # module does load — Ash runs verifiers from @after_verify, after
      # compilation has already succeeded — so the reachable guarantee is that
      # the condition is never passed over in silence. Under `mix compile`,
      # where the returned {:error, _} is raised by Spark, it is a hard failure.
      name = "AshHateoasReqTest.SilentlySucceeds#{System.unique_integer([:positive])}"

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          compile_resource(name, "exclude :ghost_action", "defaults [:read]")
        end)

      refute stderr == "",
             "a dead `exclude :ghost_action` was accepted with no diagnostic at all"

      assert stderr =~ "ghost_action"

      # And the verifier itself reports it as an error, which is what makes a
      # normal `mix compile` fail rather than warn.
      dsl_state = Module.concat([name]).spark_dsl_config()

      assert {:error, _} = AshHateoas.Resource.Verifiers.VerifyActions.verify(dsl_state)
    end

    test "caller options still win over the declaration", %{article: article} do
      envelope = afford(article, @admin, overrides: %{publish: [href: "/caller"]})

      assert envelope[:publish].href == "/caller"
    end
  end

  # ------------------------------------------------------------------
  # R5 — fixed envelope shape
  # ------------------------------------------------------------------

  describe "R5: the envelope is a map of action name => Affordance" do
    setup do
      doc = create!(Document, %{title: "T", owner_id: @admin.id})
      %{doc: doc}
    end

    test "the envelope is a plain map keyed by atom action names", %{doc: doc} do
      envelope = afford(doc, @admin)

      assert is_map(envelope)

      for {key, value} <- envelope do
        assert is_atom(key), "envelope keys must be action name atoms, got #{inspect(key)}"
        assert %Affordance{} = value
      end
    end

    test "the key always equals the affordance's own name", %{doc: doc} do
      for {key, %Affordance{name: name}} <- afford(doc, @admin) do
        assert key == name, "key #{inspect(key)} disagrees with affordance name #{inspect(name)}"
      end
    end

    test "nothing surviving yields an empty map, never nil", %{doc: doc} do
      assert afford(doc, @viewer, exclude: [:read, :update, :archive, :approve, :destroy]) == %{}
    end
  end

  describe "R5: an Affordance's shape is fixed" do
    @affordance_keys MapSet.new([:name, :href, :method, :description, :fields, :multi_step?])

    test "every affordance from every resource has exactly the documented keys" do
      for affordance <- every_affordance() do
        actual = affordance |> Map.from_struct() |> Map.keys() |> MapSet.new()

        assert actual == @affordance_keys,
               "#{inspect(affordance.name)} has keys #{inspect(MapSet.to_list(actual))}, " <>
                 "expected #{inspect(MapSet.to_list(@affordance_keys))}"
      end
    end

    test "types below the key are fixed across every affordance" do
      # R5: "Only the SET of actions is dynamic ... Everything below that key is
      # fixed." So no affordance may, for example, carry a string method here
      # and an atom there, or a nil fields list.
      for a <- every_affordance() do
        assert is_atom(a.name)

        assert is_nil(a.href) or is_binary(a.href),
               "href must be a string or nil, got #{inspect(a.href)}"

        assert is_atom(a.method) and not is_nil(a.method), "method must always be a present atom"

        assert is_nil(a.description) or is_binary(a.description),
               "description must be a string or nil"

        assert is_list(a.fields), "fields must always be a list, never nil"
        assert is_boolean(a.multi_step?), "multi_step? must always be a boolean, never nil"
      end
    end

    test "the shape does not vary across records of the same resource" do
      # Two orders in different states advertise different SETS, but each
      # affordance is structurally identical.
      pending = create!(Order, %{reference: "s1"})

      confirmed =
        create!(Order, %{reference: "s2"})
        |> Ash.Changeset.for_update(:confirm, %{})
        |> Ash.update!(authorize?: false)

      a = afford(pending, @admin)
      b = afford(confirmed, @admin)

      refute keys(a) == keys(b), "precondition: the two states must differ in their action set"

      for envelope <- [a, b], {_name, affordance} <- envelope do
        assert affordance |> Map.from_struct() |> Map.keys() |> MapSet.new() ==
                 @affordance_keys
      end
    end

    test "the shape does not vary across actors" do
      doc = create!(Document, %{title: "T", owner_id: @admin.id})

      for actor <- [@admin, @viewer], {_name, affordance} <- afford(doc, actor) do
        assert affordance |> Map.from_struct() |> Map.keys() |> MapSet.new() ==
                 @affordance_keys
      end
    end

    test "multi_step? defaults to false rather than being absent" do
      # R5 calls it "an optional multi_step flag". Optional means the flag may
      # be false, not that the key may vanish.
      for a <- every_affordance() do
        assert Map.has_key?(a, :multi_step?)
        assert a.multi_step? in [true, false]
      end
    end
  end

  describe "R5: a Field's shape is fixed" do
    @field_keys MapSet.new([:name, :type, :allow_nil?, :description, :default, :constraints])

    test "every field from every affordance has exactly the documented keys" do
      for affordance <- every_affordance(), f <- affordance.fields do
        actual = f |> Map.from_struct() |> Map.keys() |> MapSet.new()

        assert actual == @field_keys,
               "field #{inspect(f.name)} has keys #{inspect(MapSet.to_list(actual))}"
      end
    end

    test "field value types are fixed" do
      for affordance <- every_affordance(), f <- affordance.fields do
        assert is_atom(f.name)

        assert is_binary(f.type),
               "type must be a wire-format string, got #{inspect(f.type)} for #{inspect(f.name)}"

        assert is_boolean(f.allow_nil?), "allow_nil? must always be a boolean"

        assert is_nil(f.description) or is_binary(f.description),
               "description must be a string or nil"

        assert f.default == :error or match?({:ok, _}, f.default),
               "default must be :error or {:ok, value}, got #{inspect(f.default)}"

        assert is_map(f.constraints), "constraints must always be a map, never nil or a keyword"
      end
    end

    test "a type module never leaks into the wire format" do
      for affordance <- every_affordance(), f <- affordance.fields do
        refute f.type =~ "Elixir.",
               "#{inspect(f.name)} leaked a module name into the wire type: #{f.type}"
      end
    end

    test "a sensitive field appears but carries no default" do
      doc = create!(Document, %{title: "T", owner_id: @admin.id})
      approve = afford(doc, @admin)[:approve]

      key = field(approve, :signing_key)

      assert key, "a sensitive argument must still be advertised as a field"
      assert key.default == :error, "a sensitive argument's default must never reach the wire"
    end

    test "a non-sensitive default is wrapped so nil stays distinguishable" do
      doc = create!(Document, %{title: "T", owner_id: @admin.id})
      approve = afford(doc, @admin)[:approve]

      assert field(approve, :notify).default == {:ok, false}

      # :note has no default at all, which must read as :error, NOT {:ok, nil}.
      assert field(approve, :note).default == :error,
             "an argument with no default must be :error, not {:ok, nil}"
    end

    test "constraints carry enum derived from one_of" do
      doc = create!(Document, %{title: "T", owner_id: @admin.id})
      approve = afford(doc, @admin)[:approve]

      assert field(approve, :visibility).constraints[:enum] == [:public, :private]
    end

    test "an affordance with no inputs has an empty field list, not nil" do
      order = create!(Order, %{reference: "f1"})

      cancel = afford(order, @admin)[:cancel]

      assert cancel, "precondition: :cancel is legal from :pending"
      assert cancel.fields == [], ":cancel accepts nothing, so fields must be [] and not nil"
    end

    test "field names are unique within an affordance" do
      # An action's inputs are its accepted attributes PLUS its public
      # arguments. If an argument shadows an accepted attribute the same name
      # would appear twice, which no transport can represent (JSON Schema
      # properties and MCP inputSchema are both keyed by name).
      for affordance <- every_affordance() do
        names = Enum.map(affordance.fields, & &1.name)

        assert names == Enum.uniq(names),
               "#{inspect(affordance.name)} has duplicate field names: #{inspect(names)}"
      end
    end

    test "no private argument ever becomes a field" do
      doc = create!(Document, %{title: "T", owner_id: @admin.id})
      approve = afford(doc, @admin)[:approve]

      refute field(approve, :internal_trace),
             "a non-public argument must never be advertised"
    end
  end

  describe "R5: the shape is stable across transports" do
    test "the JSON:API renderer projects from the same fixed shape" do
      doc = create!(Document, %{title: "T", owner_id: @admin.id})
      envelope = afford(doc, @admin)

      rendered = AshHateoas.JsonApi.Renderer.render(envelope, path_params: %{"id" => doc.id})

      assert Map.keys(rendered) |> Enum.sort() ==
               envelope |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort(),
             "the renderer must emit one link per affordance, no more and no less"

      for {_name, link} <- rendered do
        assert Map.has_key?(link, "href")
        assert Map.has_key?(link, "rel")
        assert Map.has_key?(link, "meta")
        assert Map.has_key?(link["meta"], "method")
        assert Map.has_key?(link["meta"], "fields")
      end
    end

    test "required inverts allow_nil? exactly once, at the edge" do
      # R5: `AshHateoas.Field` carries Ash's `allow_nil?`; the wire says
      # `required`. The inversion belongs in the renderer, so a field the
      # resource declares as non-nillable must arrive as required — and one it
      # allows to be nil must not.
      doc = create!(Document, %{title: "T", owner_id: @admin.id})
      envelope = afford(doc, @admin)

      for {name, affordance} <- envelope, affordance.fields != [] do
        rendered =
          %{name => affordance}
          |> AshHateoas.JsonApi.Renderer.render()
          |> Map.fetch!(to_string(name))
          |> get_in(["meta", "fields"])
          |> Map.new(fn field -> {field["name"], field["required"]} end)

        for field <- affordance.fields do
          assert rendered[to_string(field.name)] == not field.allow_nil?,
                 "#{inspect(name)}.#{field.name}: allow_nil? #{field.allow_nil?} " <>
                   "rendered as required #{inspect(rendered[to_string(field.name)])}"
        end
      end
    end

  end

  # Spark verifiers run in `__verify_spark_dsl__`, invoked at module
  # compile time, so the DslError escapes an inline `defmodule` rather than
  # propagating to `assert_raise`. Compiling a source string puts the raise
  # back in this process, which is what lets the requirement be asserted.
  defp compile_resource(name, hateoas_body, actions_body) do
    Code.compile_string("""
    defmodule #{name} do
      use Ash.Resource,
        domain: nil,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshHateoas.Resource]

      hateoas do
        warn_on_missing_authorizers?(false)
        #{hateoas_body}
      end

      attributes do
        uuid_primary_key :id
      end

      actions do
        #{actions_body}
      end
    end
    """)
  end

  # Every affordance the test domain can produce, across record- and
  # collection-level entry points, several actors and several resources. The
  # shape assertions above run over all of them, so a structural regression on
  # any one resource fails.
  defp every_affordance do
    doc = create!(Document, %{title: "T", owner_id: @admin.id})
    article = create!(Article, %{title: "A"})
    order = create!(Order, %{reference: unique("ref")})
    note = create!(PublicNote, %{text: "n"})
    derived = create!(Derived, %{label: "d"})
    unrouted = create!(Unrouted, %{label: "u"})

    records = [doc, article, order, note, derived, unrouted]
    resources = [Document, Article, Order, PublicNote, Derived, Unrouted]
    actors = [@admin, @viewer, nil]

    record_level =
      for record <- records, actor <- actors, {_name, a} <- afford(record, actor), do: a

    collection_level =
      for resource <- resources, actor <- actors, {_name, a} <- afford(resource, actor), do: a

    result = record_level ++ collection_level

    # Guard against the whole suite silently passing on an empty list.
    assert result != []

    result
  end
end
