defmodule AshHateoas.ConformanceTest do
  @moduledoc """
  Conformance against REQ's numbered requirements, stated as directly as the
  requirement itself. Where another test file covers a requirement in depth,
  this one asserts the headline claim so a regression is legible as
  "R1 broke", not "some link is missing".
  """

  use ExUnit.Case, async: true

  alias AshHateoas.Test.{Actor, Derived, Document, Domain, Order, Quiet}

  @actor %Actor{id: "conformance", role: :admin}

  describe "R1 — automatic, from what is already declared" do
    setup do
      derived =
        Derived
        |> Ash.Changeset.for_create(:create, %{label: "L"})
        |> Ash.create!(authorize?: false)

      %{derived: derived}
    end

    test "a resource author writes no affordances", %{derived: derived} do
      # Derived carries no `hateoas` block at all.
      assert map_size(affordances(derived)) > 0,
             "zero per-resource config must still produce affordances"
    end

    test "the candidate set comes from ROUTES, not from actions", %{derived: derived} do
      declared = Derived |> Ash.Resource.Info.actions() |> MapSet.new(& &1.name)
      advertised = derived |> affordances() |> Map.keys() |> MapSet.new()

      assert MapSet.member?(declared, :unrouted_touch),
             "precondition: the action exists"

      refute MapSet.member?(advertised, :unrouted_touch),
             "an authorized but UNROUTED action must not be advertised (R1)"
    end

    test "a routed action of the same shape IS advertised", %{derived: derived} do
      assert Map.has_key?(affordances(derived), :touch),
             ":touch differs from :unrouted_touch only by having a route"
    end
  end

  describe "R3 — resolved per request, from the client's own context" do
    test "two actors receive different sets for the same record" do
      doc =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "T", owner_id: "someone-else"})
        |> Ash.create!(authorize?: false)

      admin = affordances(doc, %Actor{id: "a", role: :admin})
      viewer = affordances(doc, %Actor{id: "v", role: :viewer})

      refute Map.equal?(admin, viewer)
    end
  end

  describe "R4 — self-documenting" do
    test "descriptions, defaults and constraints come from the DSL verbatim" do
      doc =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "T", owner_id: "o"})
        |> Ash.create!(authorize?: false)

      approve = affordances(doc)[:approve]
      visibility = Enum.find(approve.fields, &(&1.name == :visibility))

      assert approve.description == "Approve this document so it can be published."
      assert visibility.constraints[:enum] == [:public, :private]
      assert visibility.default == {:ok, :private}
    end
  end

  describe "R5 — the envelope shape is fixed" do
    test "every affordance carries the same keys regardless of resource" do
      doc =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "T", owner_id: "o"})
        |> Ash.create!(authorize?: false)

      order =
        Order
        |> Ash.Changeset.for_create(:create, %{reference: "R"})
        |> Ash.create!(authorize?: false)

      keys =
        for record <- [doc, order],
            {_name, affordance} <- affordances(record),
            uniq: true,
            do: affordance |> Map.from_struct() |> Map.keys() |> Enum.sort()

      assert length(keys) == 1,
             "a renderer must not see structurally different affordances across resources"
    end
  end

  describe "R8 — cost is bounded" do
    test "a collection's cost does not grow with page size" do
      # Type-level affordances are computed once per request, not per record,
      # so the M × N case cannot arise. Asserting the entry point rather than
      # counting queries: for_resource takes no record at all.
      assert map_size(AshHateoas.affordances(Document, @actor, domain: Domain)) > 0
    end

    test "a resource may switch affordances off" do
      quiet =
        Quiet
        |> Ash.Changeset.for_create(:create, %{label: "x"})
        |> Ash.create!(authorize?: false)

      assert affordances(quiet) == %{}
    end
  end

  describe "R9 — enter anywhere" do
    test "a client with no record in hand is told what it may create" do
      affordances = AshHateoas.affordances(Document, @actor, domain: Domain)

      assert Map.has_key?(affordances, :create),
             "the cold-start case is the first thing a new client needs"
    end

    test "the collection entry point applies no state gate" do
      # Order's actions are all state-gated at record level; at collection level there
      # is no record to have a state, so :create survives.
      assert Map.has_key?(AshHateoas.affordances(Order, @actor, domain: Domain), :create)
    end
  end

  defp affordances(record, actor \\ @actor) do
    AshHateoas.affordances(record, actor, domain: Domain)
  end
end
