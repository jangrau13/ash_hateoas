defmodule AshHateoas.Resource.Transformers.DeriveActionRoutes do
  @moduledoc """
  Routes every action by default; `unrouted` is how an author opts one out.

  A resource declaring `defaults [:read, :create, :update, :destroy]` and an
  `update :publish` gets the five REST routes and `/:id/publish` without writing
  any routes by hand — it declares a `type` (or lets one be inferred from its
  module name) and nothing else.

  Routes are `AshHateoas.Route` structs persisted under the `ash_hateoas`-owned
  key `:ash_hateoas_routes`. Owning the route model is what lets the package
  serve Hydra directly.

  ## A deny-list, not an allow-list

  Every action is routed by default, and `unrouted` opts one out. That deny-list
  has one property an allow-list would not give up: under an allow-list,
  forgetting to think about an action yields a 404, and under a deny-list it
  yields a live endpoint. The failure is silent, and there is no diff showing
  it, because the omission is in a file nobody edited.

  That cost is real and is accepted here deliberately. What buys it back:

    * `unrouted :name` is verified against the action list, so a renamed action
      fails the build rather than quietly becoming routed again — the same
      contract `exclude`/`override` have. This is the one check standing
      between a rename and silent publication.
    * Policies remain the actual gate. An action being routed is not an action
      being permitted, and `Ash.can?/3` still decides what any actor may invoke.

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

    * **An `unrouted` action gets nothing.**
    * **Ash embedded *types* are skipped** — a value type has no identity, so
      no IRI, so nothing to address and nothing to link to.
  """

  use Spark.Dsl.Transformer

  alias AshHateoas.Route
  alias Spark.Dsl.Transformer

  @persisted_routes_key :ash_hateoas_routes

  # Relationships and primary-action flags are populated by Ash's own
  # transformers, so reading before they run finds an incomplete picture —
  # silently, as an empty list rather than an error.
  @impl true
  def after?(module) do
    module |> Module.split() |> Enum.take(3) == ~w(Ash Resource Transformers)
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

    routes =
      dsl_state
      |> Ash.Resource.Info.actions()
      |> Enum.reject(&(&1.name in skip))
      |> Enum.flat_map(&build_routes(dsl_state, &1))

    {:ok, Transformer.persist(dsl_state, @persisted_routes_key, routes)}
  rescue
    _ -> {:ok, dsl_state}
  end

  # The base path, from two declared facts: the domain's short name and the
  # resource's `type`. `MyApp.Blog.Comment` with `type "comment"` becomes
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
  # An author who wants the conventional plural declares `base` by hand.
  defp base(dsl_state) do
    with nil <- AshHateoas.Resource.Info.base(dsl_state),
         type when is_binary(type) <- AshHateoas.Resource.Info.type(dsl_state),
         domain when is_binary(domain) <- domain_short_name(dsl_state) do
      "#{owner_prefix(dsl_state, domain)}/#{type}"
    else
      declared when is_binary(declared) -> declared
      _ -> nil
    end
  end

  # What an owned resource's routes hang off: the owner's own base plus its id.
  #
  #     /blog/comment            without an owner
  #     /blog/document/:document_id/comment    owned by :document
  #
  # The owner's id is named after the relationship rather than called `:id`,
  # because a nested path has two and `:id` is the record's own. Which is which
  # has to survive into `capture_id/2`, and a second bare `:id` would make that
  # unrecoverable.
  #
  # ## Derived from the module name, never by reading the owner's DSL
  #
  # The same constraint `domain_short_name/1` documents below, and the same
  # reason — but sharper here, and found by hitting it. `Info.type/1` looks in
  # the DSL before falling back to the module name, and that first step **forces
  # the owner module to finish compiling**. When the owner also points back
  # (a `has_many` to its children, which an owner usually has) the two wait on
  # each other and the compiler reports a deadlock:
  #
  #     model.ex            => ElementResource
  #     element_resource.ex => Model
  #
  # `Info.module_type/1` reads only `Module.split/1`, so it needs nothing
  # compiled. The cost is that an owner **declaring** a `type` or `base`
  # different from its module name is not honoured in its children's paths.
  # That is a real limitation and the alternative is deadlocking every app that
  # nests.
  defp owner_prefix(dsl_state, domain) do
    with %{name: name, destination: destination} <- AshHateoas.Resource.Info.owner(dsl_state),
         owner_type when is_binary(owner_type) <-
           AshHateoas.Resource.Info.module_type(destination) do
      "/#{domain}/#{owner_type}/:#{name}_id"
    else
      _ -> "/#{domain}"
    end
  end

  # A resource may have no domain at compile time (`domain: nil` with
  # `validate_domain_inclusion?: false` is a real pattern, and several fixtures
  # use it). Without one there is no namespace to derive, so the base is left
  # nil rather than half-derived.
  #
  # The name is taken from the MODULE, never by reading the domain's DSL.
  #
  # `Ash.Domain.Info.short_name/1` would be the obvious call and it deadlocks
  # the compiler: it reads a Spark option, which forces the domain module to
  # finish compiling, while the domain is itself blocked waiting on the
  # resources it lists. So the name comes from the module, which needs nothing
  # compiled — the same value `short_name` returns unless a domain declares one
  # explicitly, which is rare and not worth deadlocking every other app for.
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

  defp skipped(dsl_state) do
    AshHateoas.Resource.Info.unrouted(dsl_state)
  end

  defp build_routes(dsl_state, action) do
    base = base(dsl_state)

    dsl_state
    |> route_specs(action)
    |> Enum.map(fn {type, opts} ->
      %Route{
        type: type,
        action: action.name,
        method: opts[:method],
        route: prepend(base, opts[:route]),
        primary?: Keyword.get(opts, :primary?, false)
      }
    end)
  end

  # Non-primary routes carry an explicit sub-path; primaries carry the
  # conventional member/collection paths, which this transformer owns.
  defp route_specs(dsl_state, action) do
    cond do
      reactor_compensation?(action) -> []
      authentication_action?(dsl_state, action) -> []
      generic?(action) -> generic_specs(dsl_state, action)
      primary?(dsl_state, action) -> primary_specs(action.type)
      collection_read?(action) -> [{:index, [route: "/#{action.name}"]}]
      true -> [{non_primary_type(action.type), [route: "/:id/#{action.name}"]}]
    end
  end

  # A non-primary read that returns a COLLECTION, not a member.
  #
  # `/:id/<name>` is right for a read scoped to one record — a variant `get`
  # that loads more, filters to the actor's own, and so on. It is wrong for a
  # read that searches or lists the whole type: there is no `:id` to supply, so
  # the derived route is unreachable, and the action is a collection operation
  # wearing a member's URL.
  #
  # `get?` is the exact signal, and Ash defines it for this: "expresses that
  # this action innately only returns a single result". A read that is NOT
  # `get?` returns many, so it belongs at the collection as an `:index` at
  # `/<name>` — where its public arguments arrive as query params, which is also
  # what makes it advertise as a COLLECTION affordance. A `get?` read keeps
  # `/:id/<name>`.
  #
  # `AshHateoas.Navigation` treats the base-path index as the canonical
  # collection, so the named ones do not shadow it.
  defp collection_read?(%{type: :read} = action), do: not Map.get(action, :get?, false)
  defp collection_read?(_action), do: false

  # An action AshAuthentication generated, rather than one the author wrote.
  # `:get_by_subject` is guarded by a bypass that only matches in-process calls,
  # so an HTTP route would always deny; sign-in and registration are served by
  # AshAuthentication's own router. The list is read from AshAuthentication's
  # introspection, never guessed from action names.
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
    _ -> []
  end

  # `Strategy.actions/1` returns PHASE names, not resource action names — the
  # action names live on the strategy struct as `*_action_name` fields, and
  # which exist differs per strategy. So every `*_action_name` field is
  # collected rather than any being named here.
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
    # `authentication_get_by_subject_action_name/1` is typed to return
    # `{:ok, name}`, so only that clause is matched. The `rescue` still guards
    # the runtime case where the function is unavailable (no AshAuthentication)
    # or raises — which the type checker does not model.
    {:ok, name} = AshAuthentication.Info.authentication_get_by_subject_action_name(dsl_state)
    [name]
  rescue
    _ -> []
  end

  # A Reactor compensation action — the `undo_action` of a `create`/`update`
  # step. Ash requires it to take a single `changeset` argument, which no HTTP
  # caller can construct, so a derived route would raise when followed. The
  # shape IS the fact, so an author does not restate it with `unrouted`.
  defp reactor_compensation?(%{arguments: [%{name: :changeset}]}), do: true
  defp reactor_compensation?(_action), do: false

  # Generic actions carry their method as data (there is no verb entity), and
  # the method is the one fact not declared anywhere — a generic action says
  # nothing about whether it mutates. POST is the default because it understates
  # nothing. An author who knows better says so with `method :tally, :get`.
  defp generic_specs(dsl_state, action) do
    method = AshHateoas.Resource.Info.method(dsl_state, action.name) || :post

    [{:route, [method: method, route: "/:id/#{action.name}"]}]
  end

  defp generic?(%{type: :action}), do: true
  defp generic?(_action), do: false

  # The primary read is the one action yielding two routes: the member `/:id`
  # and the collection `/`. `primary?: true` on the `get` marks the canonical
  # record URL a client uses as a node `@id`.
  defp primary_specs(:read),
    do: [{:get, [route: "/:id", primary?: true]}, {:index, [route: "/"]}]

  defp primary_specs(:create), do: [{:post, [route: "/"]}]
  defp primary_specs(:update), do: [{:patch, [route: "/:id"]}]
  defp primary_specs(:destroy), do: [{:delete, [route: "/:id"]}]
  defp primary_specs(_other), do: []

  # This handles the `get?: true` read — one scoped to a single record, which
  # `collection_read?` has already separated out. Such a read belongs at
  # `/:id/<name>` as a `:get`, NOT an `:index`: `index` means "the collection",
  # and navigation reads a type's index route to find its collection URL.
  defp non_primary_type(:read), do: :get
  defp non_primary_type(:create), do: :post
  defp non_primary_type(:update), do: :patch
  defp non_primary_type(:destroy), do: :delete
  defp non_primary_type(_generic), do: :post

  # Generic actions have no `primary?` field at all, hence the Map.get rather
  # than a struct access — reading `.primary?` on one raises.
  defp primary?(_dsl_state, action), do: Map.get(action, :primary?, false)

  # Every route path is base-qualified here, at derivation time, so readers do
  # not have to re-join. A resource with no derivable base keeps the bare path,
  # which is still followable when the whole API is mounted at the root.
  defp prepend(nil, path), do: path
  defp prepend(_base, nil), do: nil
  defp prepend(base, "/"), do: base
  defp prepend(base, path), do: base <> path
end
