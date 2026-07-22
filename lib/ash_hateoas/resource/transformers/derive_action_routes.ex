defmodule AshHateoas.Resource.Transformers.DeriveActionRoutes do
  @moduledoc """
  Routes every action by default; `unrouted` is how an author opts one out.

  A resource declaring `defaults [:read, :create, :update, :destroy]` and an
  `update :publish` gets the five REST routes and `/:id/publish` without writing
  a `routes` block beyond its `base`. Only deviations are declared.

  ## The default this inverts

  Until now the package read routes and never wrote them, so an action reached
  the HTTP surface only once an author routed it. That allow-list has one
  property this deny-list gives up: under an allow-list, forgetting to think
  about an action yields a 404, and under a deny-list it yields a live endpoint.
  The failure is silent, and there is no diff showing it, because the omission
  is in a file nobody edited.

  That cost is real and is accepted here deliberately. What buys it back:

    * `unrouted :name` is verified against the action list, so a renamed action
      fails the build rather than quietly becoming routed again — the same
      contract `exclude`/`override` have (R2). This is the one check standing
      between a rename and silent publication.
    * Policies remain the actual gate. An action being routed is not an action
      being permitted, and `Ash.can?/3` still decides what any actor may invoke.

  Authors with actions that must never be reachable — ones called by a `change`
  module, ones trusting a pre-verified payload, bulk administrative ones —
  must now say so. Saying nothing publishes them.

  ## What it derives

  | action | route |
  |---|---|
  | primary read | `get` at `/:id` and `index` at `/` |
  | primary create | `post` at `/` |
  | primary update | `patch` at `/:id` |
  | primary destroy | `delete` at `/:id` |
  | any other action | its own name under `/:id/<name>` |

  Primaries get the REST verbs because "which read answers `GET /things`" has
  exactly one answer when one read is primary. Non-primaries do not: a resource
  with three updates has no canonical `PATCH /things/:id`, so each is addressed
  by name instead. This is the same reasoning
  `AshHateoas.Resource.Transformers.MarkPrimaryGet` applies to `primary?` —
  derive what is unambiguous, leave what is not.

  ## What it will not do

    * **An action the author already routed is left alone.** A declared route
      wins entirely, including its path and options. A partial `routes` block is
      a partial declaration, not an opt-out for the rest of the resource.
    * **An `unrouted` action gets nothing.**
    * **A resource with no `json_api` section is skipped**, having no routes
      path to write into.
    * **Embedded resources are skipped** — no routes, no identity, nothing to
      address.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  # Relationships and primary-action flags are populated by Ash's own
  # transformers, so reading before they run finds an incomplete picture —
  # silently, as an empty list rather than an error.
  @impl true
  def after?(module) do
    module |> Module.split() |> Enum.take(3) == ~w(Ash Resource Transformers)
  rescue
    _ -> false
  end

  # Before `ash_json_api`'s own, so derived routes are in place by the time it
  # prefixes and validates them.
  @impl true
  def before?(module) do
    module |> Module.split() |> Enum.take(2) == ~w(AshJsonApi Resource)
  rescue
    _ -> false
  end

  @impl true
  def transform(dsl_state) do
    if Transformer.get_persisted(dsl_state, :embedded?, false) do
      {:ok, dsl_state}
    else
      derive(dsl_state)
    end
  end

  defp derive(dsl_state) do
    skip = skipped(dsl_state)

    dsl_state
    |> Ash.Resource.Info.actions()
    |> Enum.reject(&(&1.name in skip))
    |> Enum.reduce(dsl_state, &add_routes(&2, &1, dsl_state))
    |> derive_base()
    |> persist_authored_generics(dsl_state)
    |> then(&{:ok, &1})
  rescue
    # A resource without ash_json_api has no such DSL path.
    _ -> {:ok, dsl_state}
  end

  # Which generic actions the AUTHOR routed by hand, recorded before this
  # transformer adds its own.
  #
  # `AshHateoas.Resource.Verifiers.VerifyActions` needs the distinction and
  # cannot recover it: verifiers run after transformers, and a derived generic
  # route is the same `:route` entity, carrying the same `:method` field, as a
  # hand-written one. By then "the author stated POST" and "we assumed POST"
  # look identical — and the verifier warns about exactly that difference.
  defp persist_authored_generics(dsl_state, original_dsl) do
    authored =
      original_dsl
      |> Transformer.get_entities([:json_api, :routes])
      |> Enum.filter(&Map.has_key?(&1, :method))
      |> Enum.map(& &1.action)
      |> Enum.reject(&is_nil/1)

    Transformer.persist(dsl_state, :ash_hateoas_authored_generic_routes, authored)
  rescue
    _ -> dsl_state
  end

  # `base` is the last thing an author would otherwise have to write, and both
  # halves of it are already declared: the domain's `short_name` and the
  # json_api `type`. `MyApp.Blog.Comment` with `type "comment"` becomes
  # `/blog/comment`.
  #
  # The type is used verbatim — NOT pluralised. ash#31 removed exactly this
  # guess across the framework in one decision: ash_postgres stopped guessing
  # table names and ash_json_api stopped guessing base routes, because
  # pluralisation is where the guessing lives. `person` -> `/persons`,
  # `status` -> `/statuss`, `category` -> `/categorys` are all wrong, and a
  # wrong base makes every URL for that resource wrong. URLs are public API and
  # cost more to correct than a table name.
  #
  # So the singular is deliberate, and `base` stays available for an author who
  # wants the conventional plural. Deriving `/blog/comment` from two declared
  # facts is reading declarations; deriving `/blog/comments` would be inventing
  # one, which is the line this package does not cross.
  defp derive_base(dsl_state) do
    with nil <- Transformer.get_option(dsl_state, [:json_api, :routes], :base),
         segment when is_binary(segment) <- base_segment(dsl_state) do
      Transformer.set_option(dsl_state, [:json_api, :routes], :base, segment)
    else
      _ -> dsl_state
    end
  end

  defp base_segment(dsl_state) do
    with type when is_binary(type) <- Transformer.get_option(dsl_state, [:json_api], :type),
         domain when not is_nil(domain) <- domain_short_name(dsl_state) do
      "/#{domain}/#{type}"
    else
      _ -> nil
    end
  end

  # A resource may have no domain at compile time (`domain: nil` with
  # `validate_domain_inclusion?: false` is a real pattern, and several fixtures
  # use it). Without one there is no namespace to derive, so the base is left
  # alone rather than half-derived.
  #
  # The name is taken from the MODULE, never by reading the domain's DSL.
  #
  # `Ash.Domain.Info.short_name/1` would be the obvious call and it deadlocks
  # the compiler: it reads a Spark option, which forces the domain module to
  # finish compiling, while the domain is itself blocked waiting on the
  # resources it lists. Every resource in a normal app fails with
  # "deadlocked waiting on module MyApp.Domain". The `rescue` here does not
  # save it either — the compiler raises a CompileError that is fatal by then.
  #
  # This cost real debugging time and did not show up in this package's own
  # tests, because the fixtures use `domain: nil`. It only appears when a
  # domain actually lists its resources, which is every real application.
  #
  # So: derive from the module name, which needs nothing compiled. That is the
  # same value `short_name` returns unless a domain declares one explicitly in
  # its `execution` block — rare, and not worth deadlocking every other app to
  # honour here. An author who does declare one can still set `base` by hand.
  defp domain_short_name(dsl_state) do
    case Transformer.get_persisted(dsl_state, :domain) do
      nil -> nil
      domain -> module_short_name(domain)
    end
  end

  # `MyApp.Library` -> "library". Mirrors `Ash.Domain.default_short_name/0`,
  # which is what `short_name` itself falls back to.
  defp module_short_name(domain) do
    domain
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  rescue
    _ -> nil
  end

  # Both halves of "leave it alone": what the author routed by hand, and what
  # they declared `unrouted`.
  defp skipped(dsl_state) do
    already_routed(dsl_state) ++ AshHateoas.Resource.Info.unrouted(dsl_state)
  end

  # Relationship routes are excluded deliberately. They carry `action: :read`
  # — the read used to fetch the source record — but they are a claim on an
  # edge, not on the resource's own REST surface. Counting them would make any
  # resource with a public relationship look as though its primary read were
  # hand-routed, and silently lose its `get` and `index`.
  #
  # `DeriveRelationshipRoutes` declares itself `after?` this transformer for the
  # same reason. This filter is what makes that ordering a belt-and-braces
  # detail rather than the only thing holding it up.
  @relationship_types [:get_related, :relationship]

  defp already_routed(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:json_api, :routes])
    |> Enum.reject(&(&1.type in @relationship_types))
    |> Enum.map(& &1.action)
    |> Enum.reject(&is_nil/1)
  end

  defp add_routes(dsl_state, action, original_dsl) do
    original_dsl
    |> route_specs(action)
    |> Enum.reduce(dsl_state, fn {type, opts}, acc ->
      case build_route(type, action.name, opts) do
        {:ok, route} -> Transformer.add_entity(acc, [:json_api, :routes], route)
        _ -> acc
      end
    end)
  end

  # `:route` is omitted for the primaries, not passed explicitly: each route
  # entity fills in its own conventional path (`/:id`, `/`) via its own
  # transform, and writing those here would duplicate a convention
  # `ash_json_api` owns and may change.
  defp route_specs(dsl_state, action) do
    cond do
      reactor_compensation?(action) -> []
      authentication_action?(dsl_state, action) -> []
      generic?(action) -> generic_specs(dsl_state, action)
      primary?(dsl_state, action) -> primary_specs(action.type)
      true -> [{non_primary_type(action.type), [route: "/:id/#{action.name}"]}]
    end
  end

  # An action AshAuthentication generated, rather than one the author wrote.
  # Two reasons, and they differ by action:
  #
  #   * `:get_by_subject` is guarded by a bypass on
  #     `AshAuthentication.Checks.AshAuthenticationInteraction`, which matches
  #     only when `private.ash_authentication?` is set on the context — and that
  #     "will only ever be set in code that is called internally by
  #     ash_authentication". An HTTP request never carries it, so the route
  #     would fall through to the remaining policies and deny. An endpoint that
  #     always 403s is an affordance no client can use.
  #
  #   * sign-in and registration ARE meant to be public, but AshAuthentication
  #     serves them through its own router, which handles the strategy phases,
  #     token issuance and failure semantics. A JSON:API route to the same
  #     action is a second path to the same capability that skips all of it.
  #
  # The list is read from AshAuthentication's own introspection, never guessed
  # from action names: `Strategy.actions/1` per configured strategy and add-on,
  # plus the configured subject-resolver name. An author who renames
  # `:sign_in_with_password` still gets it skipped.
  defp authentication_action?(dsl_state, action) do
    action.name in authentication_actions(dsl_state)
  end

  defp authentication_actions(dsl_state) do
    if Code.ensure_loaded?(AshAuthentication.Info) do
      strategy_actions(dsl_state) ++ subject_action(dsl_state)
    else
      []
    end
  rescue
    # A resource without the AshAuthentication extension has no such DSL path.
    _ -> []
  end

  # `Strategy.actions/1` returns PHASE names (`:register`, `:sign_in`), not the
  # resource action names (`:register_with_password`) — the phase is the step in
  # the auth flow, the action is what it calls. The action names live on the
  # strategy struct as `*_action_name` fields, and which fields exist differs
  # per strategy: password has `register_action_name`, `sign_in_action_name`
  # and `sign_in_with_token_action_name`; OAuth2 has its own set.
  #
  # So every `*_action_name` field is collected rather than any being named
  # here. A strategy this package has never heard of still gets its actions
  # skipped, and an author who renames one is still covered — the name is read,
  # not assumed.
  @action_name_suffix "_action_name"

  defp strategy_actions(dsl_state) do
    dsl_state
    |> AshAuthentication.Info.list_strategies()
    |> Enum.flat_map(fn strategy ->
      strategy
      |> Map.from_struct()
      |> Enum.filter(fn {key, value} ->
        is_atom(value) and value not in [nil, true, false] and
          String.ends_with?(to_string(key), @action_name_suffix)
      end)
      |> Enum.map(fn {_key, value} -> value end)
    end)
  rescue
    _ -> []
  end

  defp subject_action(dsl_state) do
    case AshAuthentication.Info.authentication_get_by_subject_action_name(dsl_state) do
      {:ok, name} -> [name]
      _ -> []
    end
  rescue
    _ -> []
  end

  # A Reactor compensation action — the `undo_action` of a `create` or `update`
  # step. Ash requires exactly this shape and enforces it at compile time:
  # `Ash.Reactor.Builders.Create.verify_action_takes_changeset/3` matches
  # `%{arguments: [%{name: :changeset}]}` and errors on anything else. Reactor
  # hands the undo the changeset that made the row, not the record.
  #
  # So no HTTP caller can construct a request for one: an `Ash.Changeset` is a
  # struct with functions and internal state, not something expressible in a
  # JSON body. A derived route here would be an affordance that raises when a
  # client follows it, which is worse than no affordance — the same reasoning
  # that skips to-one relationship routes in `DeriveRelationshipRoutes`.
  #
  # This is read, not declared: the shape IS the fact, so an author does not
  # restate it with `unrouted`. The pattern is deliberately as narrow as Ash's
  # own — a single argument, named `changeset`. A destroy taking other
  # arguments is an ordinary endpoint and stays routed.
  defp reactor_compensation?(%{arguments: [%{name: :changeset}]}), do: true
  defp reactor_compensation?(_action), do: false

  # Generic actions route through `ash_json_api`'s `:route` entity rather than a
  # verb entity. Two things follow from that, both of which make this the right
  # target rather than a workaround:
  #
  #   * `:route` takes the method as data, so one entity covers every verb.
  #   * it is exempt from the return-type check the verb entities apply. `get`,
  #     `index` and `post` require a generic action to return the resource
  #     struct, because they serialize the result as a resource object; `:route`
  #     has its own controller and renders whatever the action returns, wrapped
  #     via `wrap_in_result?` when it is not a resource.
  #
  # So `action :tally, :boolean` is routable, and `returns` needs no inspection.
  #
  # The method is the one fact not declared anywhere — a generic action is an
  # escape hatch and says nothing about whether it mutates. POST is the default
  # because it understates nothing: a client may not cache it or retry it
  # blindly. An author who knows better says so with `method :tally, :get`.
  defp generic_specs(dsl_state, action) do
    method = AshHateoas.Resource.Info.method(dsl_state, action.name) || :post

    [
      {:route,
       [
         method: method,
         route: "/:id/#{action.name}",
         wrap_in_result?: true
       ]}
    ]
  end

  defp generic?(%{type: :action}), do: true
  defp generic?(_action), do: false

  # The primary read is the one action yielding two routes: the member and the
  # collection are both canonically it. `primary?: true` on the `get` is what
  # makes records carry a `self` link — see `MarkPrimaryGet`, whose job this
  # subsumes for derived routes.
  defp primary_specs(:read), do: [{:get, [primary?: true]}, {:index, []}]
  defp primary_specs(:create), do: [{:post, []}]
  defp primary_specs(:update), do: [{:patch, []}]
  defp primary_specs(:destroy), do: [{:delete, []}]
  defp primary_specs(_other), do: []

  # A generic action is neither a read nor a write as far as Ash is concerned,
  # but it has to be reachable by *some* verb. POST is the honest default: it is
  # not safe and not idempotent, which is what "arbitrary action" means over
  # HTTP.
  defp non_primary_type(:read), do: :index
  defp non_primary_type(:create), do: :post
  defp non_primary_type(:update), do: :patch
  defp non_primary_type(:destroy), do: :delete
  defp non_primary_type(_generic), do: :post

  # Generic actions have no `primary?` field at all, hence the Map.get rather
  # than a struct access — reading `.primary?` on one raises.
  defp primary?(_dsl_state, action), do: Map.get(action, :primary?, false)

  defp build_route(type, action, opts) do
    Transformer.build_entity(
      AshJsonApi.Resource,
      [:json_api, :routes],
      type,
      Keyword.merge([action: action], opts)
    )
  end
end
