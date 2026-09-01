defmodule AshHateoas.Resource.DeriveActionRoutesTest do
  @moduledoc """
  Every action is routed by default; not being routed is a declaration.

  Route derivation is a deny-list: declaring an action is declaring an endpoint,
  and `unrouted :name` is how an author takes it back. Routes are
  `AshHateoas.Route` structs read via `AshHateoas.Resource.Info.routes/1`, and
  every path is base-qualified at derivation time.

  The cases that matter most are not the ones proving routes appear — they are
  the ones proving `unrouted` actually suppresses.
  """

  use ExUnit.Case, async: true

  alias AshHateoas.Test.Domain

  defp routes(resource), do: AshHateoas.Resource.Info.routes(resource)

  defp route_for(resource, action) do
    resource |> routes() |> Enum.find(&(&1.action == action))
  end

  defp routed?(resource, action), do: route_for(resource, action) != nil

  describe "primary actions become the REST verbs" do
    test "the primary read is both `get` and `index`" do
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

    test "the derived `get` is primary?, so a record knows its own @id" do
      route =
        AshHateoas.Test.AutoRouted
        |> routes()
        |> Enum.find(&(&1.type == :get))

      assert route.primary?
    end
  end

  describe "non-primary actions are routed under their own name" do
    test "a named transition is a POST at /:id/<action>, not a PATCH" do
      # It was a `PATCH`, because the Ash action's type is `:update` and the verb
      # was read straight off it. RFC 5789 defines `PATCH` by its body — "a set
      # of instructions describing how a resource currently residing on the
      # origin server should be modified" — and a named transition does not send
      # one. `publish` sends nothing at all, so it was a PATCH with no patch
      # document, which has no defined meaning.
      #
      # RFC 9110 gives the method for it: POST performs "resource-specific
      # processing on the request content".
      route = route_for(AshHateoas.Test.AutoRouted, :publish)

      assert route.type == :post
      assert route.route == "/auto_routeds/:id/publish"
    end

    test "the primary update keeps PATCH, which is what a partial modification is" do
      # The distinction the change exists to restore: one verb used to sit on
      # three unlike operations of one class, so `hydra:method` separated none of
      # them.
      route = route_for(AshHateoas.Test.AutoRouted, :update)

      assert route.type == :patch
      assert route.route == "/auto_routeds/:id"
    end

    test "a named transition still addresses one record" do
      # The property a reader has to keep after the verb moved. A `:post` used to
      # mean "the collection" to everything that sorted routes by kind, and this
      # one plainly names a record — so the sort is by the path.
      assert AshHateoas.Route.member?(route_for(AshHateoas.Test.AutoRouted, :publish))
      refute AshHateoas.Route.member?(route_for(AshHateoas.Test.AutoRouted, :create))
    end

    test "a generic action returning a scalar is routed too" do
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

    test "a declared method is the escape hatch for a sub-action too" do
      # The override used to be read only for a generic action, so an author who
      # said `method :publish, :patch` on a named transition got a documentation
      # entry saying PATCH and a router that answered only POST. It is read for
      # any non-primary action now, which is what makes the derived POST a
      # default rather than a rule.
      declared = AshHateoas.Resource.Info.method(AshHateoas.Test.AutoRouted, :publish)

      assert declared == nil, "the fixture declares none, so the derived verb is what is asserted"
      assert route_for(AshHateoas.Test.AutoRouted, :publish).method == nil
    end

    test "every action kind is derived, generic included" do
      for action <- [:read, :create, :update, :destroy, :publish, :tally] do
        assert routed?(AshHateoas.Test.AutoRouted, action),
               ":#{action} must be derived"
      end
    end

    test "a collection read derives its own index; the canonical one stays resolvable" do
      indexes =
        AshHateoas.Test.MultiRead
        |> routes()
        |> Enum.filter(&(&1.type == :index))

      routes = Enum.map(indexes, & &1.route)
      assert "/domain/multi_read" in routes, "the primary read's index must exist"
      assert "/domain/multi_read/by_label" in routes, "the collection read must get its own index"

      canonical = AshHateoas.Navigation.collection_href(AshHateoas.Test.MultiRead, [Domain])

      assert canonical == "/domain/multi_read",
             "Navigation must resolve the base collection, not a named sub-collection"
    end

    test "a collection read (get?: false) is a named index, not a member route" do
      route = route_for(AshHateoas.Test.MultiRead, :by_label)

      assert route.type == :index
      assert route.route == "/domain/multi_read/by_label"
    end

    test "a member read (get?: true) stays a member route under /:id" do
      route = route_for(AshHateoas.Test.MultiRead, :by_id)

      assert route.type == :get
      assert route.route == "/domain/multi_read/:id/by_id"
    end

    test "a non-primary read does not squat the collection path" do
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
      refute routed?(AshHateoas.Test.Derived, :unrouted_touch)
      refute routed?(AshHateoas.Test.Derived, :admin_only)
    end

    test "unrouting one action leaves its siblings routed" do
      assert routed?(AshHateoas.Test.Derived, :touch),
             ":touch differs from :unrouted_touch only by not being unrouted"

      assert routed?(AshHateoas.Test.Derived, :read)
    end

    test "an unrouted action is therefore not advertised" do
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

  describe "AshAuthentication's own actions are not routed" do
    @describetag :auth

    test "the subject resolver gets no route" do
      refute routed?(AshHateoas.Test.AuthUser, :get_by_subject)
    end

    test "sign-in and registration get no route" do
      refute routed?(AshHateoas.Test.AuthUser, :sign_in_with_password)
      refute routed?(AshHateoas.Test.AuthUser, :register_with_password)
    end

    test "the resource's own actions are still routed" do
      assert routed?(AshHateoas.Test.AuthUser, :read)
      assert routed?(AshHateoas.Test.AuthUser, :set_role)
    end

    test "a resource without AshAuthentication is unaffected" do
      assert routed?(AshHateoas.Test.AutoRouted, :read)
    end
  end

  describe "Reactor compensation actions are not routed" do
    test "an undo action taking a changeset gets no route" do
      refute routed?(AshHateoas.Test.Compensating, :undo_create)
    end

    test "its siblings are routed as usual" do
      assert routed?(AshHateoas.Test.Compensating, :create)
      assert routed?(AshHateoas.Test.Compensating, :read)
    end

    test "a destroy taking other arguments is still routed" do
      assert routed?(AshHateoas.Test.Compensating, :archive)
    end
  end

  describe "the base path is derived too" do
    test "a resource declaring no base gets /<domain>/<type>" do
      assert AshHateoas.Test.NoBase
             |> routes()
             |> Enum.map(& &1.route)
             |> Enum.all?(&String.starts_with?(&1, "/domain/no_base"))
    end

    test "the type is used verbatim, not pluralised" do
      collection =
        AshHateoas.Test.NoBase
        |> routes()
        |> Enum.find(&(&1.type == :index))

      assert collection.route == "/domain/no_base"
      refute collection.route =~ "no_bases"
    end

    test "a declared base still wins" do
      assert AshHateoas.Test.AutoRouted
             |> routes()
             |> Enum.all?(&String.starts_with?(&1.route, "/auto_routeds"))
    end

    test "the type is inferred from the module name when not declared" do
      # `AshHateoas.Test.NoBase` declares a `type`, but a resource that declares
      # none still gets one from its module's last segment, underscored.
      assert AshHateoas.Resource.Info.type(AshHateoas.Test.Compensating) == "compensating"
    end
  end

  describe "the assumed method is announced" do
    test "an undeclared generic action warns that POST was assumed" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule AshHateoasAssumedMethod#{System.unique_integer([:positive])} do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshHateoas.Resource]

            hateoas do
              type "assumed"
              base "/assumeds"
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
      # Scoped to this module's own output. `capture_io(:stderr, …)` captures
      # the group leader, so under `async: true` a module another file compiles
      # at the same moment writes into this capture too — and a `refute` reads
      # a neighbour's warning as a failure here. Latent rather than live (no
      # other runtime compile emits this phrase today), and one fixture away
      # from being live.
      name = "AshHateoasDeclaredMethod#{System.unique_integer([:positive])}"

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule #{name} do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshHateoas.Resource]

            hateoas do
              type "declared"
              base "/declareds"
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

      own =
        stderr
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, name))
        |> Enum.join("\n")

      refute own =~ "by assumption",
             "declaring the method must silence it, got: #{own}"
    end
  end

  describe "what is left alone" do
    test "an unrouted name that is not an action fails the build" do
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
