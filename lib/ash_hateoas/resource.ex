defmodule AshHateoas.Resource do
  @moduledoc """
  Adds authorization- and state-aware affordances to a resource.

      defmodule MyApp.Document do
        use Ash.Resource,
          domain: MyApp.Docs,
          extensions: [AshJsonApi.Resource, AshHateoas.Resource]
      end

  That is the whole per-resource setup. Every routed action the actor may invoke
  — and that is legal from the record's current state — is advertised
  automatically, in every transport, from this one declaration.

  ## The DSL is override-only (R2)

  There are deliberately **no per-action "enable" entries**. Everything routed
  is advertised; the block carries deviations only:

      hateoas do
        enabled? true
        exclude :internal_reconcile
        override :approve, href: "/documents/:id/approve"
      end

  A compile-time verifier rejects an `exclude` or `override` naming an action
  that does not exist, so a renamed action fails the build rather than silently
  losing its deviation.
  """

  alias AshHateoas.Resource.{Exclusion, Override}

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
    entities: [@exclude, @override],
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
    verifiers: [AshHateoas.Resource.Verifiers.VerifyActions]
end
