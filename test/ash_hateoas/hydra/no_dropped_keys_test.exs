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

  alias AshHateoas.Test.{Actor, Article, Comment, Document, HydraEndpoint, Recipe}

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

    {:ok, article: article, document: document, recipe: recipe}
  end

  describe "every document shape the plug serves survives expansion" do
    test "all of them", %{article: article, document: document, recipe: recipe} do
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
