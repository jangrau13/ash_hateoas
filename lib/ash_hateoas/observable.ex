defmodule AshHateoas.Observable do
  @moduledoc """
  A transport-neutral observability spec, derived from an `observable`
  declaration.

  Where `AshHateoas.Route` is the derived answer to "where does this live",
  this is the derived answer to "what URL names this change, and which actions
  cause it":

    * `subject` — what is observed: `:resource`, `:collection`, or an attribute
      name.
    * `topic` — the URL a subscriber subscribes to. The collection URL for
      `:collection`, the member URL (`/base/:id`) for `:resource`, and the
      member URL plus `?observe=<attribute>` for a property. `:id` is a path
      param, filled in by the publishing transport per changed record.
    * `actions` — the concrete, routed action names whose completion signals a
      change to this topic. An `unrouted` action never appears here, so keeping
      an action off the HTTP surface also keeps it from notifying.

  Specs are persisted under the `ash_hateoas`-owned key
  `:ash_hateoas_observables` and read at runtime via
  `AshHateoas.Resource.Info.observables/1`. This package never publishes them —
  a transport (e.g. `ash_websub`) does.
  """

  @type t :: %__MODULE__{
          subject: :resource | :collection | atom(),
          topic: String.t(),
          actions: [atom()]
        }

  defstruct [:subject, :topic, actions: []]
end
