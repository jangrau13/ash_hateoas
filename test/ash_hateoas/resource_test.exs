defmodule AshHateoas.ResourceTest do
  use ExUnit.Case, async: true

  alias AshHateoas.Resource.Info
  alias AshHateoas.Test.{Actor, Article, Document, Domain}

  @actor %Actor{id: "someone", role: :admin}

  setup do
    article =
      Article
      |> Ash.Changeset.for_create(:create, %{title: "Spec"})
      |> Ash.create!(authorize?: false)

    %{article: article}
  end

  describe "Info readers" do
    test "extension?/1 distinguishes resources carrying the extension" do
      assert Info.extension?(Article)
      refute Info.extension?(Document), "Document does not carry AshHateoas.Resource"
    end

    test "extension?/1 is false for anything that is not a resource" do
      refute Info.extension?(NotAModule)
      refute Info.extension?("not even an atom")
    end

    test "exclusions/1 reads the declared excludes" do
      assert Info.exclusions(Article) == [:internal_reconcile]
    end

    test "overrides/1 shapes overrides for the backbone's :overrides option" do
      assert Info.overrides(Article) == %{publish: [href: "/custom/publish/:id"]}
    end

    test "enabled? defaults to true" do
      assert Info.hateoas_enabled?(Article)
    end

    test "readers accept a record as well as a module", %{article: article} do
      assert Info.exclusions(article) == [:internal_reconcile]
    end
  end

  describe "the DSL applies without caller options (R2)" do
    test "an excluded action is not advertised", %{article: article} do
      affordances = AshHateoas.affordances(article, @actor, domain: Domain)

      refute Map.has_key?(affordances, :internal_reconcile),
             "the resource's own `exclude` must take effect with no opts passed"
    end

    test "an excluded action is still routed" do
      routes = AshJsonApi.Resource.Info.routes(Article, [Domain])

      assert Enum.any?(routes, &(&1.action == :internal_reconcile)),
             "exclude hides the affordance; it must not remove the route"
    end

    test "an override replaces the derived href", %{article: article} do
      affordances = AshHateoas.affordances(article, @actor, domain: Domain)

      assert affordances[:publish].href == "/custom/publish/:id"
    end

    test "actions without an override keep their derived href", %{article: article} do
      affordances = AshHateoas.affordances(article, @actor, domain: Domain)

      assert affordances[:update].href == "/articles/:id"
    end

    test "explicit opts still win over the declaration", %{article: article} do
      affordances =
        AshHateoas.affordances(article, @actor,
          domain: Domain,
          overrides: %{publish: [href: "/caller/wins"]}
        )

      assert affordances[:publish].href == "/caller/wins"
    end
  end

  describe "resources without the extension" do
    test "still produce affordances when called directly" do
      doc =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "T", owner_id: "o"})
        |> Ash.create!(authorize?: false)

      affordances = AshHateoas.affordances(doc, @actor, domain: Domain)

      assert map_size(affordances) > 0,
             "the backbone is usable without the extension; the extension adds declaration"
    end
  end
end
