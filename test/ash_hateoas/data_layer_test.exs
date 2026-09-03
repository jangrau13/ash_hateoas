defmodule AshHateoas.DataLayerTest do
  @moduledoc """
  The little this library knows about somebody else's data layer.

  Two names and one question: where does this resource keep its table and repo,
  and will its data layer open a transaction if nobody asks. The second is the
  one that matters — `AshSqlite.DataLayer` answers no and Ash acts on that
  silently, so a boundary this library needs has to be opened here or not at
  all.

  Neither SQL data layer is a dependency, so neither can be exercised from this
  package. What is testable is the recognition itself, and the promise that a
  resource with no repo behaves exactly as it did before the boundary existed —
  which is what every other test in this suite is standing on.
  """

  use ExUnit.Case, async: true

  alias AshHateoas.DataLayer
  alias AshHateoas.Test.Scripted.Author

  describe "recognising a data layer" do
    test "the two SQL data layers are known by name" do
      # By name and not by dependency: a consumer brings whichever it uses, and
      # this package builds without either.
      assert DataLayer.section(AshPostgres.DataLayer) == :postgres
      assert DataLayer.section(AshSqlite.DataLayer) == :sqlite
    end

    test "anything else keeps no table or repo, and that is not an error" do
      # The ordinary case rather than the exceptional one. ETS is a real data
      # layer with nowhere to put a `table`, and a `postgres` block on it does
      # not compile.
      assert DataLayer.section(Ash.DataLayer.Ets) == nil
      assert DataLayer.section(nil) == nil
    end
  end

  describe "the transaction boundary" do
    test "a resource with no repo has none to find" do
      assert DataLayer.repo(Author) == nil
    end

    test "a resource with no repo runs the function as it always did" do
      # **Adding no boundary is the correct answer here**, not a fallback. A
      # data layer with no transactions has none to lose, and refusing to run
      # would break every consumer that never had one — this suite included.
      assert DataLayer.transaction(Author, fn -> {:ok, :ran} end) == {:ok, :ran}
    end

    test "an error is returned unchanged, so a caller writes the same clauses" do
      # The point of the wrapper is that atomicity is the only difference. A
      # caller that could tell from the return value whether a boundary was
      # opened would have to branch on the data layer, which is the coupling
      # this exists to avoid.
      assert DataLayer.transaction(Author, fn -> {:error, :nope} end) == {:error, :nope}
    end
  end
end
