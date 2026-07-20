defmodule AshHateoas.Gate.StateMachineTest do
  use ExUnit.Case, async: true

  alias AshHateoas.Gate.StateMachine
  alias AshHateoas.Test.{Actor, Document, Domain, Order}

  # Order's policies are `authorize_if always()`, so anything withheld here was
  # withheld by the STATE gate, not by authorization.
  @actor %Actor{id: "anyone", role: :admin}

  setup do
    order =
      Order
      |> Ash.Changeset.for_create(:create, %{reference: unique("ref")})
      |> Ash.create!(authorize?: false)

    %{order: order}
  end

  describe "transitions legal from the current state" do
    test "pending offers :confirm", %{order: order} do
      assert :pending == order.state
      assert Map.has_key?(affordances(order), :confirm)
    end

    test "pending withholds :ship and :deliver", %{order: order} do
      affordances = affordances(order)

      refute Map.has_key?(affordances, :ship),
             ":ship starts from :confirmed — advertising it from :pending is a broken promise"

      refute Map.has_key?(affordances, :deliver)
    end

    test "confirming makes :ship legal and :confirm illegal", %{order: order} do
      confirmed = transition!(order, :confirm)

      assert Map.has_key?(affordances(confirmed), :ship)
      refute Map.has_key?(affordances(confirmed), :confirm)
    end

    test "shipping makes :deliver legal and :ship illegal", %{order: order} do
      shipped = order |> transition!(:confirm) |> transition!(:ship)

      assert Map.has_key?(affordances(shipped), :deliver)
      refute Map.has_key?(affordances(shipped), :ship)
    end

    test "the affordance set changes as the record moves through states", %{order: order} do
      pending = affordances(order) |> Map.keys() |> MapSet.new()
      confirmed = order |> transition!(:confirm) |> affordances() |> Map.keys() |> MapSet.new()

      refute MapSet.equal?(pending, confirmed),
             "this is the whole point: the same actor sees a different set as state moves"
    end
  end

  describe "wildcard transitions" do
    test ":cancel is offered from every state", %{order: order} do
      confirmed = transition!(order, :confirm)
      shipped = transition!(confirmed, :ship)

      for record <- [order, confirmed, shipped] do
        assert Map.has_key?(affordances(record), :cancel),
               "cancel declares from: :*, so it is legal from #{record.state}"
      end
    end
  end

  describe "actions the state machine does not govern" do
    test ":read is unaffected by state", %{order: order} do
      shipped = order |> transition!(:confirm) |> transition!(:ship)

      assert Map.has_key?(affordances(order), :read)
      assert Map.has_key?(affordances(shipped), :read)
    end
  end

  describe "resources without a state machine" do
    test "pass through untouched" do
      doc =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "T", owner_id: "o"})
        |> Ash.create!(authorize?: false)

      affordances = AshHateoas.affordances(doc, @actor, domain: Domain)

      assert map_size(affordances) > 0,
             "the gate must be a no-op for resources with no state machine"
    end
  end

  describe "collection-level affordances (R9)" do
    test "no state gate applies without a record" do
      affordances = AshHateoas.affordances(Order, @actor, domain: Domain)

      assert Map.has_key?(affordances, :create),
             "there is no record to have a state, so only authorization applies"
    end
  end

  describe "gate availability" do
    test "reports ash_state_machine as available in this build" do
      assert StateMachine.available?()
    end

    test "the default chain includes the state gate when available" do
      assert StateMachine in AshHateoas.Backbone.default_gates()
    end

    test "the state gate runs before authorization" do
      gates = AshHateoas.Backbone.default_gates()

      assert Enum.find_index(gates, &(&1 == StateMachine)) <
               Enum.find_index(gates, &(&1 == AshHateoas.Gate.Authorization)),
             "the free in-memory check must run before the one that can query"
    end
  end

  defp affordances(record) do
    AshHateoas.affordances(record, @actor, domain: Domain)
  end

  defp transition!(record, action) do
    record
    |> Ash.Changeset.for_update(action, %{})
    |> Ash.update!(authorize?: false)
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
