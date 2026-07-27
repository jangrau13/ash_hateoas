defmodule AshHateoas.PostureTest do
  use ExUnit.Case, async: true

  alias AshHateoas.Posture
  alias AshHateoas.Test.{Actor, Article, Document, Domain, LoudResource}
  alias AshHateoas.Test.{Quiet, SilentDomain, SilentResource}

  @actor %Actor{id: "someone", role: :admin}

  describe "precedence: resource > domain > on (R8)" do
    test "a resource that says nothing is on" do
      assert Posture.enabled?(Article, Domain)
    end

    test "a resource without the extension at all is on" do
      assert Posture.enabled?(Document, Domain),
             "affordances are a contract — the default must be on, not off"
    end

    test "a resource may switch itself off" do
      refute Posture.enabled?(Quiet, Domain)
    end

    test "a resource inherits its domain's default" do
      refute Posture.enabled?(SilentResource, SilentDomain),
             "SilentResource declares nothing; its domain declares enabled? false"
    end

    test "a resource's own declaration beats the domain default" do
      assert Posture.enabled?(LoudResource, SilentDomain),
             "one resource must be able to stay navigable in a switched-off domain"
    end

    test "no domain given falls back to on" do
      assert Posture.enabled?(Article, nil)
    end
  end

  describe "the distinction the nil default protects" do
    # Spark materialises schema defaults into DSL state, so `default: true`
    # would make a silent resource indistinguishable from one that declared
    # true — and inheritance from the domain would silently never work.
    test "an undeclared enabled? reads as nil, not true" do
      assert Spark.Dsl.Extension.get_opt(Article, [:hateoas], :enabled?, nil, false) == nil,
             "if this is `true`, the default leaked back in and inheritance is broken"
    end

    test "a declared enabled? reads as its literal value" do
      assert Spark.Dsl.Extension.get_opt(Quiet, [:hateoas], :enabled?, nil, false) == false
      assert Spark.Dsl.Extension.get_opt(LoudResource, [:hateoas], :enabled?, nil, false) == true
    end
  end

  describe "effect on affordances" do
    test "a switched-off resource produces no affordances" do
      quiet =
        Quiet
        |> Ash.Changeset.for_create(:create, %{label: "x"})
        |> Ash.create!(authorize?: false)

      assert AshHateoas.affordances(quiet, @actor, domain: Domain) == %{},
             "enabled? false must suppress the set entirely"
    end

    test "a switched-off resource is still routed and readable" do
      routes = AshHateoas.Resource.Info.routes(Quiet)

      assert Enum.any?(routes, &(&1.type == :get)),
             "turning affordances off must not turn the endpoint off"
    end

    test "collection-level affordances are suppressed too" do
      assert AshHateoas.affordances(Quiet, @actor, domain: Domain) == %{}
    end

    test "a resource inheriting a switched-off domain produces nothing" do
      silent =
        SilentResource
        |> Ash.Changeset.for_create(:create, %{label: "x"})
        |> Ash.create!(authorize?: false)

      assert AshHateoas.affordances(silent, @actor, domain: SilentDomain) == %{}
    end

    test "a resource overriding a switched-off domain still produces affordances" do
      loud =
        LoudResource
        |> Ash.Changeset.for_create(:create, %{label: "x"})
        |> Ash.create!(authorize?: false)

      assert map_size(AshHateoas.affordances(loud, @actor, domain: SilentDomain)) > 0
    end
  end
end
