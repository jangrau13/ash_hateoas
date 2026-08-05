defmodule AshHateoas.LuaScript.CitationsTest do
  @moduledoc """
  What a script's citations say about a record that is about to be removed.

  The citation resource gives a citation a real foreign key, so Postgres *can*
  answer "is this cited?" — and must not be the one to act on the answer, since
  every cascade it offers is wrong in a different way. These are the two answers
  a domain may want instead.
  """

  use ExUnit.Case, async: false

  alias AshHateoas.LuaScript.Citations
  alias AshHateoas.Test.Scripted.{Author, Formula}

  setup do
    # ETS is process-global rather than sandboxed, so each test starts from a
    # known state instead of inheriting whatever ran before it.
    for resource <- [Formula.Citation, Formula, Author] do
      resource |> Ash.read!(authorize?: false) |> Enum.each(&Ash.destroy!(&1, authorize?: false))
    end

    :ok
  end

  defp author!(name) do
    Author
    |> Ash.Changeset.for_create(:create, %{name: name})
    |> Ash.create!(authorize?: false)
  end

  # A script and the citation row that says what it names. Both are written,
  # because a citation is what the source *claims* and the row is what resolves
  # — the two are checked against each other, so a test writing only one would
  # be testing a state the domain never produces.
  defp formula!(body, citations) do
    formula =
      Formula
      |> Ash.Changeset.for_create(:create, %{name: "f#{System.unique_integer([:positive])}", body: body})
      |> Ash.create!(authorize?: false)

    for {author, position} <- Enum.with_index(citations) do
      Formula.Citation
      |> Ash.Changeset.for_create(:create, %{
        script_id: formula.id,
        author_id: author.id,
        name: author.name,
        kind: :author,
        position: position
      })
      |> Ash.create!(authorize?: false)
    end

    formula
  end

  defp reload(formula), do: Ash.get!(Formula, formula.id, authorize?: false)

  describe "counting what cites a record" do
    test "a cited record is found by the bind that names it" do
      ada = author!("Ada")
      formula!(~s|author["Ada"] * 2|, [ada])

      assert Citations.cited_by(Formula, :author, ada.id) == 1
    end

    test "an uncited record is not" do
      ada = author!("Ada")
      grace = author!("Grace")
      formula!(~s|author["Ada"] * 2|, [ada])

      assert Citations.cited_by(Formula, :author, grace.id) == 0
    end

    test "several scripts citing one record are all counted" do
      # The number is what a refusal message says, so it has to be the real
      # count rather than "at least one".
      ada = author!("Ada")
      formula!(~s|author["Ada"] * 2|, [ada])
      formula!(~s|author["Ada"] + 1|, [ada])

      assert Citations.cited_by(Formula, :author, ada.id) == 2
    end

    test "a resource declaring no script answers zero rather than raising" do
      # A caller should not have to check for the extension first — the same
      # rule `Info` follows.
      assert Citations.cited_by(Author, :author, Ash.UUID.generate()) == 0
    end
  end

  describe "marking a removed record" do
    test "the citation keeps the name and loses the foreign key" do
      ada = author!("Ada")
      formula!(~s|author["Ada"] * 2|, [ada])

      assert Citations.mark_removed(Formula, :author, ada.id) == 1

      [citation] = Ash.read!(Formula.Citation, authorize?: false)
      assert citation.name == "Ada (removed)"
      assert citation.author_id == nil
    end

    test "the source is rewritten to match" do
      # **The half that is easy to miss.** Clearing the row and leaving the
      # source alone leaves the two disagreeing, and they are checked against
      # each other on every write — so the script would refuse its own next
      # update for a reason nothing in it explains.
      ada = author!("Ada")
      formula = formula!(~s|author["Ada"] * 2|, [ada])

      Citations.mark_removed(Formula, :author, ada.id)

      assert reload(formula).body == ~s|author["Ada (removed)"] * 2|
    end

    test "the rest of the script is untouched" do
      # Marking rather than deleting: removing the citation would take
      # `author["Grace"]` and the `+ 1` with it — everything else the author
      # wrote, because one referenced thing went away.
      ada = author!("Ada")
      grace = author!("Grace")
      formula = formula!(~s|author["Ada"] * author["Grace"] + 1|, [ada, grace])

      Citations.mark_removed(Formula, :author, ada.id)

      assert reload(formula).body == ~s|author["Ada (removed)"] * author["Grace"] + 1|

      grace_citation =
        Formula.Citation |> Ash.read!(authorize?: false) |> Enum.find(&(&1.name == "Grace"))

      assert grace_citation.author_id == grace.id
    end

    test "a name inside a string literal is left alone" do
      # The rewrite is by the subscript's exact spelling — `author["Ada"]` —
      # rather than by the name wherever it appears, so a literal that happens
      # to read the same is not a citation and is not touched.
      ada = author!("Ada")
      formula = formula!(~s|author["Ada"] .. "Ada"|, [ada])

      Citations.mark_removed(Formula, :author, ada.id)

      assert reload(formula).body == ~s|author["Ada (removed)"] .. "Ada"|
    end

    test "the suffix is the caller's" do
      ada = author!("Ada")
      formula = formula!(~s|author["Ada"]|, [ada])

      Citations.mark_removed(Formula, :author, ada.id, suffix: " (gone)")

      assert reload(formula).body == ~s|author["Ada (gone)"]|
    end

    test "marking an uncited record changes nothing" do
      ada = author!("Ada")
      grace = author!("Grace")
      formula = formula!(~s|author["Ada"]|, [ada])

      assert Citations.mark_removed(Formula, :author, grace.id) == 0
      assert reload(formula).body == ~s|author["Ada"]|
    end
  end

  describe "finding the citation resource" do
    test "a script resource has one" do
      assert Citations.citation_resource(Formula) == Formula.Citation
    end

    test "a resource with no script has none" do
      assert Citations.citation_resource(Author) == nil
    end
  end
end
