defmodule AshHateoas.RootActionsTest do
  @moduledoc """
  Carrying `AshHateoas.DslRoot` generates `:validate` and `:save`, and they behave.

  The invariant under test throughout is that **validation never writes**. It is
  what makes the action safe to call on every editor keystroke and callable by
  an actor holding no write permission, so it is asserted directly — row counts
  before and after — rather than inferred from the action's type.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias AshHateoas.Test.{Ingredient, Recipe, Step, Technique}

  setup do
    for resource <- [
          AshHateoas.Test.RecipeTechnique,
          AshHateoas.Test.Technique,
          Ingredient,
          Step,
          Recipe
        ] do
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

    test "the extension is optional" do
      # `AshHateoas.Resource` describes and routes; it has no opinion about
      # documents. A resource carrying only it never sees this DSL, and asking
      # whether it is a root answers false rather than raising — so a caller
      # never has to check for the extension first.
      refute AshHateoas.DslRoot in Spark.extensions(Ingredient)
      refute AshHateoas.DslRoot.Info.root?(Ingredient)

      # And a resource with neither extension at all.
      refute AshHateoas.DslRoot.Info.root?(AshHateoas.Test.Unrouted)
    end

    test "an aggregate root carries both extensions" do
      extensions = Spark.extensions(Recipe)

      assert AshHateoas.Resource in extensions
      assert AshHateoas.DslRoot in extensions
      assert AshHateoas.DslRoot.Info.root?(Recipe)
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

    test "a document may carry the root it belongs to" do
      # A document *is* the root, so the root is not among the kinds it may
      # hold as an element — and it is still the only place the root's own
      # attributes can travel. Refusing it drew `unknown element kind` plus one
      # error per field, on every document a client sent.
      assert validate([%{"kind" => "recipe", "title" => "Bread"}])["valid?"]
    end

    test "the root's own attributes are not read as references to elements" do
      # The subtle half, and the one a reader is most likely to drop.
      # `accepted_keys/2` answers `[]` for a kind it cannot place, and every
      # remaining string is then taken as naming another element — so accepting
      # the root without teaching this function about it reports the root's own
      # `title` as `no element named "Bread"`.
      result = validate([%{"kind" => "recipe", "title" => "Bread"}])

      assert result["valid?"], inspect(result["errors"])
      refute Enum.any?(result["errors"], &(&1["message"] =~ "no element named"))
    end

    test "a root attribute the resource does not have is still reported" do
      # Accepting the root must not make it a place to write anything.
      result = validate([%{"kind" => "recipe", "titel" => "Bread"}])

      refute result["valid?"]
      assert Enum.any?(result["errors"], &(&1["field"] == "titel"))
    end

    test "a document naming its root twice is an error" do
      # Two sets of attributes for one record, with no principled winner —
      # taking the last silently discards the other.
      result =
        validate([
          %{"kind" => "recipe", "title" => "Bread"},
          %{"kind" => "recipe", "title" => "Cake"}
        ])

      refute result["valid?"]
      assert Enum.any?(result["errors"], &(&1["message"] =~ "names its root once"))
    end

    test "a type of two words is named by its type, not by its class" do
      # **The round trip no fixture exercised until `MixingBowl` existed.**
      #
      # A class IRI is the type camelized, and camelizing is lossy: `step`
      # round-trips because it is one lower-case word, while `mixing_bowl`
      # becomes `MixingBowl` and lowercases back to `mixingbowl`. A client
      # deriving the kind from the class therefore sends a token this server
      # has never heard of — measured on a live API, every element of a
      # 214-element save rejected.
      #
      # So the accepted spelling is the *declared type*, and the derived one
      # must stay refused: accepting both would make them interchangeable and
      # leave a client no way to discover which is meant.
      assert validate([%{"kind" => "mixing_bowl", "name" => "Big"}])["valid?"]

      result = validate([%{"kind" => "mixingbowl", "name" => "Big"}])

      refute result["valid?"]
      assert [error] = result["errors"]
      assert error["message"] =~ "unknown element kind"
    end

    test "an element of a two-word type is persisted by a save" do
      # Validation and persistence read the same index, so this could only
      # diverge if one of them stopped doing so — which is exactly what a
      # future "normalise the kind" change would do to one and not the other.
      recipe = recipe!()

      assert {:ok, _result} =
               save([%{"kind" => "mixing_bowl", "name" => "Big", "litres" => 12}], %{
                 id: recipe.id
               })

      assert [%{name: "Big", litres: 12}] = Ash.read!(AshHateoas.Test.MixingBowl)
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

    test "an element's own id is not read as naming another element" do
      # A rendered element carries its `id` — that is how it was read back. It
      # is an attribute the class *has* and does not *accept*, so judging
      # references by the accept list alone reports it as a dangling reference
      # on every element in the document, which the author cannot act on.
      #
      # "Writable" and "is a reference" are separate questions. The unwritable
      # half is already handled by dropping the key before casting.
      recipe = recipe!()

      result =
        validate([
          %{
            "kind" => "ingredient",
            "id" => Ash.UUID.generate(),
            "name" => "Sugar",
            "unit" => "g"
          },
          %{"kind" => "recipe", "id" => recipe.id, "title" => "Sourdough"}
        ])

      assert result["valid?"], inspect(result["errors"])
      refute "id" in fields(result)
    end

    test "a create-only field is carried, and the domain still governs it" do
      # `manage_opts/2` sets `on_no_match: :create, on_match: :update`, so which
      # action an element meets is decided at runtime by whether it already
      # exists. `Ingredient.origin` is accepted on create and not on update —
      # set when the ingredient is added, immutable after.
      #
      # So the keys an element may *carry* are the union of both actions. That
      # is safe because `manage_relationship` builds each changeset for the
      # action it actually took and drops what that action does not accept:
      # measured, a second save carrying `origin: "Brazil"` leaves the stored
      # value at "Peru" rather than failing. Passing the same key to a bare
      # `for_update/4` raises `NoSuchInput` — which is why the *root*, cast
      # directly rather than managed, is filtered to `update` alone.
      recipe = recipe!()

      assert {:ok, created} =
               save(
                 [
                   %{"kind" => "ingredient", "name" => "Sugar", "unit" => "g", "origin" => "Peru"}
                 ],
                 %{id: recipe.id}
               )

      assert created["valid?"], inspect(created["errors"])

      assert {:ok, updated} =
               save(
                 [
                   %{
                     "kind" => "ingredient",
                     "name" => "Sugar",
                     "unit" => "g",
                     "origin" => "Brazil"
                   }
                 ],
                 %{id: recipe.id, complete: true}
               )

      assert updated["valid?"], inspect(updated["errors"])

      ingredient =
        Ingredient
        |> Ash.Query.filter(name == "Sugar")
        |> Ash.read_one!(authorize?: false)

      assert ingredient.origin == "Peru", "an update must not write a create-only field"
    end

    test "an element links to another by the identity the wire advertises" do
      # **The key a client is told to send is the key a document may send.**
      # `AshHateoas.Descriptor` publishes a `belongs_to`'s foreign key as the
      # *relationship*: `follows_id` reaches the wire as `follows`, typed
      # `sh:nodeKind: sh:IRI`, and `Step` publishes `ah:identity` naming the
      # field that keys it. So a client sends `{"follows": {"name": "Mix"}}`.
      #
      # `AshHateoas.Hydra.LinkInput` reverses that for a write to a resource's
      # own URL and `Hydra.Plug` calls it — nothing reversed it here, so a
      # document carrying the advertised key had it filtered out as unaccepted
      # and the save reported success with the element unconnected.
      #
      # Measured on a live service: a flow added through the DSL, gating on a
      # state, drained no stock and moved none of 214 series.
      # Two saves, because the target is resolved against the database: a
      # sibling created in the *same* document does not exist yet when the
      # element citing it is cast. That is a real limit and it is stated here
      # rather than worked around — a document may link to what is already
      # there, and adding both at once takes two saves.
      recipe = recipe!()

      assert {:ok, first} =
               save([%{"kind" => "step", "name" => "Mix", "body" => "Combine"}], %{
                 id: recipe.id,
                 complete: true
               })

      assert first["valid?"], inspect(first["errors"])

      assert {:ok, result} =
               save(
                 [
                   %{"kind" => "step", "name" => "Mix", "body" => "Combine"},
                   %{"kind" => "step", "name" => "Bake", "follows" => %{"name" => "Mix"}}
                 ],
                 %{id: recipe.id, complete: true}
               )

      assert result["valid?"], inspect(result["errors"])

      steps =
        Step
        |> Ash.read!(authorize?: false)
        |> Map.new(&{&1.name, &1})

      assert steps["Bake"].follows_id == steps["Mix"].id,
             "the link the wire advertises did not reach the record"
    end

    test "a key no action accepts is still reported" do
      # The tightened list must not become a blanket exemption: a key that is
      # neither accepted nor an attribute is still read as naming an element,
      # which is what makes a typo in a reference findable.
      result =
        validate([%{"kind" => "step", "name" => "Mix", "uses" => "Nonexistent"}])

      refute result["valid?"]
      assert Enum.any?(result["errors"], &(&1["message"] =~ "no element named"))
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
      # "synced", not "created": a save reconciles the aggregate against the
      # document rather than appending to it.
      assert result["synced"] == 2
      assert Ash.count!(Ingredient, authorize?: false) == 1
      assert Ash.count!(Step, authorize?: false) == 1
    end

    test "a document carrying its root applies the root's own attributes" do
      # **The assertion that could have caught the defect.** `persist/2` passed
      # an empty attribute map, so a root's own fields were discarded by every
      # save that ever ran — silently, with `valid?: true`.
      #
      # A document is the only way they can travel: there is no separate update
      # affordance, so a client rendering `title` into a buffer and an author
      # editing it had nowhere to send the result.
      recipe = recipe!()

      assert {:ok, result} =
               save(
                 [
                   %{"kind" => "recipe", "title" => "Sourdough"},
                   %{"kind" => "ingredient", "name" => "Flour", "unit" => "g"}
                 ],
                 %{id: recipe.id}
               )

      assert result["valid?"]
      assert Ash.get!(Recipe, recipe.id, authorize?: false).title == "Sourdough"

      # The root is the document, not an element of it, so it is not counted.
      # Inflating this would change the number every existing client reads.
      assert result["synced"] == 1
    end

    test "a root element carrying unwritable fields still saves" do
      # **What a real client sends, as opposed to what a test hand-writes.**
      # A rendered element carries its `id` — that is how it was read back — so
      # the root does too. `id` is `writable?: false`, and
      # `Ash.Changeset.for_update/4` raises `NoSuchInput` on the first key its
      # action does not accept, failing the entire save with a 400.
      #
      # Measured against a live service: a 215-element document that validated
      # clean could not be saved at all. Every test here passed throughout,
      # because each composed the root by hand and none included the `id` a
      # client cannot avoid sending.
      recipe = recipe!()

      assert {:ok, result} =
               save(
                 [
                   %{"kind" => "recipe", "id" => recipe.id, "title" => "Sourdough"},
                   %{"kind" => "ingredient", "name" => "Flour", "unit" => "g"}
                 ],
                 %{id: recipe.id}
               )

      assert result["valid?"]

      # The writable field still lands; `id` is dropped rather than rejected,
      # since a client has no way to send the root without it.
      assert Ash.get!(Recipe, recipe.id, authorize?: false).title == "Sourdough"
    end

    test "a document that carries no root leaves the root alone" do
      # Every document written before the root was accepted, and every one a
      # client composes by hand. It must behave exactly as it did.
      recipe = recipe!()

      assert {:ok, result} =
               save([%{"kind" => "ingredient", "name" => "Flour", "unit" => "g"}], %{
                 id: recipe.id
               })

      assert result["valid?"]
      assert Ash.get!(Recipe, recipe.id, authorize?: false).title == "Bread"
    end

    test "an invalid document writes nothing" do
      recipe = recipe!()

      {:ok, result} =
        save([%{"kind" => "ingredient", "name" => "Salt", "unit" => "banana"}], %{
          id: recipe.id,
          complete: true
        })

      refute result["valid?"]
      assert Ash.count!(Ingredient, authorize?: false) == 0
    end

    test "saved elements are attached to the aggregate" do
      recipe = recipe!()

      {:ok, _} =
        save([%{"kind" => "ingredient", "name" => "Sugar", "unit" => "g"}], %{
          id: recipe.id,
          complete: true
        })

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

  describe "save is a sync, not an append" do
    # A document is the aggregate's whole contents, so saving it twice must not
    # duplicate it and removing an element from it must remove the record.
    # These are the cases a create-only loop passes in a fresh database and
    # fails on the second save — the normal editing loop.

    test "saving the same document twice does not duplicate it" do
      recipe = recipe!()
      document = [%{"kind" => "ingredient", "name" => "Sugar", "unit" => "g"}]

      {:ok, _} = save(document, %{id: recipe.id})
      {:ok, _} = save(document, %{id: recipe.id})

      assert Ash.count!(Ingredient, authorize?: false) == 1
    end

    test "an element matched by name is updated in place" do
      recipe = recipe!()

      {:ok, _} =
        save([%{"kind" => "ingredient", "name" => "Sugar", "quantity" => 10}], %{
          id: recipe.id,
          complete: true
        })

      [before] = Ash.read!(Ingredient, authorize?: false)

      {:ok, _} =
        save([%{"kind" => "ingredient", "name" => "Sugar", "quantity" => 99}], %{
          id: recipe.id,
          complete: true
        })

      assert [after_edit] = Ash.read!(Ingredient, authorize?: false)
      assert after_edit.quantity == 99
      # The same row, not a replacement. Matching is by the resource's declared
      # identity, which is what lets the DSL keep primary keys out of the text
      # an author writes.
      assert after_edit.id == before.id
    end

    test "an element removed from the document is removed from the aggregate" do
      recipe = recipe!()

      {:ok, _} =
        save(
          [
            %{"kind" => "ingredient", "name" => "Sugar", "unit" => "g"},
            %{"kind" => "ingredient", "name" => "Salt", "unit" => "g"}
          ],
          %{id: recipe.id}
        )

      {:ok, _} =
        save([%{"kind" => "ingredient", "name" => "Salt", "unit" => "g"}], %{
          id: recipe.id,
          complete: true
        })

      assert ["Salt"] = Ash.read!(Ingredient, authorize?: false) |> Enum.map(& &1.name)
    end

    test "a document holding fewer elements than the aggregate is refused" do
      # The failure a client cannot detect for itself. A truncated read and a
      # deliberate deletion produce the same document, and only the server holds
      # both counts — so a client that read one page of a paged collection and
      # saved it back would delete the rest, and report success.
      recipe = recipe!()

      {:ok, _} =
        save(
          [
            %{"kind" => "ingredient", "name" => "Sugar", "unit" => "g"},
            %{"kind" => "ingredient", "name" => "Salt", "unit" => "g"}
          ],
          %{id: recipe.id}
        )

      assert {:ok, result} =
               save([%{"kind" => "ingredient", "name" => "Sugar", "unit" => "g"}], %{
                 id: recipe.id
               })

      refute result["valid?"]
      assert [%{"kind" => "ingredients"} = error] = result["errors"]
      assert error["message"] =~ "holds 1 ingredients but the recipe has 2"

      # Refused means refused: nothing was written.
      assert Ash.count!(Ingredient, authorize?: false) == 2
    end

    test "a many_to_many is counted through the join, not by a foreign key" do
      # The shape that slipped through. A `many_to_many` has no foreign key on
      # the destination — `source_attribute` and `destination_attribute` are
      # both `id` — so counting `destination.id == root.id` matched nothing and
      # returned the whole table instead. Every relationship then looked
      # unchanged and a truncated document saved silently.
      #
      # Caught only against a live service, because every relationship in this
      # fixture was a `has_many`, where that spelling happens to be right.
      recipe = recipe!()

      {:ok, _} =
        save(
          [
            %{"kind" => "technique", "name" => "Kneading"},
            %{"kind" => "technique", "name" => "Folding"}
          ],
          %{id: recipe.id}
        )

      assert {:ok, result} =
               save([%{"kind" => "technique", "name" => "Kneading"}], %{id: recipe.id})

      refute result["valid?"]
      assert [%{"kind" => "techniques"} = error] = result["errors"]
      assert error["message"] =~ "holds 1 techniques but the recipe has 2"
    end

    test "the same document is saved when it says it is complete" do
      recipe = recipe!()

      {:ok, _} =
        save(
          [
            %{"kind" => "ingredient", "name" => "Sugar", "unit" => "g"},
            %{"kind" => "ingredient", "name" => "Salt", "unit" => "g"}
          ],
          %{id: recipe.id}
        )

      assert {:ok, result} =
               save([%{"kind" => "ingredient", "name" => "Sugar", "unit" => "g"}], %{
                 id: recipe.id,
                 complete: true
               })

      assert result["valid?"], inspect(result["errors"])
      assert ["Sugar"] = Ash.read!(Ingredient, authorize?: false) |> Enum.map(& &1.name)
    end

    test "a document that grows needs no declaration" do
      # The guard is about loss, not about size. Adding elements, or replacing
      # them one for one, is the ordinary case and must stay unceremonious.
      recipe = recipe!()

      {:ok, _} =
        save([%{"kind" => "ingredient", "name" => "Sugar", "unit" => "g"}], %{id: recipe.id})

      assert {:ok, result} =
               save(
                 [
                   %{"kind" => "ingredient", "name" => "Sugar", "unit" => "g"},
                   %{"kind" => "ingredient", "name" => "Salt", "unit" => "g"}
                 ],
                 %{id: recipe.id}
               )

      assert result["valid?"], inspect(result["errors"])
      assert Ash.count!(Ingredient, authorize?: false) == 2
    end

    test "emptying the document empties the aggregate" do
      recipe = recipe!()

      {:ok, _} =
        save([%{"kind" => "ingredient", "name" => "Sugar", "unit" => "g"}], %{
          id: recipe.id,
          complete: true
        })

      {:ok, _} = save([], %{id: recipe.id, complete: true})

      # Every managed relationship is passed, including ones the document says
      # nothing about. Iterating only what the document contains would make
      # removal inexpressible — deleting the last element leaves nothing behind
      # to group, so the relationship would never be managed.
      assert Ash.count!(Ingredient, authorize?: false) == 0
    end

    test "a relationship the document never mentions is still emptied" do
      recipe = recipe!()

      {:ok, _} =
        save(
          [
            %{"kind" => "ingredient", "name" => "Sugar", "unit" => "g"},
            %{"kind" => "step", "name" => "Mix", "body" => "combine"}
          ],
          %{id: recipe.id}
        )

      # Only ingredients now; steps are absent entirely rather than emptied.
      {:ok, _} =
        save([%{"kind" => "ingredient", "name" => "Sugar", "unit" => "g"}], %{
          id: recipe.id,
          complete: true
        })

      assert Ash.count!(Step, authorize?: false) == 0
      assert Ash.count!(Ingredient, authorize?: false) == 1
    end
  end

  describe "removal is derived from the schema" do
    test "an exclusively-owned child is destroyed" do
      # `Recipe has_many :ingredients` and `Ingredient belongs_to :recipe,
      # allow_nil?: false` — the child cannot exist without this parent, so the
      # schema states exclusive ownership and removal means destruction.
      relationship = Ash.Resource.Info.relationship(Recipe, :ingredients)

      assert AshHateoas.RootActions.manage_opts(relationship, Recipe)[:on_missing] == :destroy
    end

    test "a shared element is unlinked, not destroyed" do
      # `Recipe many_to_many :techniques` states that a technique belongs to no
      # single recipe. Destroying it because one document stopped mentioning it
      # would delete data another aggregate still refers to — and on a
      # polymorphic edge the database will not stop that, because such a column
      # carries no foreign key.
      relationship = Ash.Resource.Info.relationship(Recipe, :techniques)

      assert AshHateoas.RootActions.manage_opts(relationship, Recipe)[:on_missing] == :unrelate
    end

    test "removing a shared element from the document leaves the record" do
      recipe = recipe!()

      {:ok, _} = save([%{"kind" => "technique", "name" => "Kneading"}], %{id: recipe.id})
      assert Ash.count!(AshHateoas.Test.Technique, authorize?: false) == 1
      assert Ash.count!(AshHateoas.Test.RecipeTechnique, authorize?: false) == 1

      {:ok, _} = save([], %{id: recipe.id, complete: true})

      # The link is gone; the technique is not.
      assert Ash.count!(AshHateoas.Test.RecipeTechnique, authorize?: false) == 0
      assert Ash.count!(AshHateoas.Test.Technique, authorize?: false) == 1
    end

    test "a shared element is edited where it is written" do
      relationship = Ash.Resource.Info.relationship(Recipe, :techniques)
      opts = AshHateoas.RootActions.manage_opts(relationship, Recipe)

      # `on_match: :update` reverses what this asserted. Under `:ignore` a
      # document carrying an edited element saved **clean and discarded the
      # edit** — an author changed a value, was told it saved, and found it
      # unchanged. See the behavioural test below, which is what an
      # option-level assertion could not catch.
      #
      # `on_lookup: :relate` is what makes sharing work at all: without it, an
      # element not yet linked to this aggregate is created fresh, so two
      # documents naming the same technique produce two records rather than one
      # shared one.
      assert opts[:on_match] == :update
      assert opts[:on_lookup] == :relate
      assert opts[:on_missing] == :unrelate
    end

    test "editing a shared element through a document persists the edit" do
      # The property the option exists for, asserted on the *persisted* record
      # rather than on the response — a save that discards an edit still
      # returns success, which is how this went unseen.
      bread = recipe!()

      {:ok, _} =
        save([%{"kind" => "technique", "name" => "Kneading", "summary" => "fold and press"}], %{
          id: bread.id
        })

      {:ok, _} =
        save([%{"kind" => "technique", "name" => "Kneading", "summary" => "stretch and fold"}], %{
          id: bread.id
        })

      technique =
        Technique |> Ash.read!() |> Enum.find(&(&1.name == "Kneading"))

      assert technique.summary == "stretch and fold"
    end

    test "an edit through one aggregate is visible from another holding it" do
      # The consequence, stated rather than left implicit: linking an element
      # into two aggregates says they hold the *same* element, so editing it
      # changes both. A caller wanting an independent copy copies it.
      bread = recipe!()
      cake = Recipe |> Ash.Changeset.for_create(:create, %{title: "Cake"}) |> Ash.create!()

      {:ok, _} = save([%{"kind" => "technique", "name" => "Kneading"}], %{id: bread.id})
      {:ok, _} = save([%{"kind" => "technique", "name" => "Kneading"}], %{id: cake.id})

      {:ok, _} =
        save([%{"kind" => "technique", "name" => "Kneading", "summary" => "edited via cake"}], %{
          id: cake.id
        })

      from_bread =
        bread.id
        |> then(&Ash.get!(Recipe, &1, load: [:techniques]))
        |> Map.fetch!(:techniques)
        |> Enum.find(&(&1.name == "Kneading"))

      assert from_bread.summary == "edited via cake"
    end

    test "two aggregates naming the same element share one record" do
      bread = recipe!()
      cake = Recipe |> Ash.Changeset.for_create(:create, %{title: "Cake"}) |> Ash.create!()

      {:ok, _} = save([%{"kind" => "technique", "name" => "Kneading"}], %{id: bread.id})
      {:ok, _} = save([%{"kind" => "technique", "name" => "Kneading"}], %{id: cake.id})

      # One technique, two links — not two techniques. Under `on_lookup:
      # :ignore` this silently produced a duplicate on a data layer that does
      # not enforce identities, and a constraint violation on one that does.
      assert Ash.count!(AshHateoas.Test.Technique, authorize?: false) == 1
      assert Ash.count!(AshHateoas.Test.RecipeTechnique, authorize?: false) == 2
    end

    test "one aggregate cannot rename a shared element out from under another" do
      bread = recipe!()
      cake = Recipe |> Ash.Changeset.for_create(:create, %{title: "Cake"}) |> Ash.create!()

      {:ok, _} = save([%{"kind" => "technique", "name" => "Kneading"}], %{id: bread.id})
      {:ok, _} = save([%{"kind" => "technique", "name" => "Kneading"}], %{id: cake.id})

      # Bread's author renames it in their file. Under identity matching this is
      # indistinguishable from "remove Kneading, add Folding" — the document
      # carries no id, so the two edits are byte-identical. Rather than guess,
      # the shared element is read-only: Bread unlinks Kneading and links a new
      # Folding, and Cake is untouched.
      {:ok, _} = save([%{"kind" => "technique", "name" => "Folding"}], %{id: bread.id})

      cake_techniques =
        Recipe
        |> Ash.get!(cake.id, load: [:techniques], authorize?: false)
        |> Map.get(:techniques)
        |> Enum.map(& &1.name)

      assert cake_techniques == ["Kneading"]
    end

    test "matching uses the resource's declared identity, not the primary key" do
      relationship = Ash.Resource.Info.relationship(Recipe, :ingredients)

      # `identity :unique_name, [:name]` is why `stock Susceptible` can be
      # matched without the author ever writing a uuid.
      assert AshHateoas.RootActions.manage_opts(relationship, Recipe)[:use_identities] ==
               [:unique_name]
    end

    test "a resource with no identity falls back to the primary key" do
      relationship = Ash.Resource.Info.relationship(AshHateoas.Test.Document, :comments)

      # Nothing to match on but the id, so a document for such a resource would
      # have to carry one. Degrading rather than guessing at a natural key.
      assert AshHateoas.RootActions.manage_opts(relationship, AshHateoas.Test.Document)[
               :use_identities
             ] == [:_primary_key]
    end
  end

  describe "which relationships a document syncs" do
    test "a many_to_many join is not managed twice" do
      # Ash exposes the join a `many_to_many` travels through as a `has_many` of
      # its own, so both appear as manageable. Syncing both writes the join
      # table twice, and on the wire it would advertise the join as an element
      # kind an author writes — when it is plumbing nobody was asked to author.
      names =
        AshHateoas.Test.Recipe
        |> AshHateoas.RootActions.managed_relationships()
        |> Enum.map(& &1.name)

      assert :techniques in names
      refute :techniques_join_assoc in names
    end

    test "the many_to_many itself is still managed" do
      # Removing the join must not remove the relationship it serves: a document
      # still adds and removes techniques.
      names =
        AshHateoas.Test.Recipe
        |> AshHateoas.RootActions.managed_relationships()
        |> Enum.map(& &1.name)

      assert Enum.sort(names) == [:ingredients, :mixing_bowls, :steps, :techniques]
    end
  end

  describe "a relationship that is not public" do
    # `public?` defaults to `false` in Ash and means "appears in public
    # interfaces". Routes, the documentation's properties and the ontology all
    # honour it; `managed_relationships/1` did not — so a relationship nobody
    # opted in was advertised as an authorable element kind, and because
    # `on_missing/2` returns `:destroy` for an owned `has_many`, a document that
    # merely omitted those rows deleted them.
    #
    # `Recipe.audits` is the case: a private `has_many` to `RecipeAudit`.

    test "is not managed, so it is neither authorable nor destroyable" do
      names =
        Recipe
        |> AshHateoas.RootActions.managed_relationships()
        |> Enum.map(& &1.name)

      refute :audits in names
      assert Enum.sort(names) == [:ingredients, :mixing_bowls, :steps, :techniques]
    end

    test "the join is rejected by name even though it is itself not public" do
      # The ordering trap, pinned. Ash generates `techniques_join_assoc` for the
      # `many_to_many` and leaves it at the default `public?: false`. Filtering
      # public *before* collecting the join names would drop it from the list
      # the rejection reads, so it would be neither rejected nor filtered — and
      # the join table would be synced twice and advertised as an element kind.
      join = Ash.Resource.Info.relationship(Recipe, :techniques).join_relationship
      refute Ash.Resource.Info.relationship(Recipe, join).public?

      names =
        Recipe
        |> AshHateoas.RootActions.managed_relationships()
        |> Enum.map(& &1.name)

      refute join in names
      assert :techniques in names
    end

    test "its kind is rejected as unknown" do
      result = validate([%{"kind" => "recipe_audit", "note" => "written by a client"}])

      refute result["valid?"]
      assert "kind" in fields(result)

      assert Enum.any?(result["errors"], fn error ->
               error["field"] == "kind" and error["message"] =~ "unknown element kind"
             end)
    end

    test "omitting it from a document does not delete it" do
      recipe = recipe!()

      audit =
        AshHateoas.Test.RecipeAudit
        |> Ash.Changeset.for_create(:create, %{note: "seeded", recipe_id: recipe.id})
        |> Ash.create!(authorize?: false)

      # A document that says nothing about audits at all.
      {:ok, result} = save([%{"kind" => "step", "name" => "Mix"}], %{id: recipe.id})

      assert result["valid?"]

      assert Ash.get!(AshHateoas.Test.RecipeAudit, audit.id, authorize?: false).note ==
               "seeded"
    end
  end

  describe "an element no relationship points at" do
    # `Index.build/1` indexes every extension-carrying resource in the root's
    # *domain*, not only the destinations a save manages. So a kind can be known
    # to validation and unreachable to persistence — and the two disagreed:
    # `element_error/4` accepted it, then `group_by_relationship/2` folded it
    # into an `else _ -> acc` clause that dropped it without a word.
    #
    # `Comment` is the case: a `hateoas` resource in `Recipe`'s domain that
    # `Recipe` has no relationship to.

    test "is rejected rather than silently dropped" do
      result = validate([%{"kind" => "comment", "name" => "Nope"}])

      refute result["valid?"]
      assert fields(result) == ["kind"]
    end

    test "does not persist, and does not report success" do
      recipe = recipe!()

      {:ok, result} = save([%{"kind" => "comment", "name" => "Nope"}], %{id: recipe.id})

      # The failure this test exists for: a 200 whose document lost an element.
      refute result["valid?"]
      assert Ash.read!(AshHateoas.Test.Comment, authorize?: false) == []
    end
  end

  describe "a key that would vanish silently" do
    test "a non-string value under an unknown key is reported" do
      # The gap between the two existing checks: `authorable/3` drops what the
      # resource does not accept, and `reference_keys/2` catches the rest only
      # when the value is a *string*. A number or a boolean under a misspelled
      # key was cast by nothing and resolved by nothing — so a save reported
      # success and discarded the value, which is the worst answer available.
      result = validate([%{"kind" => "ingredient", "name" => "Sugar", "calories" => 5}])

      refute result["valid?"]
      assert Enum.any?(result["errors"], &(&1["field"] == "calories"))
    end

    test "the error names what the class does accept" do
      # An author who misspelled a field needs the list, not just a refusal.
      result = validate([%{"kind" => "ingredient", "name" => "Sugar", "calories" => 5}])
      [error] = Enum.filter(result["errors"], &(&1["field"] == "calories"))

      assert error["message"] =~ "Accepted:"
      assert error["message"] =~ "unit"
    end

    test "a string under an unknown key is still read as a reference" do
      # Not broken by the above: an unaccepted string key is how a document
      # writes a cross-element edge, and `graph_errors` reports it when it names
      # nothing.
      result = validate([%{"kind" => "step", "name" => "Mix", "uses" => "Nothing"}])

      refute result["valid?"]
      assert Enum.any?(result["errors"], &(&1["message"] =~ "no element named"))
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
