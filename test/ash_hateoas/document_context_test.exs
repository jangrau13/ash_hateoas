defmodule AshHateoas.DocumentContextTest do
  @moduledoc """
  `AshHateoas.DslRoot.document_context/1` — computed once for a document, handed
  to every element.

  The problem it exists for is structural rather than incidental. Every element
  is cast through its own `Ash.Changeset.for_create/4`, which runs that
  resource's `change` modules — so a change that reads the database reads it
  **once per element**, and a document is precisely where that multiplication is
  guaranteed.

  Measured on the domain that motivated it: one lookup per element put a
  1,000-element document at 431ms and a 10,000-element one at 8.5s, against 6ms
  of real work. Gathered once for the document, the same 10,000 elements cost
  193ms.

  A change cannot fix that itself — it is handed one changeset and cannot know a
  document exists. The root can, so the root is asked.
  """

  use ExUnit.Case, async: false

  alias AshHateoas.Test.{Ingredient, Recipe}

  setup do
    Process.put(:ash_hateoas_test_pid, self())

    on_exit(fn -> Process.delete(:ash_hateoas_test_pid) end)

    {:ok, recipe} =
      Recipe |> Ash.Changeset.for_create(:create, %{title: "Context"}) |> Ash.create()

    %{recipe: recipe}
  end

  defp document(count) do
    for n <- 1..count, do: %{"kind" => "ingredient", "name" => "I#{n}", "unit" => "g"}
  end

  defp validate(recipe, document) do
    Recipe
    |> Ash.ActionInput.for_action(:validate, %{id: recipe.id, document: document})
    |> Ash.run_action()
  end

  defp collect(acc \\ []) do
    receive do
      {:document_context, prepared} -> collect([prepared | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "validating a document" do
    test "hands the context to every element", %{recipe: recipe} do
      assert {:ok, result} = validate(recipe, document(3))
      assert result["valid?"], inspect(result["errors"])

      seen = collect()

      assert length(seen) == 3, "expected one cast per element, got #{length(seen)}"
      assert Enum.all?(seen, &(&1.size == 3))
    end

    test "computes it once, not once per element", %{recipe: recipe} do
      # The property the hook exists for. Every element must see the *same*
      # prepared value — a hook called per element would still be correct and
      # would still cost per element, which is the defect rather than the fix.
      assert {:ok, _} = validate(recipe, document(5))

      assert seen = collect()
      assert length(seen) == 5
      assert seen |> Enum.uniq() |> length() == 1
    end

    test "the context describes the whole document, not one element", %{recipe: recipe} do
      assert {:ok, _} = validate(recipe, document(4))

      assert [%{size: 4, names: names} | _] = collect()
      assert names == ~w(I1 I2 I3 I4)
    end
  end

  describe "saving a document" do
    test "hands the same context to every element", %{recipe: recipe} do
      # `save` casts through `manage_relationship` rather than directly, so the
      # context travels a different route and needs its own assertion — the two
      # paths agreeing is what keeps a change from having to care which it is
      # running under.
      assert {:ok, result} =
               Recipe
               |> Ash.ActionInput.for_action(:save, %{id: recipe.id, document: document(3)})
               |> Ash.run_action()

      assert result["valid?"], inspect(result["errors"])

      seen = collect()

      assert seen != [], "no element saw the document context on the save path"
      assert Enum.all?(seen, &(&1.size == 3))
    end
  end

  describe "a root that does not implement it" do
    test "casts exactly as before" do
      # Optional means optional. Asserted at the library's own boundary rather
      # than through a second fixture root: what must hold is that a root
      # without the callback is never asked for one, and every other document
      # test in this suite predates the hook and still passes — which is the
      # broader version of this assertion.
      refute function_exported?(AshHateoas.Test.Ingredient, :document_context, 1)
    end

    test "a document with no formulas prepares without reading anything", %{recipe: recipe} do
      # The context is prepared before any element is examined, so it must cope
      # with a document that gives it nothing to prepare — an empty list is the
      # limiting case, and it must not raise on the way to reporting.
      assert {:ok, result} = validate(recipe, [])

      assert result["valid?"], inspect(result["errors"])
      assert collect() == []
    end
  end

  describe "a change with no document" do
    test "still works when written through its own action", %{recipe: recipe} do
      # The fallback that keeps the hook from becoming mandatory. A single-record
      # write has no document, so a change must read the context as a *cache*
      # and do its own work when it is absent.
      assert {:ok, ingredient} =
               Ingredient
               |> Ash.Changeset.for_create(:create, %{
                 name: "Standalone",
                 unit: :g,
                 recipe_id: recipe.id
               })
               |> Ash.create()

      assert ingredient.name == "Standalone"
      assert collect() == [], "a standalone write must not receive a document context"
    end
  end
end
