defmodule AshHateoas.Gate.AuthorizationTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AshHateoas.Test.{Actor, Domain, EagerPrepare}

  @actor %Actor{id: "anyone", role: :admin}

  defp affordances_for_type(resource, actor) do
    AshHateoas.affordances(resource, actor, domain: Domain)
  end

  describe "an action whose preparation dereferences a required argument" do
    test "is still advertised — the empty-probe crash is recovered, not dropped" do
      # `:search` has `authorize_if always()`, so it MUST appear. Before the
      # recovery path it vanished: the probe ran the preparation with no
      # argument, `"query: " <> nil` raised, and the affordance was dropped.
      names = EagerPrepare |> affordances_for_type(@actor) |> Map.keys()

      assert :search in names,
             "an authorizable action must not vanish because its preparation crashed on the empty probe"
    end

    test "recovering does not log an error — the raise was expected, not a fault" do
      # The recovery answers before the loud R7 log fires. A logged error here
      # would mean the retry did not catch the preparation crash.
      log =
        capture_log(fn ->
          affordances_for_type(EagerPrepare, @actor)
        end)

      refute log =~ "Authorization check raised",
             "a recovered preparation crash must not be logged as a dropped affordance"
    end

    test "a genuinely forbidden action with the same crash stays hidden" do
      # `:forbidden_search` has the identical crashing preparation but
      # `forbid_if always()`. The recovery must authorize WITHOUT the argument,
      # not advertise everything that happens to crash the probe.
      names = EagerPrepare |> affordances_for_type(@actor) |> Map.keys()

      refute :forbidden_search in names,
             "recovery must not turn a real denial into an offered affordance"
    end
  end
end
