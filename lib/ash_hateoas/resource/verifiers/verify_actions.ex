defmodule AshHateoas.Resource.Verifiers.VerifyActions do
  @moduledoc """
  Compile-time checks for the `hateoas` section (R2).

  Two things are verified:

    * every `exclude` and `override` names an action that exists — a renamed
      action should fail the build, not silently stop being excluded. This also
      protects the backbone, since `Ash.can?/3` raises `ArgumentError` on an
      unknown action rather than returning false.

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
      :ok
    end
  end

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
  defp warn_on_unaddressable_records(dsl_state, module) do
    gets = get_routes(dsl_state)

    if gets != [] and not Enum.any?(gets, & &1.primary?) do
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

    :ok
  end

  defp get_routes(dsl_state) do
    if Code.ensure_loaded?(AshJsonApi.Resource.Info) do
      dsl_state
      |> AshJsonApi.Resource.Info.routes([])
      |> Enum.filter(&(&1.type == :get))
    else
      []
    end
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

    dsl_state
    |> AshHateoas.Resource.Info.hateoas()
    |> Enum.find(&(not MapSet.member?(action_names, &1.action)))
    |> case do
      nil -> :ok
      entity -> {:error, unknown_action_error(entity, module, action_names)}
    end
  end

  defp unknown_action_error(entity, module, action_names) do
    Spark.Error.DslError.exception(
      module: module,
      path: [:hateoas, entity_name(entity), entity.action],
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
end
