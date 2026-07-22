defmodule AshHateoas.Resource.Changes.EnforceNotDelegable do
  @moduledoc """
  Refuses a `not_delegable` action for a credential that does not commit (R10).

  Installed automatically by
  `AshHateoas.Resource.Transformers.EnforceNotDelegable` on every action the
  `agentic_hateoas` section names. It is not written by hand.

  ## Why a change and not a plug

  Enforcing in the transport would cover JSON:API and nothing else, and §5.2
  says other transports build against the profile — so a consumer invoking
  through `Ash.update/2` would have bypassed it. A change runs inside Ash, so
  every caller is refused identically, whatever the transport.

  It also keeps R6 intact. `Ash.can?/3` still answers `true`, so the affordance
  is still advertised and still carries its flag; advertisement and enforcement
  do not diverge into two implementations of one rule.

  ## It rejects before anything runs

  The refusal is added to the changeset directly, so the action is invalid
  before `before_action` and never reaches the data layer. Rejecting later —
  from `after_action`, say — would fire every side effect the action performs
  and *then* refuse, which is the failure this whole feature exists to prevent.

  ## The projection is computed only on refusal

  Building it re-runs the gate chain (`AshHateoas.Projection`), so it is
  deliberately computed after the decision to refuse, never before. A committing
  actor pays nothing.

  ## Re-entrancy

  The projection is where the loop hides. Building it calls the backbone, whose
  authorization gate calls `Ash.can?/3`, which builds a changeset for this very
  action — running this change again, which projects again, without bound.

  A process flag set for the duration of the projection makes those inner
  changesets pass through untouched. They are hypothetical and must never be
  refused: `Ash.can?/3` is asking whether the action is *permitted*, which it
  is, and answering "no" there would drop the affordance from the very set being
  described (R6).
  """

  use Ash.Resource.Change

  # Set while the projection runs, so the changesets `Ash.can?/3` builds during
  # it do not re-enter this change. Without it the recursion is unbounded:
  # refuse -> project -> affordances -> Ash.can?/3 -> changeset -> refuse.
  @projecting :"$ash_hateoas_projecting"

  @impl true
  def change(changeset, _opts, context) do
    cond do
      Process.get(@projecting) ->
        changeset

      AshHateoas.CommitAuthority.commits?(context.actor) ->
        changeset

      true ->
        Ash.Changeset.add_error(changeset, refusal(changeset, context))
    end
  end

  # An atomic action would run its update as an expression without calling
  # `change/3`, so the refusal would never happen. Declining atomicity forces
  # the non-atomic path, where `change/3` sees the actor and can refuse.
  #
  # The cost is that a `not_delegable` action cannot run atomically. That is
  # acceptable: the declaration is rare, deliberate, and on exactly the actions
  # where a correct refusal matters more than a single-statement update.
  @impl true
  def atomic(_changeset, _opts, _context) do
    {:not_atomic, "#{inspect(__MODULE__)} must see the actor to decide whether it commits (R10)"}
  end

  defp refusal(changeset, context) do
    AshHateoas.Error.NotDelegable.exception(
      resource: changeset.resource,
      action: changeset.action.name,
      actor: context.actor,
      deltas: deltas(changeset, context)
    )
  end

  # A record is needed to project from, and a create has none — there is no
  # current state to transition out of, so there is nothing to project.
  defp deltas(%{data: nil}, _context), do: []

  defp deltas(changeset, context) do
    Process.put(@projecting, true)

    AshHateoas.Projection.deltas(
      changeset.resource,
      changeset.data,
      context.actor,
      changeset.action.name,
      domain: changeset.domain,
      tenant: changeset.tenant
    )
  rescue
    # The refusal matters more than its explanation: a projection that cannot be
    # built must not turn a clean 403 into a 500.
    _ -> []
  after
    Process.delete(@projecting)
  end
end
