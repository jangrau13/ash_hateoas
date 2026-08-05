defmodule AshHateoas.DslRoot do
  @moduledoc """
  Makes a resource an **aggregate root**: the thing a client authors, validates
  and saves as one document.

      use Ash.Resource,
        domain: MyApp.Cooking,
        extensions: [AshHateoas.Resource, AshHateoas.DslRoot]

  That is the whole declaration — there is no section to write and no flag to
  set. Carrying the extension *is* the statement that this resource is a root,
  and a boolean inside it would have to be `true` for the extension to do
  anything, so it could only ever be set to the one value that was not a
  mistake.

  It generates `:validate` and `:save`, both taking the whole aggregate as a
  flat list of elements, and both routed like any other action — so they reach
  the wire as Hydra operations with nothing further to declare.

  ## Why a root at all

  The root is what gives a multi-element document a subject. "Two elements share
  a name" and "this reference does not resolve" are not properties of any single
  changeset — they need a boundary, and the aggregate supplies it. A domain is
  not a subject: you cannot save a domain.

  `:validate` is a **generic action**, so it returns a value and cannot write by
  construction. That invariant is enforced by the action type rather than by
  discipline, which is what makes it safe to call on every editor save.

  More than one root per domain is allowed: a second root is a second document
  and therefore a second language, told apart by the operation a client calls.
  Most resources are parts rather than roots, which is why this is opt-in.

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

  ## An element's changes run per element — `c:document_context/1` is the escape

  Every element of a document is cast through its own
  `Ash.Changeset.for_create/4`, which runs that resource's `change` modules. A
  change is ordinary code, so a change that reads the database **reads it once
  per element** — and a document is the one place where that multiplication is
  guaranteed rather than incidental.

  This is not a hypothetical cost. Measured on a real domain whose elements
  resolve a reference by name: one lookup per element meant a 1,000-element
  document spent 2s in the database and a 10,000-element one 8.5s, against 6ms
  of actual parsing. Nothing about the work was expensive; asking for it a
  thousand times was.

  A change cannot fix this itself, because it cannot see the document — by
  construction, since it is handed one changeset. So the root, which *can* see
  it, is given one chance to prepare whatever its elements will need:

      @behaviour AshHateoas.DslRoot

      @impl true
      def document_context(document) do
        %{targets: MyApp.Target.fetch_many(referenced_ids(document))}
      end

  What it returns becomes the changeset `context` for every element, so a change
  reads it with `changeset.context[:targets]` instead of querying. **The library
  never learns what the context holds** — it collects it, passes it down, and
  the meaning stays entirely in the domain.

  Two properties this must keep, and they are the reason it is a callback rather
  than something the library does automatically:

    * **It runs on `:validate` as well as `:save`**, and `:validate` writes
      nothing — so an implementation must read, never write. It is called before
      any element is cast, which is exactly when there is nothing to write yet.
    * **A change must still work without it.** The context is absent when a
      resource is written through its own action rather than through a document,
      so a change reads it as a *cache* and falls back to its own lookup. An
      implementation that made the context mandatory would break every
      single-record write.

  Optional: a root that does not implement it is cast exactly as before.
  """

  @doc """
  Prepares context shared by every element of a document, once.

  Called with the whole document before any element is cast, on `:validate` and
  on `:save`. The returned map becomes each element changeset's `context`, so a
  `change` can read what it needs instead of querying per element.

  Must not write — `:validate` is a generic action that persists nothing, and an
  implementation that wrote here would break that guarantee.

  Returning `%{}` is the same as not implementing it.
  """
  @callback document_context(document :: list()) :: map()

  @optional_callbacks document_context: 1

  use Spark.Dsl.Extension,
    transformers: [AshHateoas.DslRoot.Transformers.DeriveRootActions]
end
