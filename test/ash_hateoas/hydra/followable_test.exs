defmodule AshHateoas.Hydra.FollowableTest do
  @moduledoc """
  Every URL a document advertises must resolve.

  This is the contract a hypermedia client depends on and the one assertion
  that catches a routing regression across *every* shape rather than the one
  shape a hand-written test happened to pick. A client does not construct URLs;
  it follows the ones it is given, so a link that 404s is a broken API however
  correct the record it appeared on.

  ## Why it is general

  The `:related` fix that landed earlier asserted only that a link **key** was
  present, never that the URL resolved — so it could not catch a regression, and
  a 404 shipped. Its replacement fetched the URL, but for one relationship on
  one resource out of five.

  These tests instead *discover* what to follow: fetch a record, read the links
  off the node, and GET each one. A new relationship, a new resource, or a new
  link kind is covered the moment it is emitted, with no test to remember to
  write.

  It was written for the change that nested an element's URL under its owner,
  and it earned its place immediately by catching all three href builders. It
  outlived that change: **un-nesting** rewrites the same paths in the opposite
  direction, and the sweep now covers more than it did, since a flat member
  advertises its own operations *and* the links that used to be path segments.
  A `many_to_many` and a `has_many` still reach the router differently, so
  covering only one leaves the other free to break silently.
  """

  use ExUnit.Case, async: false

  import Plug.Test

  alias AshHateoas.Test.{
    Actor,
    Article,
    Comment,
    Document,
    HydraEndpoint,
    Entry,
    Ingredient,
    Ledger,
    Recipe,
    RecipeTechnique,
    Step,
    Technique
  }

  @admin %Actor{id: "admin-1", role: :admin}

  defp get(path) do
    conn(:get, path)
    |> Ash.PlugHelpers.set_actor(@admin)
    |> HydraEndpoint.call([])
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  # Every URL the node advertises **as followable** — a relationship link, a
  # `hydra:collection`, a `hydra:view` page, a member's own `@id`. Collected by
  # walking the document rather than by naming keys, so a link emitted somewhere
  # new is followed without this test changing.
  #
  # An **operation target** is deliberately excluded, and the distinction is
  # Hydra's own. `hydra:Link` marks a value *intended to be dereferenced*;
  # `/documents/<id>/approve` is a POST endpoint, so a GET against it correctly
  # 404s. On the wire the two are already distinct shapes:
  #
  #     "comments":   {"@id" => "…/comments", "@type" => "Collection"}   ← follow
  #     "ah:approve": {"@id" => "…/approve", "hydra:operation" => […]}   ← invoke
  #
  # So a node carrying `hydra:operation` states what may be *done* at that URL,
  # not that it may be fetched. Keying on that rather than on the `ah:` prefix
  # keeps this test from encoding the current spelling — the plan's optional
  # step folds those nodes into `hydra:operation`, and this survives it.
  defp advertised_urls(node) do
    node
    |> collect_ids()
    |> Enum.filter(&String.starts_with?(&1, "/"))
    |> Enum.uniq()
  end

  defp collect_ids(%{} = map) do
    own =
      if is_binary(map["@id"]) and not Map.has_key?(map, "hydra:operation") do
        [map["@id"]]
      else
        []
      end

    nested =
      map
      |> Map.drop(["@id", "hydra:operation", "odrl:permission", "@context"])
      |> Enum.flat_map(fn {_k, v} -> collect_ids(v) end)

    own ++ nested
  end

  defp collect_ids(list) when is_list(list), do: Enum.flat_map(list, &collect_ids/1)
  defp collect_ids(_other), do: []

  setup do
    article =
      Article |> Ash.Changeset.for_create(:create, %{title: "Followed"}) |> Ash.create!(authorize?: false)

    document =
      Document
      |> Ash.Changeset.for_create(:create, %{title: "Owner", owner_id: "admin-1"})
      |> Ash.create!(authorize?: false)

    Comment
    |> Ash.Changeset.for_create(:create, %{
      body: "mine",
      document_id: document.id,
      article_id: article.id
    })
    |> Ash.create!(authorize?: false)

    recipe =
      Recipe
      |> Ash.Changeset.for_create(:create, %{title: "Soup"})
      |> Ash.create!(authorize?: false)

    Step
    |> Ash.Changeset.for_create(:create, %{name: "Chop", recipe_id: recipe.id})
    |> Ash.create!(authorize?: false)

    Ingredient
    |> Ash.Changeset.for_create(:create, %{name: "Onion", recipe_id: recipe.id})
    |> Ash.create!(authorize?: false)

    technique =
      Technique
      |> Ash.Changeset.for_create(:create, %{name: "Braise"})
      |> Ash.create!(authorize?: false)

    RecipeTechnique
    |> Ash.Changeset.for_create(:create, %{recipe_id: recipe.id, technique_id: technique.id})
    |> Ash.create!(authorize?: false)

    {:ok, article: article, document: document, recipe: recipe}
  end

  describe "every URL a record advertises resolves" do
    test "a record with a has_many", %{article: article} do
      assert_all_followable("/articles/#{article.id}")
    end

    test "a record with several has_many relationships", %{recipe: recipe} do
      # Recipe carries three public to-many relationships — two `has_many` and
      # one `many_to_many`. The join is built differently from a plain
      # `has_many`, so covering only the latter leaves it free to break.
      assert_all_followable("/recipes/#{recipe.id}")
    end

    test "a record reached through a different owner", %{document: document} do
      assert_all_followable("/documents/#{document.id}")
    end
  end

  describe "every URL a collection advertises resolves" do
    test "the collection document itself" do
      assert_all_followable("/articles")
    end

    test "an inline collection's members are each followable", %{article: article} do
      # Was the two-hop case: follow the link off a record, then follow what the
      # related collection advertised. With the members inline there is one hop
      # fewer and the same obligation — a member carries its own flat `@id`, so
      # it is a link *and* the data, and that link must resolve.
      node =
        "/articles/with_comments"
        |> get()
        |> body()
        |> Map.get("hydra:member")
        |> Enum.find(&(&1["@id"] =~ article.id))

      members = node["comments"]["hydra:member"]

      assert members != [], "the read loads :comments, so they must be here"

      for member <- members, do: assert_all_followable(member["@id"])
    end
  end

  describe "a record with a required link is followable flatly" do
    setup do
      ledger =
        Ledger |> Ash.Changeset.for_create(:create, %{name: "L"}) |> Ash.create!(authorize?: false)

      entry =
        Entry
        |> Ash.Changeset.for_create(:create, %{memo: "M", ledger_id: ledger.id})
        |> Ash.create!(authorize?: false)

      {:ok, ledger: ledger, entry: entry}
    end

    test "every URL the member advertises resolves", %{entry: entry} do
      # These cases used to address `/domain/ledger/<id>/entry/<id>` and caught
      # a real defect there: nesting put a second placeholder in every route
      # and three href builders substituted only `:id`, so each operation
      # advertised `/ledger/:ledger_id/entry/<id>` — a pattern, not an address,
      # and a 404 a key-presence assertion would have called fine.
      #
      # Flat addressing removes that particular trap and the sweep now covers
      # *more*: a member advertises its own operations and its `ledger` link,
      # every one of which must resolve.
      assert_all_followable("/domain/entry/#{entry.id}")
    end

    test "every URL the collection advertises resolves" do
      # And the collection exists to be swept at all. Under nesting there was
      # no `/domain/entry`.
      assert_all_followable("/domain/entry")
    end

    test "the link's target is itself followable", %{entry: entry} do
      # The property that makes the edge a link rather than a decoration: the
      # URL the record states for its ledger is one the API serves, and
      # everything *that* node advertises resolves in turn.
      href = body(get("/domain/entry/#{entry.id}"))["ledger"]["@id"]

      assert_all_followable(href)
    end

    test "the other side's own URLs are unaffected", %{ledger: ledger} do
      assert_all_followable("/domain/ledger/#{ledger.id}")
    end
  end

  describe "any URL is a place to start" do
    test "a record reached cold is followable and describes the API", %{article: article} do
      # There is no entry point to begin at, so this is the property that
      # replaces it: a client holding one URL — from a bookmark, a search
      # result, another service — can follow everything that URL advertises and
      # reach the description from it.
      path = "/articles/#{article.id}"

      assert_all_followable(path)

      conn = get(path)
      assert [link] = Plug.Conn.get_resp_header(conn, "link")
      assert link =~ "apiDocumentation"
    end
  end

  # Fetches `path`, then GETs every URL the response advertises. Reports all
  # failures at once — one broken link per run would make a routing regression
  # take as many runs as it broke links.
  defp assert_all_followable(path) do
    conn = get(path)
    assert conn.status == 200, "#{path} itself did not resolve (#{conn.status})"

    urls = conn |> body() |> advertised_urls()

    assert urls != [], "#{path} advertised no URLs — the test would assert nothing"

    broken =
      urls
      |> Enum.map(&{&1, get(&1).status})
      |> Enum.reject(fn {_url, status} -> status in 200..299 end)

    assert broken == [],
           """
           #{path} advertises #{length(urls)} URLs; #{length(broken)} did not resolve:

           #{Enum.map_join(broken, "\n", fn {url, status} -> "  #{status}  #{url}" end)}

           A client follows the URLs it is given rather than constructing them,
           so an advertised link that 404s is a broken contract.
           """
  end

end
