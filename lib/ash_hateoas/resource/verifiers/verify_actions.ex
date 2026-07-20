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
      :ok
    end
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
end
