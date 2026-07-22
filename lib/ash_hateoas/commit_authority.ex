defmodule AshHateoas.CommitAuthority do
  @moduledoc """
  Decides whether an actor's invocations take effect (R10).

  Ash treats actors as opaque — a struct, a token, a map, whatever the host puts
  there — so this package MUST NOT inspect one. Inspecting would mean guessing
  at a field, and an actor shape the guess does not recognise reads as "commits"
  and the write proceeds. Silent fail-open is unacceptable on an enforcement
  surface, so the question is asked of a module instead.

  Named for what the endpoint branches on, not for what the actor is: this
  package holds no definition of "agent", and the same answer serves sandboxes,
  service accounts and scripted humans.

  ## Configuration

  One module, application-wide. It describes the deployment's authentication,
  and a deployment has one of those — two domains disagreeing about whether the
  same actor commits has no coherent meaning, so the choice is not offered.

      config :ash_hateoas, commit_authority: AshHateoas.CommitAuthority.ApiKey

  Unconfigured, `AshHateoas.CommitAuthority.Always` answers `true` for every
  actor, so `not_delegable` is documentation and no endpoint behaviour changes.
  That is the default deliberately: affordances are a contract and default on
  (R8), but this changes what an endpoint *does*.

  ## Failure is closed

  `AshHateoas.Gate.Authorization` logs and drops an affordance when a policy
  raises, justified because affordances are advisory (R7). This is an
  **enforcement** decision, so it inverts that posture: an exception means "does
  not commit", logged loudly. Failing open here is an unapproved write; failing
  closed is an unnecessary escalation.
  """

  @doc """
  Whether this actor's invocations take effect.

  `false` means an action declared `not_delegable` is refused for this actor.
  It says nothing about authorization — that is `Ash.can?/3`'s answer, and it
  has already been given by the time this is asked.
  """
  @callback commits?(actor :: term()) :: boolean()

  require Logger

  @default AshHateoas.CommitAuthority.Always

  @doc """
  The configured module, or the always-commits default.
  """
  @spec module() :: module()
  def module do
    Application.get_env(:ash_hateoas, :commit_authority, @default)
  end

  @doc """
  Ask the configured authority whether `actor` commits.

  Fails closed: any exception is logged with context and answered `false`.
  """
  @spec commits?(term()) :: boolean()
  def commits?(actor) do
    case module().commits?(actor) do
      true ->
        true

      false ->
        false

      other ->
        Logger.error("""
        [ash_hateoas] #{inspect(module())}.commits?/1 returned a non-boolean; \
        treating the actor as non-committing.

          returned: #{inspect(other)}
          actor:    #{inspect(actor)}
        """)

        false
    end
  rescue
    exception ->
      Logger.error("""
      [ash_hateoas] #{inspect(module())}.commits?/1 raised; treating the actor \
      as non-committing (R10 fails closed).

        actor: #{inspect(actor)}

      #{Exception.format(:error, exception, __STACKTRACE__)}
      """)

      false
  end
end
