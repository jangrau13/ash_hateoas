defmodule AshHateoas.Resource do
  @moduledoc """
  Adds authorization- and state-aware affordances to a resource.

      defmodule MyApp.Document do
        use Ash.Resource,
          domain: MyApp.Docs,
          extensions: [AshJsonApi.Resource, AshHateoas.Resource]
      end

  That is the whole per-resource setup. Every action is routed, and every routed
  action the actor may invoke — and that is legal from the record's current
  state — is advertised automatically, in every transport, from this one
  declaration.

  ## Routes are derived, not written (R1)

  A resource needs no `routes` block. The `base` comes from the domain's
  `short_name` and the json_api `type`; each action is routed by its kind, with
  primaries taking the REST verbs and everything else addressed by name under
  `/:id/`. A declared route always wins, so hand-routing one action leaves the
  rest derived.

  This means **adding this extension widens a resource's HTTP surface** to every
  action it declares. Under the older allow-list an unrouted action was simply
  invisible; now keeping one off the surface is something you say out loud.
  Policies remain the actual gate on what any actor may invoke.

  ## The DSL is override-only (R2)

  There are deliberately **no per-action "enable" entries**. Saying nothing
  yields the full surface; the block subtracts from it or corrects it:

      hateoas do
        enabled? true
        exclude :internal_reconcile
        override :approve, href: "/documents/:id/approve"
        unrouted :sync_from_stripe
        method :tally, :get
      end

  `exclude` withholds an action from advertisement but leaves it routed;
  `unrouted` keeps it off the HTTP surface entirely. `method` supplies the one
  fact that cannot be derived — a generic action's verb, since `action :tally,
  :boolean` says nothing about whether it mutates. POST is assumed and warned
  about; declaring the method either way silences the warning.

  A compile-time verifier rejects any entry naming an action that does not
  exist, so a renamed action fails the build rather than silently losing its
  deviation — which for `unrouted` would mean silently republishing it.
  """

  alias AshHateoas.Resource.{Exclusion, Method, Override, Unrouted}

  @method %Spark.Dsl.Entity{
    name: :method,
    target: Method,
    args: [:action, :method],
    identifier: {:auto, :unique_integer},
    describe: """
    The HTTP method for a generic action, whose verb cannot be derived.
    """,
    examples: ["method :tally, :get"],
    schema: [
      action: [
        type: :atom,
        required: true,
        doc: "The generic action being routed."
      ],
      method: [
        type: {:in, [:get, :post, :patch, :delete, :put, :head, :options]},
        required: true,
        doc: "The HTTP method to route it under. POST is assumed otherwise."
      ]
    ]
  }

  @unrouted %Spark.Dsl.Entity{
    name: :unrouted,
    target: Unrouted,
    args: [:action],
    identifier: {:auto, :unique_integer},
    describe: """
    An action that must not be given an HTTP route.
    """,
    examples: ["unrouted :sync_from_stripe"],
    schema: [
      action: [
        type: :atom,
        required: true,
        doc: "The action to keep off the HTTP surface entirely."
      ]
    ]
  }

  @exclude %Spark.Dsl.Entity{
    name: :exclude,
    target: Exclusion,
    args: [:action],
    identifier: {:auto, :unique_integer},
    describe: """
    An action that is routed but must not be advertised.
    """,
    examples: ["exclude :internal_reconcile"],
    schema: [
      action: [
        type: :atom,
        required: true,
        doc: "The action to withhold from every transport."
      ]
    ]
  }

  @override %Spark.Dsl.Entity{
    name: :override,
    target: Override,
    args: [:action],
    identifier: {:auto, :unique_integer},
    describe: """
    Replace part of an action's derived affordance.
    """,
    examples: [~s(override :approve, href: "/documents/:id/approve")],
    schema: [
      action: [
        type: :atom,
        required: true,
        doc: "The action whose affordance is being overridden."
      ],
      href: [
        type: :string,
        required: false,
        doc: "Replaces the href derived from the action's declared route."
      ]
    ]
  }

  @hateoas %Spark.Dsl.Section{
    name: :hateoas,
    describe: """
    Deviations from the affordances derived for this resource.

    The section is optional — a resource carrying the extension needs no
    `hateoas` block at all.
    """,
    examples: [
      """
      hateoas do
        exclude :internal_reconcile
        override :approve, href: "/documents/:id/approve"
      end
      """
    ],
    entities: [@exclude, @override, @unrouted, @method],
    schema: [
      enabled?: [
        type: {:or, [:boolean, {:literal, nil}]},
        default: nil,
        doc: """
        Whether affordances are computed for this resource. Affordances are a
        hypermedia contract, so the effective default is on and this switches
        them off.

        Defaults to `nil`, not `true`, so that "not declared" stays
        distinguishable from "declared true" — Spark materialises schema
        defaults into the DSL state, so a `true` default would make a resource
        appear to override its domain when it had said nothing.
        `AshHateoas.Posture` resolves `nil` to the domain's value, then to `true`.
        """
      ],
      warn_on_missing_authorizers?: [
        type: :boolean,
        default: true,
        doc: """
        Warn at compile time when the resource declares no authorizers. Set to
        false for a resource that is deliberately public.
        """
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@hateoas],
    transformers: [
      AshHateoas.Resource.Transformers.MarkPrimaryGet,
      AshHateoas.Resource.Transformers.DeriveActionRoutes,
      AshHateoas.Resource.Transformers.DeriveRelationshipRoutes
    ],
    verifiers: [AshHateoas.Resource.Verifiers.VerifyActions]
end
