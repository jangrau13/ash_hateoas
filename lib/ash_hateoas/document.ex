defmodule AshHateoas.Document do
  @moduledoc """
  Makes a resource an **aggregate root**: the thing a client authors, validates
  and saves as one document.

      use Ash.Resource,
        domain: MyApp.Cooking,
        extensions: [AshHateoas.Resource, AshHateoas.Document]

      document do
        aggregate_root? true
      end

  That declaration generates `:validate` and `:save`, both taking the whole
  aggregate as a flat list of elements, and both routed like any other action —
  so they reach the wire as Hydra operations with nothing further to declare.

  ## Why this is a separate extension

  `AshHateoas.Resource` describes a domain and routes to it. It has no opinion
  about documents, because a document is a *format*, and nothing in Hydra says
  what one looks like. The `kind`-keyed flat list this extension expects is a
  convention, useful for authoring tools and not universal.

  Keeping it separate means a resource that never opts in never sees the DSL,
  the transformer or the vocabulary. A deployment that only wants affordances
  and routing carries none of this.

  It also keeps the boundary honest in the other direction: a client needs only
  that the two operations **exist and are advertised**. How a backend provides
  them is its own business, and this extension is one convenient answer rather
  than the required one.

  ## What a document is

  A flat list of elements, each naming its class in a `kind` key:

      [
        %{"kind" => "ingredient", "name" => "Sugar", "unit" => "g"},
        %{"kind" => "step", "name" => "Mix", "uses" => "Sugar"}
      ]

  Flat rather than nested because a domain graph *is* a graph: the same element
  is referenced from several places, and nesting would force a spanning tree
  onto it. See `AshHateoas.RootActions` for what validation and persistence do
  with it.

  ## Both actions may be overridden

  Each is added only when the resource does not already declare an action of
  that name, so a hand-written `:validate` is used as-is and `:save` is still
  generated. The declaration and the override coexist rather than the author
  having to choose for the pair.
  """

  @document %Spark.Dsl.Section{
    name: :document,
    describe: """
    Declares this resource an aggregate root, so a client can author, validate
    and save it as one document.
    """,
    examples: [
      """
      document do
        aggregate_root? true
      end
      """
    ],
    schema: [
      aggregate_root?: [
        type: :boolean,
        default: false,
        doc: """
        Whether this resource is the aggregate root — the thing a client
        authors, validates and saves as **one document**.

        Declaring it generates two actions, `:validate` and `:save`, each
        taking a `document` argument carrying the whole aggregate.

        The root is what gives a multi-element document a subject. "Two
        elements share a name" and "this reference does not resolve" are not
        properties of any single changeset — they need a boundary, and the
        aggregate supplies it. A domain is not a subject: you cannot save a
        domain.

        `:validate` is a **generic action**, so it returns a value and cannot
        write by construction. That invariant is enforced by the action type
        rather than by discipline, which is what makes it safe to call on every
        editor save.

        More than one root per domain is allowed: a second root is a second
        document and therefore a second language, told apart by the operation a
        client calls.

        Defaults to `false`: most resources are parts, not roots.
        """
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@document],
    transformers: [AshHateoas.Document.Transformers.DeriveRootActions]
end
