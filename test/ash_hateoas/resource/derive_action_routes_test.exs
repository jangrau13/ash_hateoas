defmodule AshHateoas.Resource.DeriveActionRoutesTest do
  @moduledoc """
  Every action is routed by default; not being routed is a declaration.

  This inverts what the package assumed until now. The old default was
  allow-list — an action reached the HTTP surface only once an author wrote a
  route for it — and `AshHateoas.Test.Derived` exists to pin exactly that
  distinction. The new default is deny-list: declaring an action is declaring
  an endpoint, and `unrouted :name` is how an author takes it back.

  The trade is deliberate and worth naming, because these tests are what holds
  the dangerous half of it. Under an allow-list, forgetting gives a 404.
  Under a deny-list, forgetting publishes. So the cases below that matter most
  are not the ones proving routes appear — they are the ones proving `unrouted`
  actually suppresses, and that a declared route is never silently replaced.
  """

  use ExUnit.Case, async: true

  alias AshHateoas.Test.Domain

  defp routes(resource), do: AshJsonApi.Resource.Info.routes(resource, [Domain])

  defp route_for(resource, action) do
    resource |> routes() |> Enum.find(&(&1.action == action))
  end

  defp routed?(resource, action), do: route_for(resource, action) != nil

  describe "primary actions become the REST verbs" do
    test "the primary read is both `get` and `index`" do
      # One action, two routes: the collection and the member. Nothing about
      # the action says which it is, but a resource with a primary read has
      # both by convention, and neither is a judgement call.
      types =
        AshHateoas.Test.AutoRouted
        |> routes()
        |> Enum.filter(&(&1.action == :read))
        |> Enum.map(& &1.type)
        |> Enum.sort()

      assert types == [:get, :index]
    end

    test "the primary create is `post` at the collection" do
      route = route_for(AshHateoas.Test.AutoRouted, :create)

      assert route.type == :post
      assert route.route == "/auto_routeds"
    end

    test "the primary update is `patch` at the member" do
      route = route_for(AshHateoas.Test.AutoRouted, :update)

      assert route.type == :patch
      assert route.route == "/auto_routeds/:id"
    end

    test "the primary destroy is `delete` at the member" do
      route = route_for(AshHateoas.Test.AutoRouted, :destroy)

      assert route.type == :delete
      assert route.route == "/auto_routeds/:id"
    end

    test "the derived `get` is primary?, so records carry a self link" do
      # Otherwise `ash_json_api` emits no `self` and the record is addressable
      # but unnameable — the failure `MarkPrimaryGet` was written to prevent.
      # Deriving a `get` without marking it would reintroduce it wholesale.
      route =
        AshHateoas.Test.AutoRouted
        |> routes()
        |> Enum.find(&(&1.type == :get))

      assert route.primary?
    end
  end

  describe "non-primary actions are routed under their own name" do
    test "a non-primary update is `patch` at /:id/<action>" do
      route = route_for(AshHateoas.Test.AutoRouted, :publish)

      assert route.type == :patch
      assert route.route == "/auto_routeds/:id/publish"
    end

    test "a generic action returning a scalar is routed too" do
      # It goes through `ash_json_api`'s `:route` entity rather than a verb
      # entity, and that one applies no return-type check — so `:boolean` is
      # fine. `get`/`index`/`post` would reject it, which is what makes the
      # entity choice load-bearing rather than incidental.
      route = route_for(AshHateoas.Test.AutoRouted, :tally)

      assert route.type == :route
      assert route.route == "/auto_routeds/:id/tally"
    end

    test "a generic action's method defaults to POST" do
      assert route_for(AshHateoas.Test.AutoRouted, :tally).method == :post
    end

    test "a declared method overrides the assumed POST" do
      assert route_for(AshHateoas.Test.GenericGet, :peek).method == :get
    end

    test "every action kind is derived, generic included" do
      # The feature's scope, asserted as a whole: if derivation ever stopped
      # covering an action kind, this fails rather than the surface quietly
      # shrinking.
      for action <- [:read, :create, :update, :destroy, :publish, :tally] do
        assert routed?(AshHateoas.Test.AutoRouted, action),
               ":#{action} must be derived"
      end
    end

    test "a non-primary read does not squat the collection path" do
      # Two reads both claiming "/" would be a duplicate route, and which one
      # answers GET /things is exactly the ambiguity that justifies making
      # non-primaries name-addressed rather than verb-addressed.
      paths =
        AshHateoas.Test.AutoRouted
        |> routes()
        |> Enum.filter(&(&1.type in [:get, :index]))
        |> Enum.map(& &1.route)

      assert length(paths) == length(Enum.uniq(paths)),
             "derived read routes collide: #{inspect(paths)}"
    end
  end

  describe "unrouted suppresses derivation (the opt-out)" do
    test "an unrouted action gets no route at all" do
      # The load-bearing test of the whole feature. If this regresses, every
      # action an author meant to keep internal is live, and nothing else here
      # would notice.
      refute routed?(AshHateoas.Test.Derived, :unrouted_touch)
      refute routed?(AshHateoas.Test.Derived, :admin_only)
    end

    test "unrouting one action leaves its siblings routed" do
      assert routed?(AshHateoas.Test.Derived, :touch),
             ":touch differs from :unrouted_touch only by not being unrouted"

      assert routed?(AshHateoas.Test.Derived, :read)
    end

    test "an unrouted action is therefore not advertised" do
      # R1 derives affordances from routes, so suppressing the route must
      # suppress the affordance. Asserted directly rather than inferred: the
      # two could drift if affordances ever read actions instead.
      record =
        AshHateoas.Test.Derived
        |> Ash.Changeset.for_create(:create, %{label: "x"})
        |> Ash.create!(authorize?: false)

      affordances =
        AshHateoas.affordances(record, %AshHateoas.Test.Actor{id: "a", role: :admin},
          domain: Domain
        )

      refute Map.has_key?(affordances, :unrouted_touch)
    end
  end

  describe "a declared route wins" do
    test "an author's route is kept, not duplicated" do
      # Same rule DeriveRelationshipRoutes already applies. Deriving alongside
      # a declared route would produce two routes for one action and, where
      # the paths match, a conflict at router build time.
      declared =
        AshHateoas.Test.HandRouted
        |> routes()
        |> Enum.filter(&(&1.action == :publish))

      assert [route] = declared
      assert route.route == "/hand_routeds/:id/ship-it"
    end

    test "actions the author did not route are still derived" do
      # A partial `routes` block is a partial declaration, not an opt-out of
      # derivation for the rest of the resource.
      assert routed?(AshHateoas.Test.HandRouted, :archive)
    end
  end

  describe "AshAuthentication's own actions are not routed" do
    @describetag :auth

    test "the subject resolver gets no route" do
      # `:get_by_subject` is guarded by a bypass on
      # `AshAuthentication.Checks.AshAuthenticationInteraction`, which matches
      # only when `private.ash_authentication?` is set on the context — and
      # that "will only ever be set in code that is called internally by
      # ash_authentication" (its own moduledoc). An HTTP request never carries
      # it, so a derived route falls through to the remaining policies and
      # denies. An endpoint that always 403s is an affordance no client can use.
      refute routed?(AshHateoas.Test.AuthUser, :get_by_subject)
    end

    test "sign-in and registration get no JSON:API route" do
      # AshAuthentication serves these through its OWN router, and that is the
      # path its clients, tokens and plugs are built around. A second route to
      # the same action adds a path, not a capability — and one that bypasses
      # the phase handling the auth router provides.
      refute routed?(AshHateoas.Test.AuthUser, :sign_in_with_password)
      refute routed?(AshHateoas.Test.AuthUser, :register_with_password)
    end

    test "the resource's own actions are still routed" do
      # The rule keys on what AshAuthentication generated, not on the resource
      # carrying the extension. An ordinary action on a user resource is an
      # ordinary endpoint.
      assert routed?(AshHateoas.Test.AuthUser, :read)
      assert routed?(AshHateoas.Test.AuthUser, :set_role)
    end

    test "a resource without AshAuthentication is unaffected" do
      # The detection must not fire — or raise — where the extension is absent.
      assert routed?(AshHateoas.Test.AutoRouted, :read)
    end
  end

  describe "Reactor compensation actions are not routed" do
    test "an undo action taking a changeset gets no route" do
      # Ash requires a Reactor `undo_action` to take exactly one argument named
      # `changeset` — `verify_action_takes_changeset/3` rejects any other shape.
      # An HTTP caller cannot construct an `Ash.Changeset` and put it in a
      # request body, so a derived route here would be an affordance that
      # raises when followed. Skipping is the same reasoning that skips to-one
      # relationship routes.
      #
      # No `unrouted` needed: the shape is declared, so it is read rather than
      # restated.
      refute routed?(AshHateoas.Test.Compensating, :undo_create)
    end

    test "its siblings are routed as usual" do
      # The rule keys on the argument shape, not on the resource. Being part of
      # a saga does not make an action internal — a reactor's forward steps are
      # ordinary writes, and `create` is typically both.
      assert routed?(AshHateoas.Test.Compensating, :create)
      assert routed?(AshHateoas.Test.Compensating, :read)
    end

    test "a destroy taking other arguments is still routed" do
      # Guards the narrowness of the check. Only the exact single-`:changeset`
      # shape is skipped; a destroy with ordinary arguments is a normal
      # endpoint and must not be caught by it.
      assert routed?(AshHateoas.Test.Compensating, :archive)
    end
  end

  describe "the base path is derived too" do
    test "a resource declaring no base gets /<domain>/<type>" do
      # Both halves are declared facts, not guesses: `short_name` off the
      # domain, `type` off the json_api section. The domain segment is the
      # domain module's LAST segment underscored — `AshHateoas.Test.Domain`
      # gives `domain`, `MyApp.Blog` gives `blog`. Nothing is pluralised — see
      # the test below for why.
      assert AshHateoas.Test.NoBase
             |> routes()
             |> Enum.map(& &1.route)
             |> Enum.all?(&String.starts_with?(&1, "/domain/no_base"))
    end

    test "the type is used verbatim, not pluralised" do
      # ash#31 removed exactly this guess framework-wide — ash_postgres stopped
      # guessing table names and ash_json_api stopped guessing base routes, in
      # one decision. Pluralisation is where the guessing lived: `person` ->
      # `/persons`, `status` -> `/statuss`. A wrong base makes every URL for
      # the resource wrong, and URLs are public API.
      #
      # So the singular is deliberate. `base` remains available for an author
      # who wants the conventional plural.
      collection =
        AshHateoas.Test.NoBase
        |> routes()
        |> Enum.find(&(&1.type == :index))

      assert collection.route == "/domain/no_base"
      refute collection.route =~ "no_bases"
    end

    test "a declared base still wins" do
      # Derivation fills a gap; it does not overrule. Same rule as routes.
      assert AshHateoas.Test.AutoRouted
             |> routes()
             |> Enum.all?(&String.starts_with?(&1.route, "/auto_routeds"))
    end
  end

  describe "the assumed method is announced" do
    test "an undeclared generic action warns that POST was assumed" do
      # The verb is the one fact derivation cannot read off the DSL, so it is
      # the one place this feature guesses. Guessing silently is what the whole
      # deny-list design is trying to avoid, so it says so.
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule AshHateoasAssumedMethod#{System.unique_integer([:positive])} do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshJsonApi.Resource, AshHateoas.Resource]

            json_api do
              type "assumed"
              routes do
                base "/assumeds"
              end
            end

            hateoas do
              warn_on_missing_authorizers?(false)
            end

            attributes do
              uuid_primary_key :id
            end

            actions do
              defaults [:read]

              action :tally, :boolean do
                run fn _input, _ctx -> {:ok, true} end
              end
            end
          end
          """)
        end)

      assert stderr =~ "tally", "the diagnostic must name the action"
      assert stderr =~ "POST"
      assert stderr =~ "method :tally, :get", "it must show how to correct the verb"
    end

    test "declaring the method silences the warning" do
      # Either verb silences it — confirming POST is as good an answer as
      # changing it. What the warning tracks is whether a human decided, not
      # which way they decided.
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule AshHateoasDeclaredMethod#{System.unique_integer([:positive])} do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshJsonApi.Resource, AshHateoas.Resource]

            json_api do
              type "declared"
              routes do
                base "/declareds"
              end
            end

            hateoas do
              warn_on_missing_authorizers?(false)
              method :tally, :post
            end

            attributes do
              uuid_primary_key :id
            end

            actions do
              defaults [:read]

              action :tally, :boolean do
                run fn _input, _ctx -> {:ok, true} end
              end
            end
          end
          """)
        end)

      refute stderr =~ "by assumption",
             "declaring the method must silence it, got: #{stderr}"
    end
  end

  describe "what is left alone" do
    test "a resource without ash_json_api is untouched" do
      # No json_api section means no routes DSL path to write into. The
      # transformer must no-op rather than raise, or adding AshHateoas to a
      # non-API resource stops the build.
      assert AshHateoas.Test.NoJsonApi.spark_dsl_config()
    end

    test "an unrouted name that is not an action fails the build" do
      # Same contract as `exclude`/`override` (R2): a renamed action must break
      # the build rather than silently start being routed again — which is the
      # deny-list's worst failure, since it is silent publication.
      #
      # Compiled from a source string for the reason r1_r2_r5_test.exs
      # documents: Spark verifiers run in `__verify_spark_dsl__` at module
      # compile time, so the error escapes an inline `defmodule`.
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule AshHateoasBogusUnrouted#{System.unique_integer([:positive])} do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshHateoas.Resource]

            hateoas do
              warn_on_missing_authorizers?(false)
              unrouted :no_such_action
            end

            attributes do
              uuid_primary_key :id
            end

            actions do
              defaults [:read]
            end
          end
          """)
        end)

      assert stderr =~ "DslError"
      assert stderr =~ "does not exist"
      assert stderr =~ "no_such_action", "the diagnostic must name the offending action"
    end
  end
end
