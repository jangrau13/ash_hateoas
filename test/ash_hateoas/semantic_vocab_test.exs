defmodule AshHateoas.SemanticVocabTest do
  @moduledoc """
  A bare semantic token resolves against the configured vocabulary; schema.org is
  only the default. Absolute IRIs are always verbatim, so any ontology works.
  """

  # Not async: these tests mutate the application env (the configured vocab) and
  # must not run concurrently with anything reading it.
  use ExUnit.Case, async: false

  alias AshHateoas.SemanticVocab

  setup do
    # Always restore whatever was configured, so one test cannot leak into another
    # or into the rest of the suite.
    original = Application.get_env(:ash_hateoas, :semantic_vocab)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:ash_hateoas, :semantic_vocab)
        value -> Application.put_env(:ash_hateoas, :semantic_vocab, value)
      end
    end)

    :ok
  end

  describe "default (schema.org)" do
    test "a bare token resolves against schema.org" do
      Application.delete_env(:ash_hateoas, :semantic_vocab)

      assert SemanticVocab.base() == "https://schema.org/"
      assert SemanticVocab.prefix() == "schema"
      assert SemanticVocab.resolve("Person") == "https://schema.org/Person"
    end
  end

  describe "a custom ontology" do
    setup do
      Application.put_env(:ash_hateoas, :semantic_vocab,
        base: "http://www.ease-crc.org/ont/SOMA.owl#",
        prefix: "soma"
      )

      :ok
    end

    test "a bare token resolves against the configured base" do
      assert SemanticVocab.resolve("Grasping") ==
               "http://www.ease-crc.org/ont/SOMA.owl#Grasping"
    end

    test "the configured prefix is reported" do
      assert SemanticVocab.prefix() == "soma"
    end

    test "an absolute IRI is still used verbatim, whatever the configured vocab" do
      # so a resource can always mix vocabularies by writing full IRIs
      assert SemanticVocab.resolve("https://schema.org/Person") ==
               "https://schema.org/Person"
    end
  end

  describe "the emitted @context" do
    test "declares the configured prefix -> base" do
      Application.put_env(:ash_hateoas, :semantic_vocab,
        base: "http://oro.org/",
        prefix: "oro"
      )

      terms =
        AshHateoas.Hydra.Context.context()
        |> Enum.filter(&is_map/1)
        |> Enum.reduce(%{}, &Map.merge(&2, &1))

      assert terms["oro"] == "http://oro.org/"
      # schema.org stays available too, so absolute schema.org IRIs still compact
      assert terms["schema"] == "https://schema.org/"
    end
  end
end
