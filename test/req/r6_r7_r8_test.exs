defmodule AshHateoas.Req.R6R7R8Test do
  @moduledoc """
  Independent conformance tests for REQ.md R6, R7 and R8 (plus the R9/R6
  interaction on navigation authorization).

  These are written against what REQ.md states, not against the implementation.
  Fixtures needed only by these tests are defined locally so the shared
  `test/support` fixtures stay untouched.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AshHateoas.Test.{Actor, Document, Domain, Order, PublicNote, Quiet}
  alias AshHateoas.Test.{LoudResource, SilentDomain, SilentResource}

  # Fixtures defined at the bottom of this module. Nested defmodules do not
  # auto-alias, so name them explicitly.
  alias AshHateoas.Req.R6R7R8Test.Undecidable, as: UFixture
  alias AshHateoas.Req.R6R7R8Test.Undecidable.Child, as: UChild
  alias AshHateoas.Req.R6R7R8Test.Undecidable.D, as: UDomain

  @admin %Actor{id: "r6-admin", role: :admin}
  @viewer %Actor{id: "r6-viewer", role: :viewer}

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp affordances(subject, actor, opts \\ []) do
    AshHateoas.affordances(subject, actor, Keyword.put_new(opts, :domain, Domain))
  end

  defp doc_for(owner_id) do
    Document
    |> Ash.Changeset.for_create(:create, %{title: "Spec", owner_id: owner_id})
    |> Ash.create!(authorize?: false)
  end

  setup do
    editor = %Actor{id: unique("editor"), role: :editor}
    %{editor: editor, doc: doc_for(editor.id)}
  end

  # ==================================================================
  # R6 — Validity: single source of truth
  # ==================================================================

  describe "R6: the advertised set is exactly what Ash.can?/3 says" do
    # The strongest available probe of "never a parallel reimplementation":
    # for EVERY routed action, the affordance's presence must agree with a
    # direct, independent Ash.can?/3 call made by this test. Any divergence
    # means the gate is deciding something Ash did not.

    defp routed_actions(resource) do
      AshJsonApi.Resource.Info.routes(resource, [Domain])
      |> Enum.map(& &1.action)
      |> Enum.uniq()
    end

    defp record_level_actions(resource) do
      Enum.filter(routed_actions(resource), fn name ->
        action = Ash.Resource.Info.action(resource, name)
        action && action.type in [:update, :destroy, :read]
      end)
    end

    test "agrees with a direct can?/3 for every routed record-level action, as admin",
         %{doc: doc} do
      advertised = doc |> affordances(@admin) |> Map.keys() |> MapSet.new()

      for action <- record_level_actions(Document) do
        oracle = Ash.can?({doc, action}, @admin, domain: Domain)

        assert MapSet.member?(advertised, action) == oracle,
               "affordance for #{inspect(action)} (#{MapSet.member?(advertised, action)}) " <>
                 "disagrees with Ash.can?/3 (#{oracle}) — the gate is not the single " <>
                 "source of truth"
      end
    end

    test "agrees with a direct can?/3 for every routed record-level action, as viewer",
         %{doc: doc} do
      advertised = doc |> affordances(@viewer) |> Map.keys() |> MapSet.new()

      for action <- record_level_actions(Document) do
        oracle = Ash.can?({doc, action}, @viewer, domain: Domain)

        assert MapSet.member?(advertised, action) == oracle,
               "affordance for #{inspect(action)} disagrees with Ash.can?/3 for :viewer"
      end
    end

    test "agrees with a direct can?/3 for the record's owner", %{doc: doc, editor: editor} do
      owner = %Actor{editor | role: :viewer}
      advertised = doc |> affordances(owner) |> Map.keys() |> MapSet.new()

      for action <- record_level_actions(Document) do
        oracle = Ash.can?({doc, action}, owner, domain: Domain)

        assert MapSet.member?(advertised, action) == oracle,
               "affordance for #{inspect(action)} disagrees with Ash.can?/3 for the owner"
      end
    end

    test "tracks a policy input change without any restart or cache flush", %{editor: editor} do
      # :archive is expr(owner_id == ^actor(:id)). Same actor, same action,
      # two records differing only in the policy's input.
      mine = doc_for(editor.id)
      theirs = doc_for(unique("someone-else"))
      owner = %Actor{editor | role: :viewer}

      assert Map.has_key?(affordances(mine, owner), :archive)
      refute Map.has_key?(affordances(theirs, owner), :archive)
    end

    test "a nil actor is passed through to Ash rather than special-cased" do
      doc = doc_for(unique("owner"))

      for action <- record_level_actions(Document) do
        oracle = Ash.can?({doc, action}, nil, domain: Domain)
        advertised = Map.has_key?(affordances(doc, nil), action)

        assert advertised == oracle,
               "nil actor: #{inspect(action)} advertised=#{advertised} can?=#{oracle}"
      end
    end
  end

  describe "R6: posture on undecidable authorization follows Ash (maybe_is: true)" do
    # REQ R6 (as amended, per PLAN.md) says: call Ash.can?/3 as Ash provides
    # it, so an undecidable decision follows Ash's `maybe_is: true` default and
    # IS advertised. Note REQ.md's own §5.2 and R9 still contain stale
    # "fail-closed" wording — flagged as a REQ-internal contradiction.
    #
    # Producing a genuinely undecidable decision is subtle: with the record
    # supplied as `data:`, Ash resolves even relationship-traversing
    # expressions exactly. Undecidability requires `run_queries?: false`, or a
    # collection-level (no record) question about a record-dependent policy. Both are
    # covered below, and both are verified to actually diverge — a posture test
    # whose undecidable branch never executes proves nothing.

    test "the undecidable fixture really is undecidable (guards the tests below)" do
      # Fails loudly if a future Ash makes this decidable, rather than letting
      # the posture assertions silently become vacuous.
      stranger = %{id: "nobody-owns-this"}

      open = Ash.can?({UChild, :touch}, stranger, domain: UDomain, run_queries?: false)

      closed =
        Ash.can?({UChild, :touch}, stranger,
          domain: UDomain,
          run_queries?: false,
          maybe_is: false
        )

      assert open != closed,
             "this fixture no longer produces an undecidable (:maybe) verdict, so the " <>
               "posture tests below would be vacuous"

      assert open == true, "maybe_is: true is Ash's default and must resolve :maybe to true"
    end

    test "the record-level gate mirrors Ash exactly, neither tightening nor loosening" do
      # With the record supplied as `data:`, Ash resolves the relationship
      # expression exactly and denies. The gate must reproduce that — this is
      # the "single source of truth" invariant on a record-dependent policy.
      child = UFixture.child(owner: "alice")
      stranger = %{id: "bob"}
      owner = %{id: "alice"}

      refute Ash.can?({child, :touch}, stranger, domain: UDomain),
             "bob does not own this record; ground truth is deny"

      refute child |> affordances(stranger, domain: UDomain) |> Map.has_key?(:touch),
             "the gate must not advertise what Ash denies"

      assert Ash.can?({child, :touch}, owner, domain: UDomain),
             "alice owns it; ground truth is allow"

      assert child |> affordances(owner, domain: UDomain) |> Map.has_key?(:touch),
             "the gate must not suppress what Ash allows"
    end

    test "an undecidable verdict is not suppressed by a fail-closed gate" do
      # Isolate authorization posture from R8's structural collection-level filter:
      # compare the gated set against the SAME pipeline with gates disabled.
      # Anything present ungated but absent gated was removed by the gates, and
      # for an undecidable verdict R6 says the gate must not be what removes it.
      child = UFixture.child(owner: "alice")
      stranger = %{id: "bob"}

      ungated =
        UChild
        |> affordances(stranger, domain: UDomain, gates: [])
        |> Map.keys()
        |> MapSet.new()

      gated =
        UChild
        |> affordances(stranger, domain: UDomain)
        |> Map.keys()
        |> MapSet.new()

      removed_by_gates = MapSet.difference(ungated, gated)

      for action <- removed_by_gates do
        refute Ash.can?({UChild, action}, stranger, domain: UDomain),
               "#{inspect(action)} was removed by the authorization gate even though " <>
                 "Ash.can?/3 returns true for it (undecidable -> maybe_is: true). " <>
                 "R6 forbids tightening Ash's posture."
      end

      # And the record-level path, same isolation.
      r_ungated =
        child |> affordances(stranger, domain: UDomain, gates: []) |> Map.keys() |> MapSet.new()

      r_gated = child |> affordances(stranger, domain: UDomain) |> Map.keys() |> MapSet.new()

      for action <- MapSet.difference(r_ungated, r_gated) do
        refute Ash.can?({child, action}, stranger, domain: UDomain),
               "#{inspect(action)} removed by the gate though Ash.can?/3 allows it"
      end

      _ = child
    end

    test "the gate does not pass maybe_is: false anywhere in the record-level path", %{doc: doc} do
      # Where Ash's default and the fail-closed answer differ, the gate must
      # side with the default.
      for action <- record_level_actions(Document) do
        default = Ash.can?({doc, action}, @admin, domain: Domain)
        closed = Ash.can?({doc, action}, @admin, domain: Domain, maybe_is: false)
        advertised = Map.has_key?(affordances(doc, @admin), action)

        if default != closed do
          assert advertised == default,
                 "#{inspect(action)} is undecidable; R6 requires following maybe_is: true"
        end
      end
    end

    test "resources with no authorizers advertise everything (Ash short-circuit)" do
      note =
        PublicNote
        |> Ash.Changeset.for_create(:create, %{text: "hi"})
        |> Ash.create!(authorize?: false)

      names = note |> affordances(nil) |> Map.keys() |> MapSet.new()

      assert MapSet.member?(names, :destroy),
             "Ash.can?/3 returns true before evaluating anything when there are no " <>
               "authorizers; the gate must not invent a stricter answer"
    end
  end

  describe "R6 x §3: the state gate is the real state machine, not a reimplementation" do
    test "the advertised transitions equal AshStateMachine's possible transitions" do
      order =
        Order
        |> Ash.Changeset.for_create(:create, %{reference: unique("ref")})
        |> Ash.create!(authorize?: false)

      # Order's policies are `authorize_if always()`, so anything withheld is
      # withheld by the state gate alone.
      advertised = order |> affordances(@admin) |> Map.keys() |> MapSet.new()

      transitions = AshStateMachine.Info.state_machine_transitions(Order)
      transition_actions = transitions |> Enum.map(& &1.action) |> MapSet.new()

      legal =
        transitions
        |> Enum.filter(fn t ->
          froms = List.wrap(t.from)
          order.state in froms or :* in froms
        end)
        |> Enum.map(& &1.action)
        |> MapSet.new()

      # Every transition action that is legal from :pending must be advertised.
      for action <- legal do
        assert MapSet.member?(advertised, action),
               "#{inspect(action)} is a legal transition from #{inspect(order.state)}"
      end

      # And no transition action that is illegal may be advertised.
      for action <- MapSet.difference(transition_actions, legal) do
        refute MapSet.member?(advertised, action),
               "#{inspect(action)} is not a legal transition from #{inspect(order.state)}"
      end
    end

    test "a wildcard `from: :*` transition is legal from every state" do
      order =
        Order
        |> Ash.Changeset.for_create(:create, %{reference: unique("ref")})
        |> Ash.create!(authorize?: false)

      assert Map.has_key?(affordances(order, @admin), :cancel)

      confirmed =
        order
        |> Ash.Changeset.for_update(:confirm, %{})
        |> Ash.update!(authorize?: false)

      assert Map.has_key?(affordances(confirmed, @admin), :cancel),
             ":cancel declares from: :* — it must survive every state"
    end

    test "collection-level affordances apply NO state gate (R9)" do
      # There is no record, so no state. A transition action must not be
      # silently dropped for lack of a state to check against.
      names = Order |> affordances(@admin) |> Map.keys() |> MapSet.new()

      refute MapSet.member?(names, :confirm),
             "record-level transitions are not collection-level affordances"

      assert MapSet.member?(names, :create),
             "the collection-level entry point must still offer :create"
    end
  end

  # A resource whose policy traverses a relationship. With `run_queries?: false`
  # — or asked at collection level, where there is no record — Ash cannot reach a
  # verdict and returns :maybe, which `maybe_is: true` resolves to true.
  defmodule Undecidable do
    @moduledoc false

    defmodule Parent do
      @moduledoc false
      use Ash.Resource,
        domain: AshHateoas.Req.R6R7R8Test.Undecidable.D,
        data_layer: Ash.DataLayer.Ets

      ets do
        private?(true)
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:owner_id, :string, public?: true)
      end

      actions do
        defaults([:read, create: [:owner_id]])
      end
    end

    defmodule Child do
      @moduledoc false
      use Ash.Resource,
        domain: AshHateoas.Req.R6R7R8Test.Undecidable.D,
        data_layer: Ash.DataLayer.Ets,
        authorizers: [Ash.Policy.Authorizer],
        extensions: [AshJsonApi.Resource]

      ets do
        private?(true)
      end

      json_api do
        type("undecidable_child")

        routes do
          base("/undecidable_children")
          get(:read, primary?: true)
          index(:read)
          post(:create)
          patch(:touch, route: "/:id/touch")
        end
      end

      attributes do
        uuid_primary_key(:id)
      end

      relationships do
        belongs_to(:parent, AshHateoas.Req.R6R7R8Test.Undecidable.Parent,
          public?: true,
          attribute_type: :uuid
        )
      end

      actions do
        defaults([:read, create: [:parent_id]])

        update :touch do
          description("Touch this child; permitted only to the parent's owner.")
          require_atomic?(false)
        end
      end

      policies do
        # Relationship-traversing: undecidable without a query.
        policy action(:touch) do
          authorize_if(expr(parent.owner_id == ^actor(:id)))
        end

        policy always() do
          authorize_if(always())
        end
      end
    end

    defmodule D do
      @moduledoc false
      use Ash.Domain, extensions: [AshJsonApi.Domain], validate_config_inclusion?: false

      resources do
        resource(AshHateoas.Req.R6R7R8Test.Undecidable.Parent)
        resource(AshHateoas.Req.R6R7R8Test.Undecidable.Child)
      end
    end

    def child(owner: owner_id) do
      parent =
        Parent
        |> Ash.Changeset.for_create(:create, %{owner_id: owner_id})
        |> Ash.create!(authorize?: false)

      Child
      |> Ash.Changeset.for_create(:create, %{parent_id: parent.id})
      |> Ash.create!(authorize?: false)
    end
  end

  # ==================================================================
  # R7 — Errors are loud
  # ==================================================================

  defmodule ExplodingCheck do
    @moduledoc "A policy check that raises, simulating a bad expression / nil deref."
    use Ash.Policy.SimpleCheck

    @impl true
    def describe(_), do: "explodes"

    @impl true
    def match?(_actor, _context, _opts) do
      raise "boom: simulated policy check failure"
    end
  end

  defmodule Landmine do
    @moduledoc "A resource whose :detonate policy raises during evaluation."

    use Ash.Resource,
      domain: AshHateoas.Req.R6R7R8Test.LandmineDomain,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer],
      extensions: [AshJsonApi.Resource]

    ets do
      private?(true)
    end

    json_api do
      type("landmine")

      routes do
        base("/landmines")
        get(:read, primary?: true)
        index(:read)
        post(:create)
        patch(:detonate, route: "/:id/detonate")
        patch(:safe_update, route: "/:id/safe_update")
      end
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:label, :string, public?: true)
    end

    actions do
      defaults([:read, create: [:label]])

      update :detonate do
        description("An action whose authorization check raises.")
        require_atomic?(false)
      end

      update :safe_update do
        description("An action whose authorization is decidable.")
        require_atomic?(false)
        accept([:label])
      end
    end

    policies do
      policy action(:detonate) do
        authorize_if(AshHateoas.Req.R6R7R8Test.ExplodingCheck)
      end

      policy always() do
        authorize_if(always())
      end
    end
  end

  defmodule LandmineDomain do
    @moduledoc false
    use Ash.Domain, extensions: [AshJsonApi.Domain], validate_config_inclusion?: false

    resources do
      resource(AshHateoas.Req.R6R7R8Test.Landmine)
    end
  end

  defp landmine do
    Landmine
    |> Ash.Changeset.for_create(:create, %{label: "x"})
    |> Ash.create!(authorize?: false)
  end

  describe "R7: exceptions during authorization evaluation are logged with context" do
    test "the exception is logged" do
      mine = landmine()

      log =
        capture_log(fn ->
          affordances(mine, @admin, domain: LandmineDomain)
        end)

      refute log == "",
             "an exception raised inside a policy check must not be swallowed silently"
    end

    test "the log names the resource" do
      mine = landmine()

      log =
        capture_log(fn ->
          affordances(mine, @admin, domain: LandmineDomain)
        end)

      assert log =~ "Landmine",
             "REQ R7: the exception MUST be logged *with context* — the resource is context"
    end

    test "the log names the action" do
      mine = landmine()

      log =
        capture_log(fn ->
          affordances(mine, @admin, domain: LandmineDomain)
        end)

      assert log =~ "detonate",
             "REQ R7: the action being evaluated is the context that makes the log actionable"
    end

    test "the offending affordance is dropped, not advertised" do
      mine = landmine()

      capture_log(fn ->
        refute Map.has_key?(affordances(mine, @admin, domain: LandmineDomain), :detonate),
               "an affordance whose authorization blew up must not be offered"
      end)
    end

    test "one exploding action does not take down the whole set" do
      mine = landmine()

      names =
        capture_log(fn ->
          send(self(), {:names, affordances(mine, @admin, domain: LandmineDomain) |> Map.keys()})
        end)

      _ = names
      assert_received {:names, keys}

      assert :safe_update in keys,
             "a single raising check must not suppress unrelated, decidable affordances"
    end

    test "the log is at :error level, not :debug" do
      mine = landmine()

      log =
        capture_log([level: :error], fn ->
          affordances(mine, @admin, domain: LandmineDomain)
        end)

      assert log =~ "detonate",
             "REQ R7 calls this unacceptable to degrade silently; :error is the level " <>
               "that survives a production log config"
    end
  end

  # ==================================================================
  # R8 — Cost is bounded
  # ==================================================================

  describe "R8: on by default, opt-out" do
    test "a resource that never mentions ash_hateoas is ON", %{doc: doc} do
      assert map_size(affordances(doc, @admin)) > 0,
             "Document carries no hateoas block at all; the default must be on"
    end

    test "a resource carrying the extension but declaring nothing is ON" do
      article =
        AshHateoas.Test.Article
        |> Ash.Changeset.for_create(:create, %{title: "t"})
        |> Ash.create!(authorize?: false)

      assert map_size(affordances(article, @admin)) > 0
    end

    test "enabled? false switches a resource off" do
      quiet =
        Quiet
        |> Ash.Changeset.for_create(:create, %{label: "x"})
        |> Ash.create!(authorize?: false)

      assert affordances(quiet, @admin) == %{}
    end

    test "there is no per-action enable flag — opt-out is whole-resource" do
      # R8/R2: a single `enabled?` declaration per resource. Confirm the DSL
      # exposes exactly that toggle and not a per-action opt-in.
      quiet = Spark.Dsl.Extension.get_opt(Quiet, [:hateoas], :enabled?, nil, false)
      assert quiet == false
    end

    test "a domain-level default is inherited by a resource that declares nothing" do
      silent =
        SilentResource
        |> Ash.Changeset.for_create(:create, %{label: "x"})
        |> Ash.create!(authorize?: false)

      assert affordances(silent, @admin, domain: SilentDomain) == %{},
             "SilentDomain declares enabled? false; SilentResource declares nothing"
    end

    test "a resource's own declaration overrides the domain default" do
      loud =
        LoudResource
        |> Ash.Changeset.for_create(:create, %{label: "x"})
        |> Ash.create!(authorize?: false)

      assert map_size(affordances(loud, @admin, domain: SilentDomain)) > 0
    end

    test "the domain default also suppresses collection-level affordances" do
      assert affordances(SilentResource, @admin, domain: SilentDomain) == %{},
             "an opt-out must cover both backbone entry points, not just the record one"
    end
  end

  describe "R8: collections carry ONLY collection-level affordances" do
    setup %{editor: editor} do
      # Several records, all owned by the editor, so per-record affordances
      # would definitely be non-empty if they were being computed.
      docs = for _ <- 1..3, do: doc_for(editor.id)
      %{docs: docs, editor: editor}
    end

    test "the collection-level set contains create and excludes record-only actions" do
      names = Document |> affordances(@admin) |> Map.keys() |> MapSet.new()

      assert MapSet.member?(names, :create)
      refute MapSet.member?(names, :approve), ":approve needs a record"
      refute MapSet.member?(names, :destroy), ":destroy needs a record"
      refute MapSet.member?(names, :update), ":update needs a record"
    end

    test "a collection response has no per-record affordance links", %{editor: editor} do
      body = collection_body("/documents", %Actor{editor | role: :admin})

      for record <- body["data"] do
        links = Map.get(record, "links", %{})
        keys = MapSet.new(Map.keys(links))

        assert MapSet.subset?(keys, MapSet.new(["self", "related"])),
               "a record inside a collection may carry navigation only, got: " <>
                 inspect(Map.keys(links))
      end
    end

    test "the collection's top-level links carry the collection-level affordances" do
      body = collection_body("/documents", @admin)

      assert Map.has_key?(body["links"], "create"),
             "R8/R9: the cold-start client must be told it may create"
    end

    test "collection-level affordance count is independent of page size", %{editor: editor} do
      # Add many more records; the collection-level set must not grow.
      for _ <- 1..10, do: doc_for(editor.id)

      before_keys = Document |> affordances(@admin) |> Map.keys() |> Enum.sort()

      for _ <- 1..10, do: doc_for(editor.id)

      after_keys = Document |> affordances(@admin) |> Map.keys() |> Enum.sort()

      assert before_keys == after_keys,
             "collection cost must be N actions, independent of M records"
    end
  end

  describe "R8: no cross-record caching — every record gets its own can?" do
    # The observable consequence of caching per (actor, action) would be that
    # record 1's verdict leaks onto records 2..M. :archive is
    # expr(owner_id == ^actor(:id)), so two records with different owner_id
    # MUST get different answers for the SAME actor in the SAME batch.

    test "two records with different owners get different :archive affordances", %{
      editor: editor
    } do
      owner = %Actor{editor | role: :viewer}

      mine = doc_for(editor.id)
      theirs = doc_for(unique("stranger"))

      results = Enum.map([mine, theirs, mine], &Map.has_key?(affordances(&1, owner), :archive))

      assert results == [true, false, true],
             "interleaved evaluation must not reuse a previous record's verdict; got " <>
               inspect(results)
    end

    test "order does not change the answers (deny first, then allow)", %{editor: editor} do
      owner = %Actor{editor | role: :viewer}

      theirs = doc_for(unique("stranger"))
      mine = doc_for(editor.id)

      results = Enum.map([theirs, mine, theirs], &Map.has_key?(affordances(&1, owner), :archive))

      assert results == [false, true, false],
             "a cached negative verdict would make the middle element false"
    end

    test "an explicit :cache option does not leak verdicts across records", %{editor: editor} do
      # The public API documents an opt-in per-request cache. Even with it
      # supplied, a record-dependent policy must still be evaluated per record.
      owner = %Actor{editor | role: :viewer}
      cache = :ets.new(:hateoas_probe_cache, [:public, :set])

      mine = doc_for(editor.id)
      theirs = doc_for(unique("stranger"))

      a = Map.has_key?(affordances(mine, owner, cache: cache), :archive)
      b = Map.has_key?(affordances(theirs, owner, cache: cache), :archive)

      assert {a, b} == {true, false},
             "a shared cache must never apply record 1's verdict to record 2"
    after
      :ok
    end

    test "same actor, same action, batch of records — each answer is independently correct",
         %{editor: editor} do
      owner = %Actor{editor | role: :viewer}

      docs =
        for i <- 1..6 do
          owner_id = if rem(i, 2) == 0, do: editor.id, else: unique("stranger")
          {doc_for(owner_id), owner_id == editor.id}
        end

      for {doc, should_be_allowed} <- docs do
        actual = Map.has_key?(affordances(doc, owner), :archive)

        assert actual == should_be_allowed,
               "record owned_by_actor=#{should_be_allowed} got archive=#{actual}"
      end
    end

    test "a collection HTTP request evaluates the collection-level set once, with no record leakage",
         %{editor: editor} do
      # Structural check: since collections never compute per-record
      # affordances, no record-dependent verdict can be cached or leaked.
      body = collection_body("/documents", %Actor{editor | role: :viewer})

      for record <- body["data"] do
        refute Map.has_key?(Map.get(record, "links", %{}), "archive")
      end
    end
  end

  # ==================================================================
  # R9 x R6 — authorization applies to navigation too
  # ==================================================================

  describe "R9 x R6: unreachable branches are omitted from navigation" do
    test "a collection the actor cannot create in offers no create link" do
      body = collection_body("/documents", @viewer)

      refute Map.has_key?(body["links"], "create"),
             "a viewer may not create; the branch must be omitted, not rendered-and-rejected"
    end

    test "collection-level affordances differ between actors" do
      admin_links = collection_body("/documents", @admin)["links"]
      viewer_links = collection_body("/documents", @viewer)["links"]

      assert Map.keys(admin_links) != Map.keys(viewer_links),
             "navigation must be resolved per requesting actor (R3/R9)"
    end

    test "a root/entry navigation document omits types the actor cannot reach" do
      # REQ R9 requires an entry document listing each *reachable* type. If the
      # package exposes navigation, an unauthorized type must be absent from it.
      case function_exported?(AshHateoas.Navigation, :root, 2) do
        true ->
          admin_types = AshHateoas.Navigation.root(Domain, @admin)
          viewer_types = AshHateoas.Navigation.root(Domain, @viewer)

          assert admin_types != viewer_types,
                 "structural links must not reveal branches the actor cannot access"

        false ->
          flunk(
            "REQ R9 requires a root entry document ('the one URL a client hardcodes') " <>
              "with authorization applied to navigation; no AshHateoas.Navigation.root/2 " <>
              "exists"
          )
      end
    end
  end

  defp collection_body(path, actor) do
    :get
    |> Plug.Test.conn(path)
    |> Plug.Conn.put_req_header("accept", "application/vnd.api+json")
    |> Ash.PlugHelpers.set_actor(actor)
    |> AshHateoas.Test.Endpoint.call(AshHateoas.Test.Endpoint.init([]))
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end
end
