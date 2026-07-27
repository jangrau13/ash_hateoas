defmodule AshHateoas.Resource.Changes.EnforceNotDelegable do
  @moduledoc """
  Refuses a `not_delegable` action for a credential that does not commit.

  Installed automatically by
  `AshHateoas.Resource.Transformers.EnforceNotDelegable` on every action the
  `agentic_hateoas` section names. It is not written by hand.

  ## Why a change and not a plug

  Enforcing in the transport would cover the Hydra plug and nothing else — so a
  consumer invoking through `Ash.update/2` would have bypassed it. A change runs
  inside Ash, so every caller is refused identically, whatever the transport.

  It also keeps advertisement intact. `Ash.can?/3` still answers `true`, so the
  affordance is still advertised and still carries its flag; advertisement and
  enforcement do not diverge into two implementations of one rule.

  ## It rejects before anything runs

  The refusal is added to the changeset directly, so the action is invalid
  before `before_action` and never reaches the data layer. Rejecting later —
  from `after_action`, say — would fire every side effect the action performs
  and *then* refuse, which is the failure this whole feature exists to prevent.

  ## The projection is computed only on refusal

  Building it re-runs the gate chain (`AshHateoas.Projection`), so it is
  deliberately computed after the decision to refuse, never before. A committing
  actor pays nothing.

  ## Pre-flight changesets never reach this

  `AshHateoas.Resource.Changes.InvocationChange` implements `change/3` and
  returns a pre-flight changeset before `change_invocation/3` is called, so this
  module cannot see one. That is structural rather than conventional: the guard
  used to live here as a clause, and a clause can be dropped by an edit that
  looks harmless.

  Two things depend on it. `Ash.can?/3` asks whether the action is *permitted*,
  and it is — refusing there would drop the affordance from the advertised set.
  And building the projection re-enters `Ash.can?/3`, so a change
  that refused pre-flight changesets would loop, hanging rather than crashing.

  The cost of the base module's default: a `not_delegable` action cannot run
  atomically, since an atomic update never calls `change/3` at all. Acceptable —
  the declaration is rare, deliberate, and on exactly the actions where a
  correct refusal matters more than a single-statement update.
  """

  use AshHateoas.Resource.Changes.InvocationChange

  @impl AshHateoas.Resource.Changes.InvocationChange
  def change_invocation(changeset, _opts, context) do
    if AshHateoas.CommitAuthority.commits?(context.actor) do
      changeset
    else
      Ash.Changeset.add_error(changeset, refusal(changeset, context))
    end
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
  end
end
