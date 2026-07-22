defmodule AshHateoas.Resource.Changes.InvocationChange do
  @moduledoc """
  A change that runs on **invocation** and never on a pre-flight check.

  `Ash.can?/3` builds a changeset to ask whether an action is *permitted* and
  marks it `private.pre_flight_authorization?` — Ash's own signal for "this is a
  hypothetical". Such a changeset is never executed, so a change that rejects it
  is answering the wrong question. Worse, for anything this package installs, it
  is answering the question that decides whether the action is *advertised*: a
  refusal there drops the affordance from the set R6 requires be published.

  It is also where non-termination hides. A change that computes anything from
  the backbone re-enters `Ash.can?/3`, which builds a changeset, which runs the
  change, which computes again — a loop that hangs rather than crashing, and
  prints nothing while it does.

  So the guard is not left to each change to remember:

      defmodule MyChange do
        use AshHateoas.Resource.Changes.InvocationChange

        @impl true
        def change_invocation(changeset, opts, context) do
          # only ever reached for a real invocation
        end
      end

  `change/3` is implemented here and is **not** overridable. A pre-flight
  changeset is returned untouched before `change_invocation/3` is called, so a
  change built on this cannot see one, and cannot reintroduce the loop by
  forgetting a guard. `AshHateoas.Resource.Changes.EnforceNotDelegable` is built
  on it; anything else this package installs on an action should be too.

  Atomic actions are declined by default for the same reason
  `EnforceNotDelegable` declines them: an atomic update never calls `change/3`,
  so the change would be skipped entirely. Override `atomic/3` where that is
  wrong for a particular change.
  """

  @doc """
  The change to apply, called only for a real invocation.

  Same contract as `c:Ash.Resource.Change.change/3`.
  """
  @callback change_invocation(
              changeset :: Ash.Changeset.t(),
              opts :: keyword(),
              context :: Ash.Resource.Change.Context.t()
            ) :: Ash.Changeset.t()

  @doc """
  Whether `changeset` is `Ash.can?/3` asking a hypothetical.

  Reads the same key as `Ash.Resource.Validation.PreFlightAuthorization`.
  """
  @spec pre_flight?(Ash.Changeset.t()) :: boolean()
  def pre_flight?(%Ash.Changeset{} = changeset) do
    changeset.context[:private][:pre_flight_authorization?] == true
  end

  defmacro __using__(_opts) do
    quote do
      use Ash.Resource.Change

      @behaviour AshHateoas.Resource.Changes.InvocationChange

      # Deliberately not overridable: the guard is the point of this module, and
      # a change that could replace `change/3` could drop it.
      @impl Ash.Resource.Change
      def change(changeset, opts, context) do
        if AshHateoas.Resource.Changes.InvocationChange.pre_flight?(changeset) do
          changeset
        else
          change_invocation(changeset, opts, context)
        end
      end

      @impl Ash.Resource.Change
      def atomic(_changeset, _opts, _context) do
        {:not_atomic,
         "#{inspect(__MODULE__)} runs on invocation, which an atomic action bypasses"}
      end

      defoverridable atomic: 3
    end
  end
end
