defmodule AshHateoas.RootActionsTest do
  @moduledoc """
  `aggregate_root? true` generates `:validate` and `:save`, and they behave.

  The invariant under test throughout is that **validation never writes**. It is
  what makes the action safe to call on every editor keystroke and callable by
  an actor holding no write permission, so it is asserted directly — row counts
  before and after — rather than inferred from the action's type.
  """

  use ExUnit.Case, async: false

  alias AshHateoas.Test.{Ingredient, Recipe, Step}

  setup do
    for resource <- [Ingredient, Step, Recipe] do
      resource |> Ash.read!(authorize?: false) |> Enum.each(&Ash.destroy!(&1, authorize?: false))
    end

    :ok
  end

  defp validate(document, arguments \\ %{}) do
    {:ok, result} =
      Recipe
      |> Ash.ActionInput.for_action(:validate, Map.merge(%{document: document}, arguments))
      |> Ash.run_action()

    result
  end

  defp save(document, arguments) do
    Recipe
    |> Ash.ActionInput.for_action(:save, Map.merge(%{document: document}, arguments))
    |> Ash.run_action()
  end

  defp recipe! do
    Recipe |> Ash.Changeset.for_create(:create, %{title: "Bread"}) |> Ash.create!()
  end

  defp fields(result), do: Enum.map(result["errors"], & &1["field"])

  describe "generation" do
    test "the two actions exist without being written by hand" do
      names = Recipe |> Ash.Resource.Info.actions() |> Enum.map(& &1.name)

      assert :validate in names
      assert :save in names
    end

    test "both are generic actions, so validation cannot write by construction" do
      # The invariant is carried by the action type: a generic action returns a
      # value and has no changeset, so no amount of body drift can make
      # `:validate` write.
      assert Ash.Resource.Info.action(Recipe, :validate).type == :action
      assert Ash.Resource.Info.action(Recipe, :save).type == :action
    end

    test "the document argument is required and carries the whole aggregate" do
      argument =
        Recipe
        |> Ash.Resource.Info.action(:validate)
        |> Map.get(:arguments)
        |> Enum.find(&(&1.name == :document))

      assert argument.type == {:array, Ash.Type.Map}
      refute argument.allow_nil?
    end

    test "both are routed without a route being declared" do
      routes =
        Recipe
        |> AshHateoas.Resource.Info.routes()
        |> Enum.map(&{&1.action, &1.route})

      # This is why the transformer runs *before* DeriveActionRoutes: the
      # actions must exist by the time routes are derived, or they never reach
      # the wire.
      assert {:validate, "/recipes/:id/validate"} in routes
      assert {:save, "/recipes/:id/save"} in routes
    end

    test "a resource that is not an aggregate root gets neither action" do
      names = Ingredient |> Ash.Resource.Info.actions() |> Enum.map(& &1.name)

      refute :validate in names
      refute :save in names
    end
  end

  describe "validate" do
    test "a valid document reports no errors" do
      result =
        validate([
          %{"kind" => "ingredient", "name" => "Sugar", "unit" => "g", "quantity" => 10},
          %{"kind" => "step", "name" => "Mix", "body" => "combine", "uses" => "Sugar"}
        ])

      assert result["valid?"]
      assert result["errors"] == []
    end

    test "a valid document writes nothing" do
      document = [%{"kind" => "ingredient", "name" => "Sugar", "unit" => "g"}]

      before = Ash.count!(Ingredient, authorize?: false)
      assert validate(document)["valid?"]

      # The central invariant. If this ever fails, an editor checking on save
      # has been silently writing to the domain.
      assert Ash.count!(Ingredient, authorize?: false) == before
    end

    test "an invalid document writes nothing either" do
      document = [%{"kind" => "ingredient", "name" => nil}]

      before = Ash.count!(Ingredient, authorize?: false)
      refute validate(document)["valid?"]

      assert Ash.count!(Ingredient, authorize?: false) == before
    end

    test "every error is reported in one pass, not just the first" do
      # The property the whole design exists for. Casting the list into an
      # embedded array would stop at the first bad element, giving an author one
      # error per round-trip; casting each element individually accumulates.
      result =
        validate([
          %{"kind" => "ingredient", "name" => nil},
          %{"kind" => "ingredient", "name" => "Salt", "unit" => "banana"}
        ])

      refute result["valid?"]
      assert length(result["errors"]) == 2
      assert Enum.map(result["errors"], & &1["index"]) == [0, 1]
    end

    test "every bad field within one element is reported" do
      result = validate([%{"kind" => "ingredient", "name" => nil, "unit" => "banana"}])

      assert Enum.sort(fields(result)) == ["name", "unit"]
    end

    test "an error carries the element's index, so it maps back to a source range" do
      result =
        validate([
          %{"kind" => "ingredient", "name" => "Sugar", "unit" => "g"},
          %{"kind" => "ingredient", "name" => "Salt", "unit" => "banana"}
        ])

      assert [error] = result["errors"]
      # Position in the submitted document is the only handle a client has for
      # putting the error on the right line.
      assert error["index"] == 1
      assert error["name"] == "Salt"
      assert error["field"] == "unit"
    end

    test "the domain's own constraints are enforced without being restated" do
      # `unit` is `one_of [:g, :ml, :piece]` on the resource. Nothing in
      # RootActions knows that; the element's own changeset does.
      assert validate([%{"kind" => "ingredient", "name" => "S", "unit" => "g"}])["valid?"]
      refute validate([%{"kind" => "ingredient", "name" => "S", "unit" => "furlong"}])["valid?"]
    end

    test "an unknown element kind is reported against the kind key" do
      result = validate([%{"kind" => "sorcery", "name" => "Nope"}])

      assert [error] = result["errors"]
      assert error["field"] == "kind"
      assert error["message"] =~ "unknown element kind"
    end

    test "a document that is not a list is rejected by the argument's own type" do
      # `{:array, :map}` is enforced by Ash before the body runs, so a
      # malformed document never reaches RootActions at all. The error names
      # the argument, which is what a client needs to report it.
      assert {:error, %Ash.Error.Invalid{errors: [error | _]}} =
               Recipe
               |> Ash.ActionInput.for_action(:validate, %{document: %{"kind" => "ingredient"}})
               |> Ash.run_action()

      assert error.field == :document
    end
  end

  describe "cross-element rules" do
    # These are the reason one call carries the whole document. Neither is a
    # property of any single changeset, so neither can be found per element.

    test "a duplicate name is caught" do
      result =
        validate([
          %{"kind" => "ingredient", "name" => "Flour", "unit" => "g"},
          %{"kind" => "ingredient", "name" => "Flour", "unit" => "ml"}
        ])

      refute result["valid?"]
      assert Enum.any?(result["errors"], &(&1["message"] =~ "duplicate element name"))
    end

    test "a reference to an element that does not exist is caught" do
      result =
        validate([
          %{"kind" => "ingredient", "name" => "Sugar", "unit" => "g"},
          %{"kind" => "step", "name" => "Mix", "uses" => "Saffron"}
        ])

      refute result["valid?"]
      assert [error] = Enum.filter(result["errors"], &(&1["field"] == "uses"))
      assert error["message"] =~ ~s(no element named "Saffron")
      assert error["index"] == 1
    end

    test "a reference that resolves within the document is accepted" do
      # `Sugar` exists nowhere in the database — only in this document. That is
      # the point: on a new document nothing exists yet, so references must
      # resolve against the document's own contents.
      result =
        validate([
          %{"kind" => "ingredient", "name" => "Sugar", "unit" => "g"},
          %{"kind" => "step", "name" => "Mix", "uses" => "Sugar"}
        ])

      assert result["valid?"]
    end

    test "a reference key is derived, not drawn from a fixed list of names" do
      # `uses` is this fixture's vocabulary and appears nowhere in RootActions.
      # A key the class does not accept, holding a string, naming nothing — that
      # is what makes it a reference, structurally.
      refute "uses" in (Step |> Ash.Resource.Info.attributes() |> Enum.map(&to_string(&1.name)))

      result = validate([%{"kind" => "step", "name" => "Mix", "uses" => "Ghost"}])
      assert Enum.any?(result["errors"], &(&1["field"] == "uses"))
    end
  end

  describe "errors the author cannot act on are not reported" do
    test "the owning foreign key is never surfaced" do
      # Every part declares `belongs_to :recipe, allow_nil?: false`, so casting
      # one standalone fails that check. The author did not write it and cannot
      # fix it — `save` supplies it — so reporting it would put an unfixable
      # error on every element in the document.
      result = validate([%{"kind" => "ingredient", "name" => "Sugar", "unit" => "g"}])

      assert result["valid?"]
      refute "recipe_id" in fields(result)
    end

    test "a structural key produces no error with an empty field name" do
      # Passing `uses` to `for_create/4` yields an error whose field is nil —
      # an error the editor has nowhere to put. Structural keys are stripped
      # before casting, so this stays clean.
      result =
        validate([
          %{"kind" => "ingredient", "name" => "Sugar", "unit" => "g"},
          %{"kind" => "step", "name" => "Mix", "uses" => "Sugar"}
        ])

      assert result["valid?"]
      refute Enum.any?(result["errors"], &is_nil(&1["field"]))
    end
  end

  describe "save" do
    test "a valid document is persisted" do
      recipe = recipe!()

      {:ok, result} =
        save(
          [
            %{"kind" => "ingredient", "name" => "Sugar", "unit" => "g", "quantity" => 10},
            %{"kind" => "step", "name" => "Mix", "body" => "combine", "uses" => "Sugar"}
          ],
          %{id: recipe.id}
        )

      assert result["valid?"]
      assert result["created"] == 2
      assert Ash.count!(Ingredient, authorize?: false) == 1
      assert Ash.count!(Step, authorize?: false) == 1
    end

    test "an invalid document writes nothing" do
      recipe = recipe!()

      {:ok, result} =
        save([%{"kind" => "ingredient", "name" => "Salt", "unit" => "banana"}], %{id: recipe.id})

      refute result["valid?"]
      assert Ash.count!(Ingredient, authorize?: false) == 0
    end

    test "saved elements are attached to the aggregate" do
      recipe = recipe!()

      {:ok, _} =
        save([%{"kind" => "ingredient", "name" => "Sugar", "unit" => "g"}], %{id: recipe.id})

      assert [ingredient] = Ash.read!(Ingredient, authorize?: false)
      # The owning key is supplied by save, which is why validate must not
      # report it missing.
      assert ingredient.recipe_id == recipe.id
    end

    test "save runs the same validation validate does" do
      recipe = recipe!()
      document = [%{"kind" => "ingredient", "name" => "Salt", "unit" => "banana"}]

      {:ok, saved} = save(document, %{id: recipe.id})

      assert fields(validate(document)) == fields(saved)
    end
  end

  describe "deliberate override" do
    test "a hand-written action of the same name is used as-is" do
      # `add_new_action/4` is a no-op when the action already exists, so the
      # declaration and the override coexist rather than the author having to
      # choose between generated and hand-written for the pair.
      assert Ash.Resource.Info.action(AshHateoas.Test.HandValidated, :validate).description ==
               "Hand-written, and not replaced."
    end

    test "the action not overridden is still generated" do
      assert Ash.Resource.Info.action(AshHateoas.Test.HandValidated, :save)
    end
  end
end
