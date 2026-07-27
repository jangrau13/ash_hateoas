defmodule AshHateoas.Resource.Verifiers.VerifyActions do
  @moduledoc """
  Compile-time checks for the `hateoas` and `agentic_hateoas` sections (R2, R10).

  Two things are verified:

    * every entry in either section names an action that exists — a renamed
      action should fail the build, not silently stop being excluded. This also
      protects the backbone, since `Ash.can?/3` raises `ArgumentError` on an
      unknown action rather than returning false. For `not_delegable` the stake
      is higher: a silently dropped entry republishes the action to delegated
      credentials.

    * a resource carrying the extension declares authorizers. Without them
      `Ash.can?/3` short-circuits to `true` before evaluating anything, so every
      routed action is advertised to every actor — including anonymous ones.
      That is correct Ash semantics (no policies means no restrictions), so this
      **warns** rather than failing: a resource may legitimately be public.
      Silence it with `warn_on_missing_authorizers? false`.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)

    with :ok <- verify_action_names(dsl_state, module) do
      warn_on_missing_authorizers(dsl_state, module)
      warn_on_unaddressable_records(dsl_state, module)
      warn_on_assumed_methods(dsl_state, module)
      warn_on_ambiguous_collection(dsl_state, module)
      warn_on_inert_not_delegable(dsl_state, module)
      :ok
    end
  end

  # `not_delegable` does nothing until a commit authority says some credential
  # does not commit. Unconfigured, the default answers true for everyone and the
  # declaration is documentation — which is a defensible state to ship in, but
  # not one to arrive at by accident on a control an author believes is enforcing
  # something.
  #
  # Warns rather than fails: config is a deployment concern and may legitimately
  # be absent at compile time, in a library or in a test build.
  defp warn_on_inert_not_delegable(dsl_state, module) do
    declared = AshHateoas.Resource.Info.not_delegable(dsl_state)

    if declared != [] and is_nil(Application.get_env(:ash_hateoas, :commit_authority)) do
      IO.warn(
        """
        #{inspect(module)} declares #{Enum.map_join(declared, ", ", &"`not_delegable :#{&1}`")}, \
        but no commit authority is configured.

        Every credential commits by default, so these actions are advertised
        with the flag and executed by anyone authorized — the declaration is
        documentation only.

        To enforce it:

            config :ash_hateoas, commit_authority: AshHateoas.CommitAuthority.ApiKey
        """,
        Macro.Env.stacktrace(__ENV__)
      )
    end

    :ok
  end

  # `AshHateoas.Navigation` resolves a type's collection URL — and whether the
  # type appears in the root document at all — from its `index` route.
  #
  # Several indexes is now NORMAL, not a smell: a collection read (`get?:
  # false`) legitimately derives its own `:index` at `/<name>`, so a resource
  # with `search`/`recent`/`by_region` carries one canonical index at the base
  # plus one per named read. `Navigation.index_route/2` disambiguates by path —
  # the canonical collection is the one whose route does NOT end in its action
  # name — so navigation is deterministic, not order-dependent.
  #
  # What still breaks R9 is having no resolvable canonical index: zero base-path
  # indexes, or two of them (which would be an author hand-declaring a second
  # `index` at the base). Then `Navigation` cannot name the collection and the
  # type can drop out of the root document — reachable by URL, unreachable by
  # following links. THAT is what this warns about, and only that.
  #
  # Warns rather than fails: it is a navigation ambiguity the author can resolve
  # by giving one index the base path, not an illegal declaration to reject.
  defp warn_on_ambiguous_collection(dsl_state, module) do
    indexes = routes_of_type(dsl_state, :index)
    canonical = Enum.filter(indexes, &base_path_index?/1)

    if indexes != [] and length(canonical) != 1 do
      IO.warn(
        """
        #{inspect(module)} has #{length(indexes)} `index` routes and #{length(canonical)} at the collection base, but navigation needs exactly one base index.

        Routes: #{Enum.map_join(indexes, ", ", &"#{&1.route} (:#{&1.action})")}

        `AshHateoas.Navigation` names a type's collection — and decides whether
        the type appears in the root document at all — from the index route at
        the base path (the one whose path does not end in its own action name).
        Named collection reads (`get?: false`) each get their own index at
        `/<name>` and are fine; what is missing here is a single canonical index
        at the base.

        Give the primary read its base index (the usual case, derived
        automatically), or if you hand-declared indexes, ensure exactly one sits
        at the collection base.
        """,
        []
      )
    end

    :ok
  end

  # The base collection index — its route ends at the resource base, not in a
  # named `/<action>` segment. Mirrors `AshHateoas.Navigation.canonical_index?/1`;
  # kept local so the verifier does not reach into Navigation's privates.
  defp base_path_index?(%{route: route, action: action}) when is_atom(action) do
    not String.ends_with?(route, "/#{action}")
  end

  defp base_path_index?(_route), do: true

  # A generic action IS routed like any other — `ash_json_api`'s `:route` entity
  # takes the method as data and applies no return-type check, so `action
  # :tally, :boolean` routes fine at `/:id/tally`.
  #
  # What cannot be derived is the verb. Every other action kind announces its
  # HTTP semantics by its type; a generic action announces nothing, because
  # being an escape hatch is the point of it. POST is assumed since it
  # understates nothing, but a generic action that only reads is then advertised
  # as unsafe and uncacheable — wrong, and invisible unless said out loud.
  #
  # So the warning marks an assumption, not a failure. Silence it by confirming
  # the verb either way: `method :tally, :post` is as good an answer as `:get`.
  #
  # A hand-declared route counts as confirming it. `route :post, "/acquire",
  # :acquire` states the verb as plainly as `method :acquire, :post` does, so
  # nothing is being assumed. Warning anyway would tell an author who HAS said
  # which verb to say it a second time, somewhere else — two places holding one
  # fact, free to disagree. That is what R1 exists to avoid, and this case is
  # unambiguous: the route says POST.
  defp warn_on_assumed_methods(dsl_state, module) do
    confirmed =
      declared_methods(dsl_state) ++
        routed_generic_actions(dsl_state) ++
        AshHateoas.Resource.Info.unrouted(dsl_state)

    dsl_state
    |> Ash.Resource.Info.actions()
    |> Enum.filter(&(&1.type == :action))
    |> Enum.reject(&(&1.name in confirmed))
    |> Enum.each(&warn_assumed_method(&1, module))

    :ok
  end

  # Recorded by `DeriveActionRoutes` before it added any routes of its own.
  #
  # Reading the route entities here instead would not work: by the time a
  # verifier runs, a derived generic route is indistinguishable from a declared
  # one — same entity, same `:method` field — so every generic action would
  # look declared and the warning would never fire.
  defp routed_generic_actions(dsl_state) do
    Verifier.get_persisted(dsl_state, :ash_hateoas_authored_generic_routes, [])
  end

  defp warn_assumed_method(action, module) do
    IO.warn(
      """
      #{inspect(module)} routes the generic action `:#{action.name}` as POST, by assumption.

      Generic actions declare no HTTP semantics — nothing in `action
      :#{action.name}, ...` says whether it reads or writes — so the method cannot be
      derived the way it can for a read, create, update or destroy. POST is
      assumed because it understates nothing.

      If it only reads, POST advertises it as unsafe and uncacheable:

          hateoas do
            method :#{action.name}, :get
          end

      If POST is right, say so and this warning stops:

          hateoas do
            method :#{action.name}, :post
          end
      """,
      []
    )
  end

  defp declared_methods(dsl_state) do
    dsl_state
    |> AshHateoas.Resource.Info.hateoas()
    |> Enum.filter(&match?(%AshHateoas.Resource.Method{}, &1))
    |> Enum.map(& &1.action)
  end

  # `ash_json_api` emits a record's `self` link from the `:get` route marked
  # `primary?` — "the route that should be linked to by default when rendering
  # links to this type of route". With none marked, the lookup returns nil and
  # no `self` is emitted.
  #
  # The record is then reachable by URL but carries no link to that URL. A
  # client told to follow links and construct nothing (R9) cannot name it: it
  # appears in a collection as data that can be read but never referred to, and
  # every affordance on it points at a record the client has no way to address.
  #
  # Warns rather than fails: several `:get` routes with none primary is a real
  # authorial choice, and a resource may legitimately not be addressable alone.
  # Marking SEVERAL is the mirror failure, and it is the quieter one. Ash
  # rejects two actions of a type both `primary?`, but that is a check on
  # actions, not on routes — two `get` ROUTES both marked compile silently.
  # `ash_json_api` then picks one by no rule the author controls, so a record's
  # canonical URL depends on route ordering and can change under an edit that
  # touched neither route.
  defp warn_on_unaddressable_records(dsl_state, module) do
    gets = get_routes(dsl_state)
    primaries = Enum.filter(gets, & &1.primary?)

    cond do
      gets == [] -> :ok
      primaries == [] -> warn_no_primary_get(gets, module)
      length(primaries) > 1 -> warn_several_primary_gets(primaries, module)
      true -> :ok
    end

    :ok
  end

  defp warn_no_primary_get(gets, module) do
    IO.warn(
      """
      #{inspect(module)} declares #{length(gets)} `get` route(s) but marks none `primary?`.

      `ash_json_api` renders a record's `self` link from the primary `get`
      route, so records of this type are serialized without one. A hypermedia
      client cannot address them: it is told what it may do with a record but
      has no URL to name it by.

      Mark the canonical one:

          routes do
            get :read, primary?: true
          end
      """,
      []
    )
  end

  defp warn_several_primary_gets(primaries, module) do
    IO.warn(
      """
      #{inspect(module)} marks #{length(primaries)} `get` routes `primary?`, but only one can be.

      Routes: #{Enum.map_join(primaries, ", ", &"#{&1.route} (:#{&1.action})")}

      `ash_json_api` renders a record's `self` link from the primary `get`
      route. With several, it takes one by no rule an author controls — so the
      canonical URL for a record is whichever happens to come first, and it can
      change under an edit that touched neither route.

      Note Ash's own check does not cover this: it rejects two ACTIONS of a
      type marked `primary?`, which is a different thing from two ROUTES.

      Mark exactly one, and leave the others unmarked.
      """,
      []
    )
  end

  defp get_routes(dsl_state), do: routes_of_type(dsl_state, :get)

  defp routes_of_type(dsl_state, type) do
    dsl_state
    |> AshHateoas.Resource.Info.routes()
    |> Enum.filter(&(&1.type == type))
  rescue
    _ -> []
  end

  # RETURNS {:error, _} rather than raising. Spark degrades an error raised
  # inside a verifier into a stderr warning, which would let a bogus `exclude`
  # compile successfully — exactly what R2 says must not happen. Returning it
  # makes the build fail, and lets `Spark.Test.dsl_errors/1` observe it as data.
  defp verify_action_names(dsl_state, module) do
    action_names =
      dsl_state
      |> Ash.Resource.Info.actions()
      |> MapSet.new(& &1.name)

    # Both sections are checked. A renamed action silently losing its
    # `not_delegable` would republish it to delegated credentials, which is a
    # safety regression rather than a cosmetic one.
    [
      {:hateoas, AshHateoas.Resource.Info.hateoas(dsl_state)},
      {:agentic_hateoas, AshHateoas.Resource.Info.agentic_hateoas(dsl_state)}
    ]
    |> Enum.find_value(fn {section, entities} ->
      case Enum.find(entities, &(not MapSet.member?(action_names, &1.action))) do
        nil -> nil
        entity -> {:error, unknown_action_error(entity, section, module, action_names)}
      end
    end)
    |> Kernel.||(:ok)
  end

  defp unknown_action_error(entity, section, module, action_names) do
    Spark.Error.DslError.exception(
      module: module,
      path: [section, entity_name(entity), entity.action],
      message: """
      `#{entity_name(entity)} :#{entity.action}` names an action that does not exist on #{inspect(module)}.

      Known actions: #{action_names |> Enum.sort() |> Enum.map_join(", ", &":#{&1}")}

      If the action was renamed, update this entry. If it was removed, delete
      this entry — leaving it would silently stop having any effect.
      """
    )
  end

  defp warn_on_missing_authorizers(dsl_state, module) do
    if warn?(dsl_state) and Ash.Resource.Info.authorizers(dsl_state) == [] do
      IO.warn(
        """
        #{inspect(module)} carries AshHateoas.Resource but declares no authorizers.

        `Ash.can?/3` returns true without evaluating anything when a resource has
        no authorizers, so EVERY routed action — including :destroy — will be
        advertised to every actor, including anonymous ones.

        That is correct Ash semantics: no policies means no restrictions. But on
        a hypermedia surface it is rarely what an author intends.

        Either add policies:

            use Ash.Resource, authorizers: [Ash.Policy.Authorizer]

        or, if the resource is deliberately public, silence this:

            hateoas do
              warn_on_missing_authorizers? false
            end
        """,
        []
      )
    end

    :ok
  end

  defp warn?(dsl_state) do
    AshHateoas.Resource.Info.hateoas_warn_on_missing_authorizers?(dsl_state)
  end

  defp entity_name(%AshHateoas.Resource.Exclusion{}), do: :exclude
  defp entity_name(%AshHateoas.Resource.Override{}), do: :override
  defp entity_name(%AshHateoas.Resource.Unrouted{}), do: :unrouted
  defp entity_name(%AshHateoas.Resource.Method{}), do: :method
  defp entity_name(%AshHateoas.Resource.NotDelegable{}), do: :not_delegable
end
