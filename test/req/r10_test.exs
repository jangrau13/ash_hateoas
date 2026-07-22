defmodule AshHateoas.Req.R10Test do
  @moduledoc """
  R10 — some actions may be advertised but not exercised by a delegated
  credential.
  """

  use ExUnit.Case, async: true

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

      %{rendered: AshHateoas.JsonApi.Renderer.render(envelope, path_params: %{"id" => article.id})}
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
