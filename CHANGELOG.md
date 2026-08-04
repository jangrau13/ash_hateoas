# Changelog

## Unreleased

Initial release: authorization- and state-aware HATEOAS affordances for Ash,
served natively as a Hydra / JSON-LD API.

### The transport

- `AshHateoas.Hydra.Plug` serves an Ash domain as `application/ld+json`. It
  reads and writes every routed resource itself and renders JSON-LD keyed to the
  Hydra Core Vocabulary (`http://www.w3.org/ns/hydra/core#`):
  - `GET <doc_path>` — the full `ApiDocumentation` (`supportedClass` with
    `supportedProperty` and `supportedOperation`). There is no entry point:
    every response carries a `Link: <…/doc>; rel="apiDocumentation"` header, so
    a client may start at any URL and `GET /` serves nothing;
  - `GET` member/collection — the resource node with its actor- and state-gated
    `hydra:operation`s, or a `hydra:Collection` with `member`, `totalItems` and a
    `hydra:PartialCollectionView` for paginated reads;
  - `POST`/`PATCH`/`DELETE`/generic — decodes the JSON-LD body, runs the action,
    and renders the new state or a `hydra:Error`.
  - Every response advertises the API documentation via a `Link` header.

### Affordances

- Affordances are **derived, never authored** — from a resource's actions,
  routes, policies and (where present) `AshStateMachine` transitions. Each
  becomes a `hydra:Operation`; a write's inputs become `hydra:SupportedProperty`
  entries under `hydra:expects`, a query read's become a `hydra:IriTemplate`.
- The affordance set is resolved per request via `Ash.can?/3` — the same check
  the endpoint enforces on invocation — plus the state gate where a state machine
  is present.
- `AshHateoas.affordances/3` exposes the transport-neutral envelope directly.

### Links

- Resources are connected by **links**, never by one resource's representation
  sitting inside another's. Every public Ash relationship becomes a
  `hydra:Link` property on the node; there is no link DSL.
- A link is a **node reference** (`{"@id": …}`, plus `"@type": "Collection"`
  for a to-many) or an **expanded node** — the same link with the target's own
  properties stated alongside it, still carrying its `@id`. Which one is
  decided entirely by what the action loads (`Ash.load/3`, a preparation, a
  query load): an unloaded to-one is referenced from its foreign key without
  reading the target, a loaded one is rendered in place, recursively, with
  cycles degrading to a plain reference. The target's terms travel with it as a
  scoped `@context`, so a record expands to the same triples however it is
  reached.
- **Writes name the target, never a foreign key.** A body carries
  `{"author": {"@id": "/people/7"}}` or, for a class declaring an `identity`,
  `{"author": {"name": "Ada"}}`; `null` clears an optional link.
  `AshHateoas.Hydra.LinkInput` resolves an IRI by matching it against the same
  routes that serve a GET, so the URLs the API issues are the URLs it accepts.
  Foreign keys do not appear in `hydra:expects` at all — a relationship input
  is advertised as its link property, typed `sh:nodeKind: sh:IRI`.
- **A to-many says what its members are.** The ontology declares a
  `hydra:Collection` subclass per to-many property, carrying a
  `hydra:memberAssertion` — Hydra's own pattern for a strongly typed
  collection. Where the relationship is **narrowed** by a filter
  (`has_many :reviews, Comment, filter: expr(kind == :review)`) the assertion
  names the class the filter picks out rather than the destination, so
  narrowings of one base are distinguishable by what they claim rather than
  only by an `rdfs:label`. Asserted only where the filter pins an attribute to
  a single literal *and* a class of that name is declared — every other filter
  falls back to the destination, which is weaker and never wrong.
- Refusals are `hydra:Status` 422s: clearing a required link, a reference to
  the wrong class, a dangling target, an identity object whose keys are not a
  declared identity, or an absolute IRI under a foreign origin. Existence is
  checked as the actor, so a target they may not see answers exactly as a
  missing one — a write is never an existence oracle.
- Link properties advertise `hydra:writable` (the current Hydra term) according
  to whether a write action can actually set them, and the property IRI matches
  the ontology declaration — so the chain from a write operation's input to the
  target class's own operations is traversable for every verb.

### Routes

- Every action is routed by default; `unrouted :action` keeps one off the
  surface, verified against the action list so a rename fails the build.
- `base` is derived from the domain's short name and the resource's `type`, and
  `type` is inferred from the module name when undeclared. Neither is pluralised.
- Primaries take the REST verbs; everything else is addressed by name under
  `/:id/<action>`. A `get?: false` read derives a collection index at `/<name>`;
  a generic action's method is assumed `POST` and warned about, correctable with
  `method :action, :get`.
- Reactor compensation actions and AshAuthentication's own actions are skipped
  automatically.

### Well-known vocabularies (schema.org)

- `semantic_type "Person"` on a resource advertises a well-known type alongside
  its own class: each record node carries both (`"@type": ["…#Person",
  "https://schema.org/Person"]`) and the `hydra:Class` declares an
  `owl:equivalentClass`. A bare token resolves against schema.org; an absolute
  IRI is used verbatim.
- `semantic_property :additional_name, "additionalName"` maps an attribute to a
  well-known property IRI — the node `@context` binds the flat key to it and the
  `ApiDocumentation` advertises the property by that IRI. A verifier fails the
  build when it names a missing attribute.
- **`mix ash_hateoas.gen.schema_org Person --domain MyApp.People`** generates a
  resource from a schema.org type fetched live: one attribute + `semantic_property`
  per property. A property whose range is another type is generated as:
  - a real **`belongs_to`** when the domain already serves that type (or it is a
    self-reference) — an internal, in-process relationship; or
  - an **`AshHateoas.Type.ResourceLink`** attribute otherwise — an external,
    followable URL.

  The generator scans the domain to decide, prompts only on genuine ambiguity
  (`--yes` defaults ambiguous to external), and `--internal Organization,Place`
  forces named types internal.
- A `AshHateoas.Type.ResourceLink` value renders as a JSON-LD reference node
  (`{"@id": url}`); internal vs external is the `@id`'s host, not a separate flag.

### DSL

- A `hateoas` section carrying `type`, `base`, `semantic_type`, and the
  override-only entries `exclude`, `override`, `unrouted`, `method`,
  `semantic_property`, plus `enabled?`.
- An `agentic_hateoas` section with `not_delegable :action` — an action that
  stays advertised (flagged `ah:notDelegable`) but is executed only by a
  credential a configured `commit_authority` deems committing. A refusal is a
  `403` `hydra:Error` carrying, under `ah:projection`, what the action would have
  done — read from the transitions and gate chain, never executed.
