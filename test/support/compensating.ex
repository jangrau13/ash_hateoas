defmodule AshHateoas.Test.Compensating do
  @moduledoc """
  A resource with a Reactor compensation action.

  `:undo_create` has the shape Ash requires of an `undo_action` for a `create`
  step: exactly one argument named `changeset`, checked by
  `Ash.Reactor.Builders.Create.verify_action_takes_changeset/3`. That shape is
  what makes it unroutable — an HTTP caller cannot construct an `Ash.Changeset`
  — so it is skipped without the author saying anything.

  `:archive` is the control: also a destroy, also with an argument, but an
  ordinary one. It must still be routed, or the check is too broad and starts
  swallowing real endpoints.
  """

  use Ash.Resource,
    domain: AshHateoas.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshHateoas.Resource]

  ets do
    private? true
  end

  hateoas do
    type "compensating"
  end

  attributes do
    uuid_primary_key :id
    attribute :label, :string, public?: true
  end

  actions do
    defaults [:read, create: [:label]]

    # The compensation. Reactor hands back the changeset that created the row,
    # not the record — hence the argument.
    destroy :undo_create do
      require_atomic? false
      argument :changeset, :struct, allow_nil?: false
    end

    # An ordinary destroy that happens to take an argument.
    destroy :archive do
      require_atomic? false
      argument :reason, :string, allow_nil?: true
    end
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end
end
