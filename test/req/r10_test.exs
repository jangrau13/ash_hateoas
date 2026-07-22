defmodule AshHateoas.Req.R10Test do
  @moduledoc """
  R10 — some actions may be advertised but not exercised by a delegated
  credential.
  """

  # Not async: the commit-authority tests swap application config, which is
  # global. Everything else here would be safe concurrently.
  use ExUnit.Case, async: false

  alias AshHateoas.Resource.Info

  describe "the declaration is verified at compile time" do
    # The stake is higher here than for `exclude`. A renamed action that
    # silently drops its `exclude` stops advertising something; one that
    # silently drops its `not_delegable` republishes an action to every
    # delegated credential, with no diff to show for it.
    #
    # See r1_r2_r5_test.exs for why this asserts on stderr rather than
    # rescuing: under Code.compile_string/1 Spark reports a returned
    # {:error, _} as a diagnostic, while `mix compile` turns the same
    # condition into a build failure.
    test "the verifier rejects a `not_delegable` naming a nonexistent action" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          compile_resource(
            "AshHateoasR10Test.BadNotDelegable#{System.unique_integer([:positive])}",
            "not_delegable :no_such_action",
            "defaults [:read]"
          )
        end)

      assert stderr =~ "DslError",
             "a bogus `not_delegable` must be reported as a DslError, got: #{stderr}"

      assert stderr =~ "does not exist"
      assert stderr =~ "no_such_action", "the diagnostic must name the offending action"
    end

    test "a `not_delegable` naming a real action compiles" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          compile_resource(
            "AshHateoasR10Test.GoodNotDelegable#{System.unique_integer([:positive])}",
            "not_delegable :read",
            "defaults [:read]"
          )
        end)

      refute stderr =~ "DslError"
    end
  end

  describe "the declaration subtracts nothing" do
    # R10's distinguishing property, and the one most likely to be broken by a
    # refactor that treats every DSL entry as a filter: `not_delegable` must
    # leave the action routed and advertised. Withholding it would leave a
    # delegated actor unable to tell "does not exist" from "you may not do this
    # alone", which is the silence R10 exists to remove.
    test "a not_delegable action stays in the affordance set" do
      article =
        AshHateoas.Test.Article
        |> Ash.Changeset.for_create(:create, %{title: "R10"})
        |> Ash.create!(authorize?: false)

      affordances =
        AshHateoas.affordances(article, %AshHateoas.Test.Actor{id: "someone", role: :admin},
          domain: AshHateoas.Test.Domain
        )

      assert Map.has_key?(affordances, :publish),
             "not_delegable must not withhold the affordance: #{inspect(Map.keys(affordances))}"
    end

    test "it is declared on Article and read back" do
      assert Info.not_delegable?(AshHateoas.Test.Article, :publish)
    end
  end

  describe "the flag reaches the wire" do
    setup do
      article =
        AshHateoas.Test.Article
        |> Ash.Changeset.for_create(:create, %{title: "R10"})
        |> Ash.create!(authorize?: false)

      envelope =
        AshHateoas.affordances(article, %AshHateoas.Test.Actor{id: "someone", role: :admin},
          domain: AshHateoas.Test.Domain
        )

      %{
        rendered: AshHateoas.JsonApi.Renderer.render(envelope, path_params: %{"id" => article.id})
      }
    end

    test "a not_delegable action carries meta.notDelegable", %{rendered: rendered} do
      assert %{"meta" => meta} = rendered["publish"]
      assert meta["notDelegable"] == true
    end

    # Omitted rather than false, matching multiStep: the profile documents both
    # as optional, and a client reads absence as "delegable".
    test "an ordinary action omits the key entirely", %{rendered: rendered} do
      assert %{"meta" => meta} = rendered["update"]
      refute Map.has_key?(meta, "notDelegable")
    end

    # R10: the flag is declared, not derived per actor. A different actor sees
    # the same flag on the same action — only the endpoint's behaviour varies.
    test "the flag does not vary by actor" do
      article =
        AshHateoas.Test.Article
        |> Ash.Changeset.for_create(:create, %{title: "R10 actors"})
        |> Ash.create!(authorize?: false)

      for role <- [:admin, :user] do
        envelope =
          AshHateoas.affordances(article, %AshHateoas.Test.Actor{id: "a", role: role},
            domain: AshHateoas.Test.Domain
          )

        if affordance = envelope[:publish] do
          assert affordance.not_delegable?,
                 "publish must be flagged for every actor that can see it, failed for #{role}"
        end
      end
    end
  end

  describe "commit authority" do
    alias AshHateoas.CommitAuthority

    test "defaults to Always, so the feature is inert unless configured" do
      assert CommitAuthority.module() == CommitAuthority.Always
      assert CommitAuthority.commits?(%{anything: true})
      assert CommitAuthority.commits?(nil)
    end

    test "ApiKey refuses an actor carrying the strategy's metadata" do
      key_holder = %{__metadata__: %{using_api_key?: true, api_key: %{id: "k"}}}

      refute CommitAuthority.ApiKey.commits?(key_holder)
    end

    test "ApiKey commits for anything without that metadata" do
      assert CommitAuthority.ApiKey.commits?(%{__metadata__: %{}})
      assert CommitAuthority.ApiKey.commits?(%{id: "a person"})
      assert CommitAuthority.ApiKey.commits?(nil)
    end

    # R10 inverts R7's posture deliberately. Gate.Authorization logs and drops
    # an affordance because affordances are advisory; this is enforcement, so a
    # raising authority must not let the write through.
    test "a raising authority answers false, loudly" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          with_authority(Raising, fn ->
            refute CommitAuthority.commits?(%{id: "x"})
          end)
        end)

      assert log =~ "raised"
      assert log =~ "non-committing"
    end

    test "a non-boolean answer is treated as non-committing, loudly" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          with_authority(Nonsense, fn ->
            refute CommitAuthority.commits?(%{id: "x"})
          end)
        end)

      assert log =~ "non-boolean"
    end

    defp with_authority(module, fun) do
      previous = Application.get_env(:ash_hateoas, :commit_authority)
      Application.put_env(:ash_hateoas, :commit_authority, Module.concat(__MODULE__, module))

      try do
        fun.()
      after
        if previous do
          Application.put_env(:ash_hateoas, :commit_authority, previous)
        else
          Application.delete_env(:ash_hateoas, :commit_authority)
        end
      end
    end
  end

  describe "projection" do
    alias AshHateoas.Projection
    alias AshHateoas.Test.Order

    @actor %AshHateoas.Test.Actor{id: "someone", role: :admin}

    setup do
      order =
        Order
        |> Ash.Changeset.for_create(:create, %{
          reference: "r10-#{System.unique_integer([:positive])}"
        })
        |> Ash.create!(authorize?: false)

      %{order: order, opts: [domain: AshHateoas.Test.Domain]}
    end

    test "target_states/3 reads the transition", %{order: order} do
      assert Projection.target_states(Order, order, :confirm) == [:confirmed]
    end

    test "target_states/3 is empty for an action that is not a transition", %{order: order} do
      assert Projection.target_states(Order, order, :read) == []
    end

    # R10: an action outside a state machine yields no projection, and the
    # profile must distinguish that from "nothing downstream".
    test "target_states/3 is empty for a resource with no state machine" do
      article =
        AshHateoas.Test.Article
        |> Ash.Changeset.for_create(:create, %{title: "no machine"})
        |> Ash.create!(authorize?: false)

      assert Projection.target_states(AshHateoas.Test.Article, article, :publish) == []
    end

    # A transition is only projectable from a state it can start in. `ship` runs
    # from :confirmed, so a :pending order projects nothing for it.
    test "target_states/3 respects the current state", %{order: order} do
      assert Projection.target_states(Order, order, :ship) == []
    end

    test "for_target_state/5 answers as if the record were there", %{order: order, opts: opts} do
      now = AshHateoas.affordances(order, @actor, opts)
      projected = Projection.for_target_state(Order, order, @actor, :confirmed, opts)

      assert Map.has_key?(now, :confirm), "a pending order can be confirmed"
      refute Map.has_key?(now, :ship), "a pending order cannot be shipped yet"
      assert Map.has_key?(projected, :ship), "a confirmed order can be shipped"
    end

    test "for_target_state/5 does not touch the record", %{order: order, opts: opts} do
      Projection.for_target_state(Order, order, @actor, :confirmed, opts)

      reloaded = Ash.get!(Order, order.id, authorize?: false)
      assert reloaded.state == :pending, "projecting must never write"
      assert order.state == :pending, "projecting must not mutate the struct in hand"
    end

    test "deltas/5 reports what confirming would gain and lose", %{order: order, opts: opts} do
      assert [%{to: :confirmed, gained: gained, lost: lost}] =
               Projection.deltas(Order, order, @actor, :confirm, opts)

      assert Map.has_key?(gained, :ship), "confirming makes shipping available"
      assert :confirm in lost, "confirming spends the confirm transition"
    end

    test "deltas/5 is empty when there is nothing to project", %{order: order, opts: opts} do
      assert Projection.deltas(Order, order, @actor, :read, opts) == []
    end
  end

  defmodule Raising do
    @behaviour AshHateoas.CommitAuthority

    @impl true
    def commits?(_actor), do: raise("policy blew up")
  end

  defmodule Nonsense do
    @behaviour AshHateoas.CommitAuthority

    @impl true
    def commits?(_actor), do: :maybe
  end

  defp compile_resource(name, agentic_body, actions_body) do
    Code.compile_string("""
    defmodule #{name} do
      use Ash.Resource,
        domain: nil,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshHateoas.Resource]

      hateoas do
        warn_on_missing_authorizers?(false)
      end

      agentic_hateoas do
        #{agentic_body}
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
end
