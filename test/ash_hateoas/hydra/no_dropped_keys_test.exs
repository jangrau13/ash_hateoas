defmodule AshHateoas.Hydra.NoDroppedKeysTest do
  @moduledoc """
  No document loses data to expansion.

  The rule this enforces:

  > **A JSON object key must be a JSON-LD keyword (`@id`, `@type`, …) or a term
  > the `@context` defines. A key that carries *data* is silently dropped.**

  Silently is the operative word. A processor discards what it cannot resolve
  and reports nothing, so the JSON looks complete while the graph is missing
  whole categories of statement — invisible to any test asserting on keys.
  Three ways it goes wrong, each a whole category rather than one field:
  relationship links on record nodes expanding to nothing; `title`/`name`
  captured by the referenced Hydra context and retyped; a map keyed by data
  (type names, error meta) putting values where a `@context` cannot reach.

  So this test checks no particular key. It fetches **every document shape the
  plug serves**, expands each, and asserts the predicates in the graph account
  for the keys in the JSON. A new shape that invents data-as-keys fails here
  without anyone having to remember the rule.

  ## Why a shape list rather than an example

  An example-based test proves one document is fine, while these defects take
  out a whole category at once — and a shape no test fetches is a shape nothing
  checks. Enumerating them makes coverage a property of the list rather than of
  what someone remembered to write.
  """

  use ExUnit.Case, async: false

  import Plug.Test

  alias AshHateoas.Test.JsonLd

  alias AshHateoas.Test.{Actor, Article, Comment, Document, HydraEndpoint, Placed, Recipe}

  @admin %Actor{id: "admin-1", role: :admin}

  defp get(path) do
    conn(:get, path)
    |> Ash.PlugHelpers.set_actor(@admin)
    |> HydraEndpoint.call([])
  end

  # Every non-keyword key in the JSON that carries a value, at any depth.
  #
  # `@context` is skipped, since its entries are term definitions rather than
  # data. So are keys whose value is `null`: JSON-LD drops those by design — an
  # absent value states nothing — and counting them would report a correctly
  # bound term as lost. Measured on a real node, where two nullable attributes
  # are declared, bound, and simply unset.
  defp json_keys(%{} = map) do
    own =
      map
      |> Enum.reject(fn {key, value} -> String.starts_with?(key, "@") or is_nil(value) end)
      |> Enum.map(&elem(&1, 0))

    own ++ (map |> Map.drop(["@context"]) |> Map.values() |> Enum.flat_map(&json_keys/1))
  end

  defp json_keys(list) when is_list(list), do: Enum.flat_map(list, &json_keys/1)
  defp json_keys(_other), do: []

  # Every predicate IRI in the expanded graph, at any depth.
  defp predicates(%{} = map) do
    own = map |> Map.keys() |> Enum.reject(&String.starts_with?(&1, "@"))

    own ++
      (map
       |> Map.values()
       |> List.flatten()
       |> Enum.filter(&is_map/1)
       |> Enum.flat_map(&predicates/1))
  end

  defp predicates(list) when is_list(list) do
    list |> Enum.filter(&is_map/1) |> Enum.flat_map(&predicates/1)
  end

  defp predicates(_other), do: []

  # A key survived if some predicate IRI ends with its local name — the same
  # comparison whether the key was bare (`title`) or prefixed (`hydra:title`).
  defp dropped_keys(document) do
    keys = document |> json_keys() |> Enum.uniq()

    preds =
      document
      |> JsonLd.expand()
      |> Enum.flat_map(&predicates/1)
      |> Enum.uniq()

    Enum.reject(keys, fn key ->
      local = key |> String.split(":") |> List.last()

      Enum.any?(
        preds,
        &(String.ends_with?(&1, "#" <> local) or String.ends_with?(&1, "/" <> local))
      )
    end)
  end

  setup do
    article =
      Article
      |> Ash.Changeset.for_create(:create, %{title: "T"})
      |> Ash.create!(authorize?: false)

    document =
      Document
      |> Ash.Changeset.for_create(:create, %{title: "O", owner_id: "admin-1"})
      |> Ash.create!(authorize?: false)

    Comment
    |> Ash.Changeset.for_create(:create, %{
      body: "c",
      document_id: document.id,
      article_id: article.id
    })
    |> Ash.create!(authorize?: false)

    recipe =
      Recipe |> Ash.Changeset.for_create(:create, %{title: "S"}) |> Ash.create!(authorize?: false)

    # The `:map` case. Every inner key is prefixed, which is the only thing that
    # makes one resolvable — see `AshHateoas.Hydra.Context.undeclared_keys/2`.
    placed =
      Placed
      |> Ash.Changeset.for_create(:create, %{
        label: "HQ",
        location: %{
          "@type" => "schema:Place",
          "schema:address" => "1 Main St",
          "schema:name" => "Head office"
        },
        stops: [%{"schema:name" => "Depot"}]
      })
      |> Ash.create!(authorize?: false)

    {:ok, article: article, document: document, recipe: recipe, placed: placed}
  end

  describe "every document shape the plug serves survives expansion" do
    test "all of them", %{article: article, document: document, recipe: recipe, placed: placed} do
      shapes = [
        {"ApiDocumentation", "/doc"},
        {"member", "/articles/#{article.id}"},
        {"member with operations", "/documents/#{document.id}"},
        {"collection", "/articles"},
        {"related collection", "/articles/#{article.id}/comments"},
        {"member with a to-one node reference", "/comments"},
        {"expanded to-one link", "/comments/with_document"},
        {"expanded to-many link", "/documents/with_comments"},
        {"root-action member", "/recipes/#{recipe.id}"},
        # One level further out than the rest: the keys at risk here are not the
        # node's own but the ones *inside* a `:map` attribute's value, which
        # nothing in the package declares.
        {"member with a :map attribute", "/placed/#{placed.id}"},
        {"error", "/articles/00000000-0000-0000-0000-000000000000"}
      ]

      failures =
        for {label, path} <- shapes,
            body = get(path).resp_body,
            dropped = body |> Jason.decode!() |> dropped_keys(),
            dropped != [],
            do: "#{label} (#{path}): #{Enum.join(dropped, ", ")}"

      assert failures == [],
             """
             keys present in the JSON that expand to nothing:

             #{Enum.join(failures, "\n")}

             A JSON-LD processor discards a key no term defines, and reports
             nothing. Either declare the key as a term, or carry the value
             somewhere a `@context` can reach — never as an object key.
             """
    end
  end

  describe "a :map attribute's inner keys" do
    test "the served node carries them, and nothing is lost", %{placed: placed} do
      # Belt and braces on the shape list above: assert the value really is
      # carried, not merely that no key is dropped from a document that might
      # have omitted the attribute entirely.
      node = served(placed)

      assert node["location"]["schema:address"] == "1 Main St"
      assert dropped_keys(node) == []
    end

    test "the same key written bare is dropped, from the very same document",
         %{placed: placed} do
      # The defect, demonstrated on a real response rather than described.
      # Nothing in the package can declare an application's map keys — they are
      # runtime data — so a bare one expands to nothing, and the JSON looks
      # complete while the graph is missing the statement.
      node = served(placed)

      bare =
        node
        |> Map.fetch!("location")
        |> Map.delete("schema:address")
        |> Map.put("address", "1 Main St")

      node = Map.put(node, "location", bare)

      assert "address" in dropped_keys(node)
    end

    test "the package says so out loud rather than dropping in silence" do
      # A compile-time check is impossible, since the keys are runtime data. So
      # the check is this, and it is what the plug warns from.
      terms = AshHateoas.Hydra.Context.node_terms(Placed)

      assert AshHateoas.Hydra.Context.undeclared_keys(
               %{"location" => %{"@type" => "schema:Place", "address" => "x"}},
               terms
             ) == ["address"]

      # Prefixed, declared, and JSON-LD keywords all resolve — and `location`
      # itself is a declared term, which is why it is absent above.
      assert AshHateoas.Hydra.Context.undeclared_keys(
               %{"location" => %{"@type" => "schema:Place", "schema:address" => "x"}},
               terms
             ) == []
    end
  end

  defp served(record) do
    "/placed/#{record.id}" |> get() |> Map.get(:resp_body) |> Jason.decode!()
  end

  describe "every template a served document carries names a URL" do
    # An `IriTemplate` exists to say **which URL to construct**, and a template
    # that says only how to spell the query string does not: a client expanding
    # `{?label}` gets `?label=x` with no path at all. That defect shipped once —
    # the documentation built its operations from the route table without
    # passing the route, so `href` was nil and every template collapsed — and it
    # is invisible to a unit test, which hands the renderer an affordance whose
    # href is already set.
    #
    # It belongs beside the expansion sweep for the same reason that one does:
    # the check is over **every shape the plug serves**, so a new template
    # emitted somewhere new is covered without a test being remembered. There
    # are two sources now — a node's GET affordance under `hydra:expects`, and
    # `ah:template` on every catalogue entry — and the second is why this is no
    # longer a documentation-only concern.

    defp served_templates(paths) do
      collect = fn collect, node, acc ->
        cond do
          is_map(node) ->
            acc = if node["@type"] == "IriTemplate", do: [node | acc], else: acc
            Enum.reduce(Map.values(node), acc, &collect.(collect, &1, &2))

          is_list(node) ->
            Enum.reduce(node, acc, &collect.(collect, &1, &2))

          true ->
            acc
        end
      end

      for path <- paths,
          template <-
            collect.(collect, path |> get() |> Map.get(:resp_body) |> Jason.decode!(), []),
          do: {path, template["hydra:template"]}
    end

    setup %{article: article} do
      {:ok,
       paths: [
         "/doc",
         "/articles/#{article.id}",
         "/articles",
         "/domain/read_failure/invalid?label=x"
       ]}
    end

    test "the shapes emit some, so this asserts on something", %{paths: paths} do
      assert served_templates(paths) != []
    end

    test "none is a bare query fragment", %{paths: paths} do
      bare = for {p, t} <- served_templates(paths), String.starts_with?(t, "{"), do: "#{p}: #{t}"

      assert bare == [],
             """
             a template with no path expands to a query string alone:

             #{Enum.join(bare, "\n")}
             """
    end

    test "none leaves a router placeholder in the path", %{paths: paths} do
      # `:id` is Plug's spelling, and RFC 6570 gives `:` no meaning — an expander
      # finds zero variables and hands back a literal `:id`.
      leaked =
        for {p, t} <- served_templates(paths),
            String.contains?(String.replace(t, ~r{^[a-z][a-z0-9+.-]*://}, ""), ":"),
            do: "#{p}: #{t}"

      assert leaked == [],
             """
             a router placeholder survived into a template:

             #{Enum.join(leaked, "\n")}
             """
    end
  end

  describe "data is never used as a JSON object key" do
    test "a document whose keys are values is exactly what this forbids" do
      # The shape the root listing had: a map keyed by type name, so the payload
      # sat in positions a `@context` cannot define. Constructed here rather
      # than served, since nothing emits it any more — the point is that the
      # detection works, so a future shape doing this is caught.
      keyed_by_data = %{
        "@context" => AshHateoas.Hydra.Context.context(),
        "hydra:collection" => %{
          "article" => %{"@id" => "/articles", "@type" => "Collection"},
          "document" => %{"@id" => "/documents", "@type" => "Collection"}
        }
      }

      assert "article" in dropped_keys(keyed_by_data)
      assert "document" in dropped_keys(keyed_by_data)
    end

    test "the same links carried as a list survive" do
      # The fix, had the listing been kept: values in value positions, with the
      # type named by `@type` rather than by the key.
      as_list = %{
        "@context" => AshHateoas.Hydra.Context.context(),
        "hydra:collection" => [
          %{"@id" => "/articles", "@type" => "Collection"},
          %{"@id" => "/documents", "@type" => "Collection"}
        ]
      }

      assert dropped_keys(as_list) == []
    end
  end
end
