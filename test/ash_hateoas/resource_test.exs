defmodule AshHateoas.ResourceTest do
  use ExUnit.Case, async: true

  alias AshHateoas.Resource.Info
  alias AshHateoas.Test.{Actor, Article, Document, Domain, Unrouted}

  @actor %Actor{id: "someone", role: :admin}

  setup do
    article =
      Article
      |> Ash.Changeset.for_create(:create, %{title: "Spec"})
      |> Ash.create!(authorize?: false)

    %{article: article}
  end

  defp routes(resource), do: AshHateoas.Resource.Info.routes(resource)

  describe "Info readers" do
    test "extension?/1 distinguishes resources carrying the extension" do
      assert Info.extension?(Article)
      refute Info.extension?(Unrouted), "Unrouted does not carry AshHateoas.Resource"
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

    test "not_delegable/1 reads the declared actions" do
      assert Info.not_delegable(Article) == [:publish]
    end

    test "not_delegable/1 is empty for a resource declaring none" do
      assert Info.not_delegable(Document) == []
    end

    test "not_delegable?/2 answers per action" do
      assert Info.not_delegable?(Article, :publish)
      refute Info.not_delegable?(Article, :update)
    end

    test "not_delegable does not withhold the action from the surface" do
      refute :publish in Info.unrouted(Article)
      refute :publish in Info.exclusions(Article)
    end

    test "an undeclared enabled? reads as nil, not true" do
      assert Info.hateoas_enabled?(Article) == nil
      assert AshHateoas.Posture.enabled?(Article, Domain) == true
    end

    test "readers accept a record as well as a module", %{article: article} do
      assert Info.exclusions(article) == [:internal_reconcile]
    end

    test "type/1 reads the declared type" do
      assert Info.type(Article) == "article"
    end

    test "type/1 infers from the module name when undeclared" do
      # Compensating declares no `type`; the last module segment underscored.
      assert Info.type(AshHateoas.Test.Compensating) == "compensating"
    end
  end

  describe "the DSL applies without caller options" do
    test "an excluded action is not advertised", %{article: article} do
      affordances = AshHateoas.affordances(article, @actor, domain: Domain)

      refute Map.has_key?(affordances, :internal_reconcile),
             "the resource's own `exclude` must take effect with no opts passed"
    end

    test "an excluded action is still routed" do
      assert Enum.any?(routes(Article), &(&1.action == :internal_reconcile)),
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
        extensions: [AshHateoas.Resource]

      ets do
        private?(true)
      end

      hateoas do
        type("sole_get")
        base("/sole_gets")
        warn_on_missing_authorizers?(false)
      end

      attributes do
        uuid_primary_key(:id)
      end

      actions do
        defaults([:read])
      end
    end

    test "the primary read's get route is marked primary, so a record knows its @id" do
      # The primary read derives a `get` at `/:id` marked `primary?` — the
      # canonical URL a client uses as the node @id. One `:get` route means
      # "which is canonical" has a single answer, so it is derived.
      get_route =
        SoleGet
        |> AshHateoas.Resource.Info.routes()
        |> Enum.find(&(&1.type == :get))

      assert get_route.primary?
    end

    test "other route types are untouched" do
      index =
        SoleGet
        |> AshHateoas.Resource.Info.routes()
        |> Enum.find(&(&1.type == :index))

      refute index.primary?, "only the get route carries the record's canonical URL"
    end
  end

  describe "no relationship is routed" do
    alias AshHateoas.Test.Comment

    test "a to-many relationship gets no route of its own" do
      # `/articles/:id/comments` and `/articles/:id/relationships/comments` are
      # gone. Both addressed a *relationship of the record* through path
      # structure, which the link on the node already states — and this package
      # does not keep a second spelling of a fact because it is a quieter one.
      #
      # What replaces them is not a different URL but no URL: a loaded to-many
      # is an inline collection carrying its members, each with its own flat
      # `@id`.
      refute Article
             |> routes()
             |> Enum.any?(&(&1.relationship == :comments)),
             "a relationship is carried by a link, not by an address"
    end

    test "a to-one relationship is left alone, as it always was" do
      refute Comment
             |> routes()
             |> Enum.any?(&(&1.relationship == :document))
    end

    test "no route anywhere names a relationship" do
      # Document-wide rather than by example, because the failure mode is one
      # surviving derivation path rather than one wrong route.
      named =
        [Article, Comment, AshHateoas.Test.Document, AshHateoas.Test.Recipe]
        |> Enum.flat_map(&routes/1)
        |> Enum.reject(&is_nil(&1.relationship))

      assert named == []
    end

    test "the class collection is still the addressable one" do
      # Removing the per-relationship routes takes nothing away from the
      # destination's own collection, which is where its members are listed and
      # where its create affordance lives.
      assert Enum.any?(routes(Comment), &(&1.type == :index))
    end

    test "a private relationship is not on the surface at all" do
      # This used to be asserted of routes, where it is now trivially true —
      # nothing is routed. The property it was really protecting moved down a
      # layer with the mechanism: links are emitted from
      # `public_relationships/1`, so that is the list a private relationship
      # must stay out of, or the link becomes the leak the route was.
      linkable =
        AshHateoas.Test.Recipe
        |> Ash.Resource.Info.public_relationships()
        |> Enum.map(& &1.name)

      assert :steps in linkable, "a public to-many is on the surface"
      refute :audits in linkable, "a private one is not"
    end
  end

  describe "resources without the extension" do
    test "still produce affordances when called directly" do
      note =
        AshHateoas.Test.Unrouted
        |> Ash.Changeset.for_create(:create, %{label: "T"})
        |> Ash.create!(authorize?: false)

      affordances = AshHateoas.affordances(note, @actor, domain: Domain)

      assert map_size(affordances) > 0,
             "the backbone is usable without the extension; the extension adds declaration"
    end
  end
end
