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

    test "an undeclared enabled? reads as nil, not true" do
      # The generated reader returns the raw declaration. `nil` is what makes
      # domain inheritance possible — see AshHateoas.Posture. The *effective*
      # default lives there, not in the schema.
      assert Info.hateoas_enabled?(Article) == nil
      assert AshHateoas.Posture.enabled?(Article, Domain) == true
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

  describe "a record must be addressable" do
    defmodule SoleGet do
      @moduledoc false
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshJsonApi.Resource, AshHateoas.Resource]

      ets do
        private?(true)
      end

      json_api do
        type("sole_get")

        routes do
          base("/sole_gets")
          # Deliberately NOT primary? — the case the transformer repairs.
          get(:read)
          index(:read)
        end
      end

      attributes do
        uuid_primary_key(:id)
      end

      actions do
        defaults([:read])
      end

      hateoas do
        warn_on_missing_authorizers?(false)
      end
    end

    test "a sole get route is marked primary, so ash_json_api emits self" do
      # `ash_json_api` renders `self` from the `:get` route marked `primary?`,
      # and the option defaults to false. Without this a plain `get :read`
      # yields records carrying no link to themselves: readable, but with no
      # URL a link-following client could name them by.
      #
      # One `:get` route means "which is canonical" has a single answer, so it
      # is derived rather than demanded of the author (R1).
      get_route =
        SoleGet
        |> AshJsonApi.Resource.Info.routes([])
        |> Enum.find(&(&1.type == :get))

      assert get_route.primary?,
             "the sole get route was left non-primary, so records have no self link"
    end

    test "other route types are untouched" do
      index =
        SoleGet
        |> AshJsonApi.Resource.Info.routes([])
        |> Enum.find(&(&1.type == :index))

      refute index.primary?, "only the get route carries the record's self link"
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
