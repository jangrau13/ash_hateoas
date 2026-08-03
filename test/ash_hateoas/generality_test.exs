defmodule AshHateoas.GeneralityTest do
  @moduledoc """
  The library names no domain concept.

  `ash_hateoas` describes *any* Ash domain. Everything it says is said in
  Hydra, JSON-LD, OWL or SHACL terms — "a property has a range", "a link may be
  dereferenced" — and never in the vocabulary of whichever application happens
  to be the first consumer.

  `hateoas2dsl` has carried this test for a while and it earns its place: it
  caught a leak the same day this one was written, where a comment explaining a
  SHACL disjunction reached for two class names from a test fixture to make the
  point concrete. The explanation was fine; the nouns were not.

  This is the same guard for the emitter. Without it the constraint is a
  convention that holds until someone reaches for a familiar example, and a
  library that names one consumer's concepts is no longer generic — even when
  only its comments do, because comments are what the next person reads before
  deciding what the code is for.

  ## What counts as a leak

  A concept belonging to one consumer's domain. Simulation supplies the current
  hazard (`stock`, `flow`, `converter`, `model`), since it is the domain being
  built against, and a service name is worse still — `svc_simulation` in a
  moduledoc says outright which application this library is for.

  ## What does not

  A word this package legitimately owns. `route`, `resource`, `link`,
  `collection`, `operation` and `document` are Hydra/Ash vocabulary. So is the
  ordinary English "model" in "the route model" — the test therefore looks for
  domain nouns in isolation rather than banning substrings, and permits the few
  places an illustrative example is genuinely clearer than an abstraction.
  """

  use ExUnit.Case, async: true

  # Concepts belonging to a consumer's domain rather than to this library.
  #
  # Deliberately not `transition`: that is state-machine vocabulary this package
  # owns through `ash_state_machine`, and `Projection` is built on it. Nor
  # `flow` on its own, which is ordinary English ("the Hydra client flow") as
  # often as it is a domain noun — it is caught below in the compound forms that
  # only a simulation produces.
  @domain_words ~w(stock converter)

  # Compounds a generic library has no reason to write. A property IRI like
  # `flow/model` names two domain concepts at once and cannot be anything else.
  @domain_phrases ["flow/model", "model.stocks", "converter/name", "model/stocks"]

  # A service name is the sharpest form of the leak: it names the consumer
  # outright.
  @service_names ~w(svc_simulation svc_library svc_authors hateoas2dsl hateoas_mcp)

  # Doc examples that illustrate a generic mechanism with a concrete document.
  # A flat element list is hard to picture in the abstract, and the code depends
  # on none of these words — but the allowance is per-file and narrow, so a new
  # leak elsewhere still fails.
  @illustrative ["lib/ash_hateoas/root_actions.ex"]

  defp sources do
    Path.wildcard("lib/**/*.ex")
  end

  defp read(path), do: {path, File.read!(path)}

  # A phrase is matched literally; a single word only as a whole word, so
  # "stock" is caught while an unrelated substring is not.
  defp leaked?(source, term) do
    if String.contains?(term, "/") or String.contains?(term, ".") do
      String.contains?(source, term)
    else
      Regex.match?(~r/\b#{term}s?\b/i, source)
    end
  end

  describe "the library names no consumer's domain" do
    test "no source names a domain concept" do
      leaks =
        for {path, source} <- Enum.map(sources(), &read/1),
            path not in @illustrative,
            term <- @domain_words ++ @domain_phrases,
            leaked?(source, term),
            do: "#{path}: #{term}"

      assert leaks == [],
             """
             a domain concept reached the library:

             #{Enum.join(leaks, "\n")}

             Everything here is stated in Hydra/JSON-LD/OWL/SHACL terms. If an
             example makes a mechanism clearer, describe the shape rather than
             borrowing a consumer's nouns.
             """
    end

    test "no source names a consuming service" do
      # Allowed nowhere, including the files that may carry an illustrative
      # example: naming the service says which application this library is for.
      leaks =
        for {path, source} <- Enum.map(sources(), &read/1),
            name <- @service_names,
            String.contains?(source, name),
            do: "#{path}: #{name}"

      assert leaks == [],
             """
             a consuming service is named in the library:

             #{Enum.join(leaks, "\n")}

             This package describes any Ash domain. Naming one consumer — even
             in a comment — states that it was built for that consumer.
             """
    end

    test "the illustrative allowance stays narrow" do
      # The allowance exists so a doc example may show a concrete document. If
      # it grows, the constraint has quietly become a convention.
      assert length(@illustrative) <= 1

      for path <- @illustrative do
        assert File.exists?(path), "#{path} is allowed an example but no longer exists"
      end
    end
  end

  describe "the library depends on no consumer" do
    test "no source references a consumer's module namespace" do
      leaks =
        for {path, source} <- Enum.map(sources(), &read/1),
            Regex.match?(~r/\bSvc[A-Z]/, source),
            do: path

      assert leaks == [], "a consumer's module namespace is referenced: #{inspect(leaks)}"
    end
  end
end
