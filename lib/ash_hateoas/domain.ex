defmodule AshHateoas.Domain do
  @moduledoc """
  Domain-level defaults for affordances (R8).

      defmodule MyApp.Docs do
        use Ash.Domain, extensions: [AshHateoas.Domain]

        hateoas do
          enabled? false
        end
      end

  A resource inherits this unless it declares its own `enabled?`. That is what
  lets a deployment switch a whole domain off without touching every resource,
  and REQ's "the posture is a declaration, not a hardcoded rule".

  The extension is optional: a domain without it simply has no default, and
  resources fall back to `true`.
  """

  @hateoas %Spark.Dsl.Section{
    name: :hateoas,
    describe: """
    Defaults inherited by every resource in this domain.
    """,
    examples: [
      """
      hateoas do
        enabled? false
      end
      """
    ],
    schema: [
      enabled?: [
        type: {:or, [:boolean, {:literal, nil}]},
        default: nil,
        doc: """
        Whether affordances are computed for resources in this domain. A
        resource's own `enabled?` takes precedence.

        Defaults to `nil` rather than `true` — see `AshHateoas.Resource`'s
        `enabled?` for why.
        """
      ]
    ]
  }

  use Spark.Dsl.Extension, sections: [@hateoas]
end
