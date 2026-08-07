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
- A to-one link is a **node reference** (`{"@id": …}`) or an **expanded node** —
  the same link with the target's own properties stated alongside it, still
  carrying its `@id`. A to-many is a `hydra:Collection` carrying its members.
  Which one is decided entirely by what the action loads (`Ash.load/3`, a
  preparation, a query load): an unloaded to-one is referenced from its foreign
  key without reading the target, a loaded one is rendered in place,
  recursively, with cycles degrading to a plain reference. The target's terms travel with it as a
  scoped `@context`, so a record expands to the same triples however it is
  reached.
- **Writes name the target, never a foreign key.** A body carries
  `{"author": {"@id": "/people/7"}}` or, for a class declaring an `identity`,
  `{"author": {"name": "Ada"}}`; `null` clears an optional link.
  `AshHateoas.Hydra.LinkInput` resolves an IRI by matching it against the same
  routes that serve a GET, so the URLs the API issues are the URLs it accepts.
  Foreign keys do not appear in `hydra:expects` at all — a relationship input
  is advertised as its link property, typed `sh:nodeKind: sh:IRI`.
- **Nor do they appear on the read surface.** `belongs_to :author, Person,
  public?: true` makes Ash define an `author_id` attribute that *inherits* the
  relationship's `public?`, so every path reading `public_attributes/1` picked
  it up and published Ash's storage beside the link describing the same edge —
  two spellings of one fact, and the one a client cannot use, since the write
  path takes the link. Excluded now from the documentation, the ontology, the
  node context and the served node alike, through one shared
  `AshHateoas.Resource.Info.public_attributes/1` so they cannot disagree.
  An attribute the domain declared **in its own right** stays: the signal is
  the relationship's `define_attribute?`, never the `_id` suffix.
- **A to-many is a collection, referenced then expanded.** Its `@id` is the
  relationship's own route (`/articles/7/comments`), so it has an identity that
  resolves to exactly that collection. Unloaded, it carries its members as bare
  `{"@id"}` references — bounded, with `hydra:totalItems` stating the true size
  and a `hydra:PartialCollectionView` pointing at the rest. Loaded, the same
  collection states those members in place. So **loading controls expansion,
  never presence**: the rule a to-one already followed, now followed by both
  cardinalities. A client always learns which records are related and can follow
  any of them.
- **`?load=<relationship>` lets a client ask for expansion**, advertised as a
  `hydra:IriTemplate` on the node so it is discovered rather than known out of
  band. It accepts any public to-many the class declares; an unknown or private
  name is ignored rather than refused, since the parameter narrows a response
  and must never widen what may be read. Repeated (`?load=a&load=b`) per RFC
  6570's explode form.
- **No route nests a member under another record.** `/articles/7/comments/3`
  does not exist: a record that already has an address never gets a second one,
  and its identity never depends on the path a client took to reach it. The
  relationship's *collection* keeps its route, because a collection has no other
  address and pagination needs one to page against.
- The JSON:API-style `/relationships/<name>` route is no longer derived. It
  returned linkage without the members; the reference list a collection now
  carries says exactly that, in place, at no extra request.
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
- **`AshHateoas.Type.Lua`** — an attribute holding source code, parsed on write
  (`luerl`'s scanner and parser only; nothing is ever executed). `constraints:
  [form: :chunk]` admits a full program where the default `:expression` admits a
  single value. The wire declares such a property with `rdfs:range ah:Script` and
  `ah:scriptLanguage` rather than `xsd:string`, so a client learns the value is
  code and which grammar reads it — `ah:Script` is an `rdfs:Datatype` restricting
  `xsd:string`, so a consumer that does not know the term still reads a string.

  An **operation's inputs** state the same pair, as `sh:datatype` +
  `ah:scriptLanguage`: an argument is not a property of any class, so nothing
  declares a range for it and the language would otherwise be unrecoverable —
  a client writing a formula through a save was told it was code but not that
  it was Lua. Both sides ask the type, so they cannot drift.
- **`AshHateoas.LuaScript`** — an extension declaring what the names *inside* a
  script mean. `bind :author, Author` makes `author["Ada"]` a reference that
  resolves; `functions SomeResource` publishes the callable signatures so a
  client fetches them rather than guessing. A subscript naming nothing bound, an
  unknown function, or a wrong arity is refused where it is written.

  Four declarations fail the build, each of them a way the section could be
  configured and inert: a `script` naming no attribute or one not typed
  `AshHateoas.Type.Lua`, two binds sharing a name, a bind keyed on a missing
  attribute, and a bind keyed on a **non-unique** attribute — a reference names
  one record, so a key two records can share resolves to whichever comes back
  first.

### DSL

- A `hateoas` section carrying `type`, `base`, `semantic_type`, and the
  override-only entries `exclude`, `override`, `unrouted`, `method`,
  `semantic_property`, plus `enabled?`.
- An `agentic_hateoas` section with `not_delegable :action` — an action that
  stays advertised (flagged `ah:notDelegable`) but is executed only by a
  credential a configured `commit_authority` deems committing. A refusal is a
  `403` `hydra:Error` carrying, under `ah:projection`, what the action would have
  done — read from the transitions and gate chain, never executed.
