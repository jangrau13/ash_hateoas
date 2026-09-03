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
- **An operation is identified by a class IRI**, in its own `@type`:
  `["Operation", "<vocab>#Document/approveAction"]`. `Operation` alone is
  carried by every operation and separates none of them; the `ah:action` string
  that used to do the separating cannot be dereferenced, subclassed or
  annotated, and is local — two APIs each with an `approve` were
  indistinguishable. The class is minted under the API's own vocabulary and
  named the way an input class already is (`<Class>/<action>Input`).

  The class comes from the action's name, never from the HTTP method: two
  `update`-shaped actions on one resource are both `PATCH` returning the same
  class, so the method cannot separate them and the name can.

  The domain's own word survives as `rdfs:label` on the class, where a label
  belongs — it is a fact about the action, not about a request.
- **`schema:potentialAction` is no longer emitted.** A declared
  `semantic_action` becomes `rdfs:subClassOf` on the operation's class, in the
  `ApiDocumentation`'s `@included`. It says the operation **is** that kind of
  action rather than *has* one — the accurate reading for a node that is the
  offer to act, and `potentialAction` is defined with domain `Thing` and range
  `Action`, which makes an `Operation` an awkward subject for it. An axiom also
  holds in every state, so it belongs in the document that is fetched once.
- **A route onto an action mints nothing.** Two routes may carry one action —
  the standard case is a primary read reached both at `/:id` and at the
  collection — and they share the action's class, since they invoke the same
  action. They are told apart by `ah:template` and `hydra:returns`, which are
  facts about the call. A catalogue entry's `@type` is therefore the same
  two-element list a node's operation carries, and the join between the two
  documents is an identity rather than a walk up a subclass chain.

  A subclass per route (`<Class>/<action>Action/<route kind>`) was emitted
  briefly and withdrawn. For an action with one route — most of them — it had
  exactly its parent's members, added no property and constrained nothing; and
  its segment was an Ash route kind that spells like an HTTP method, so
  `<Class>/sitAction/patch` read as "sitting is a kind of PATCH" — the inference
  this package refuses when it declines to derive `schema:ReadAction` from a GET.
  See `documentation/hydra-conformance-notes.md` §12.
- An `odrl:Permission` names its operation by that same class IRI under
  `ah:action`, rather than by a bare string.
- **A `:map` attribute's inner keys must be prefixed.** They are application
  data the package has no schema for, so nothing declares them and a JSON-LD
  processor drops them in silence — the value looks right in the JSON and is
  missing from the graph. `AshHateoas.Hydra.Plug` now warns once per key on any
  bare one it emits, `AshHateoas.Hydra.Context.undeclared_keys/2` is the public
  check behind it, and `hydra/no_dropped_keys_test.exs` covers the served shape.
  A compile-time check is impossible: the keys are runtime data.
- **Every affordance is one entry in the node's `hydra:operation`, and every
  operation states where it is invoked** as `ah:href` — a minted
  `owl:ObjectProperty` with domain `hydra:Operation`, range `hydra:Resource`.

  Hydra core mints no target-URL term, which is a gap in the vocabulary rather
  than a claim that an operation has no target: a client cannot invoke anything
  without a URL. The gap was first filled by a rule — "an operation is invoked
  against the node it hangs on" — with `ah:href` written only where the rule did
  not hold. That left the common case implicit, and an implicit URL holds only
  while the operation is still attached to its node: lift one out to log it,
  queue it, or hand it to another process, and it no longer says where it goes.
  A named sub-action is now not a special case, only a different value.

  Absent only in the `ApiDocumentation`, which describes a class rather than a
  record — there is no instance to invoke anything against. That document states
  `ah:template` instead: how to build the URL, rather than the one that was
  resolved.

  It used to be a link property `ah:<action>` wrapping a single-element
  `hydra:operation`. That named the action twice, held an array that was length
  one by construction, and left a client two traversal paths for one question,
  the second over keys whose names it could not know in advance. The wrapper's
  one benefit — a followable URL — was not real: a GET on a sub-action path is a
  404, since the plug matches those paths for writes only.

  A **design change, not a bug fix**: the old shape was conformant. It removes
  the statement `<document> ah:approve <document/approve>` from the graph; the
  URL is still in the document, inside the operation. See
  `documentation/hydra-conformance-notes.md` §7.
- **A catalogue entry now describes a call, not only a shape.** A client reading
  a `hydra:supportedOperation` should be able to issue it, which takes four
  answers: where to send it, what to send, what comes back, and what may go
  wrong. Three of the four were missing or wrong.

  - **`ah:template`** — a `hydra:IriTemplate` on every supported operation, built
    from the route's own path (`/exam/{id}`, `/exam`) and prefixed with where the
    API is mounted. A minted `owl:ObjectProperty` with domain `hydra:Operation`
    and range `hydra:IriTemplate` — the catalogue-side twin of `ah:href`, since a
    class has no record to resolve an address against. Without it a client
    holding only the documentation could see that a class supports nine
    operations and issue none of them, and a sub-action gated off by the record's
    state had **no URL in any document at all**. A collection route needs no
    variables and stays a template rather than becoming a second shape.

    `hydra:expects` narrows accordingly: in the documentation it means a request
    body and only a body. A node is unchanged — its GET affordance still renders
    query arguments as an `IriTemplate` under `hydra:expects`, where the address
    is already resolved as `ah:href`.

  - **A collection route returns a collection.** `hydra:returns` named the
    resource's class for both routes onto a primary read, and for `GET /exam`
    that was untrue: the response is a `hydra:Collection` with `hydra:member` and
    `hydra:totalItems`, which an Exam has neither of, so a client believing the
    declaration looked for the resource's properties on a node that has none of
    them. The `:index` route now names a minted `<Class>/Collection`, declared
    with the `hydra:memberAssertion` that says what is inside — `hydra:Collection`
    alone would be true and would not say of what.

    **Breaking** for a consumer reading `hydra:returns` on a collection route and
    expecting the member class. It was reading a false statement.

  - **Every served collection says what it is a collection of.** One
    `hydra:memberAssertion`, from `AshHateoas.Hydra.Collection.member_assertion/1`
    — the same function the declaration uses, so the two cannot drift. It reaches
    the resource collection, a related collection and an inline to-many (loaded or
    not), including a *narrowed* relationship, whose member class is read from
    `AshHateoas.Hydra.Ontology.member_class_iri/2`. It matters most on an empty
    page, which carries no members to infer it from.

  - **`hydra:possibleStatus` carries the success.** The list was built from three
    calls and all three were errors, so every entry read as an operation that can
    only fail and a generated handler had to hardcode which status means success.
    The success comes first, from the route kind: 200 for a read, an index, an
    update and a generic action; 201 for a create; **200 and 204** for a destroy,
    since the plug answers 200 with the destroyed record and 204 when the data
    layer yields none. Hydra places no restriction on the list — it is "merely a
    hint" — so nothing licensed omitting it.

  See `documentation/hydra-conformance-notes.md` §9–§11.
- **A resource yields two supported classes**, and a collection-level operation
  is filed under the second. `hydra:supportedOperation` on a `hydra:Class` says
  an *instance* of that class supports the operation — and you cannot POST to an
  exam to create an exam, nor is listing exams something one exam does. Every
  route used to hang off the one class, so 34 of 115 operations in a captured API
  were filed under a subject they are not about.

  `<Class>/Collection` is the same class `hydra:returns` already named on a
  collection route, so it is now described as well as returned. A collection
  response and every entry-point row name it in `@type`, so a client reaching
  either can look up what it supports — *how do I list these, how do I make one* —
  without holding a record.

  The split is by the route's **path**: `:id` in it means the member class.
  Reading the route *kind* was an approximation that stopped tracking the fact
  the moment a named transition became a `POST`.

  **Breaking** for a consumer looking up `create` under the member class. It was
  reading a statement about the wrong subject.
- **A named transition is a `POST`, not a `PATCH`.** Every non-primary `update`
  action became a `PATCH` at `/:id/<name>`, because the route kind was read off
  the Ash action's type — putting one verb on three unlike operations of one
  class. RFC 5789 defines `PATCH` by its body, *"a set of instructions describing
  how a resource … should be modified"*, and a transition sends no such thing:
  `open_sitting` sends nothing at all, so it was a `PATCH` with no patch
  document, which has no defined meaning. RFC 9110's `POST` — *"resource-specific
  processing on the request content"* — is the method for it.

  The primary update keeps `PATCH`, so `hydra:method` carries a real distinction
  again. A named **destroy** keeps `DELETE`: that argument is about `PATCH`
  semantics and does not carry over on its own. `method :sit, :patch` is the
  author's override, and it is now read for any non-primary action rather than
  only for a generic one — and by the **router** as well as the documentation, so
  a declared verb can no longer be advertised and then refused.

  **Breaking**: every sub-action URL's verb moves, and every client and captured
  fixture with it.
- **Every `POST`/`PATCH`/`PUT` declares its `hydra:expects`**, with an empty
  property list where the action takes nothing. An operation that took no input
  used to carry no `hydra:expects` at all — 71 of 115 in a captured document, 17
  of them `PATCH` — and absence in RDF is the absence of a statement rather than
  a negative one, so a client could not tell "send an empty body" from "the body
  is undescribed". *"These are the properties, and there are none"* is a
  statement.

  Not `owl:Nothing`: that says an instance of the empty class is expected, which
  is unsatisfiable and reads as "no valid request to this operation exists" —
  right for a response with no body, wrong for a request that is legitimately
  empty. `GET` and `DELETE` are left alone, since RFC 9110 gives silence there an
  unambiguous reading; a `DELETE` whose action takes arguments still describes
  them.

  **Every input class is now declared** in `@included` — 68 referenced and 0
  declared before, which was the ontology's own invariant broken in the one place
  its resource walk cannot reach. The class is declared and its properties are
  not, on the rule that already governs arguments.
- **A node's operation states `@type` and `ah:href`, and nothing else.** Those
  are the two facts that vary per request: which operations are present is
  decided by `Ash.can?/3` and the state gate, and the href holds the record's id.
  The method, the input, the return and the title are read off the *action*, so
  they are identical for every record of the class and every actor who may invoke
  it — 92 statements repeated across 13 captured responses that the catalogue
  already made once, and 40 operations shrinking from 22,354 bytes to 6,729.

  The class in `@type` is the key that joins the two documents, which is what it
  was minted for. The rule a client implements once:

  > the catalogue states the shape; a node may restate it; a node that says
  > nothing means the catalogue's answer stands.

  `AshHateoas.Hydra.Renderer.operation/2` still builds the full shape — it is what
  the documentation calls, and where a node would restate a narrowed input if an
  application ever needed one.

  **Breaking, and the largest break here.** A consumer reading a node's operation
  for its method, input or return finds none of them, and a node is no longer
  readable on its own. Every response carries
  `Link: <…>; rel="…apiDocumentation"`, so **that header is load-bearing now**: a
  path that omits it is a correctness bug rather than a missing convenience.

  See `documentation/hydra-conformance-notes.md` §13–§16.
- **`rdfs:isDefinedBy` is no longer emitted on term nodes.** Every one carried it,
  all with the same value, and that value was the `@id` of the `owl:Ontology`
  node in the same document. This package mints **hash** IRIs, so RDF's own rule
  already answers the question — truncate at the fragment — and restating it per
  term states the rule as data. The `owl:Ontology` node stays. `hydra-mapping.md`
  records the two changes that bring the property back: slash IRIs, or more than
  one namespace emitted as first-class nodes.
- An `odrl:Permission` names its operation under `ah:action` by the very class
  IRI that operation carries in its `@type`, so the permission list and the
  operation list can be joined. ODRL's action
  vocabulary is five terms wide, so `odrl:action` alone cannot say which
  operation a permission is about, and a `not_delegable?` duty could not be
  attached to one named action.
- An `odrl:Permission` targets **the URL its action is invoked on**, so a
  sub-action targets its own `ah:href` rather than the record. It used to target
  the record either way, which said the actor might `odrl:modify` the record
  itself when what was granted was one named transition on it.
- The node a `DELETE` returns drops `odrl:permission` along with
  `hydra:operation`. Dropping the latter alone left the permission list — and,
  before the flattening, every `ah:<action>` link node — asserting affordances on
  a record that no longer exists.
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
- **A citation resource is generated from the binds** — one nullable
  `belongs_to` per bind, so what a script names is a row with a real foreign key
  rather than a string the database cannot see. Its table is derived from the
  script resource's own, so the two sit together under whatever prefix the domain
  uses.

  **Postgres and SQLite both**, and neither is a dependency: the data layer is
  recognised by name and the matching `postgres` or `sqlite` block written. The
  storage the two share is emitted once; only enforcement differs.
- **"A citation names at most one thing" is a validation**, not only a check
  constraint. It was Postgres's alone, which left the same generated resource on
  any other data layer with the columns and none of the rule — and ash_sqlite has
  no `check_constraints` section to state it in at all. Postgres still gets the
  constraint as a database-level backstop, so the change there is which layer
  reports a violation first.

### DSL

- A `hateoas` section carrying `type`, `base`, `semantic_type`, and the
  override-only entries `exclude`, `override`, `unrouted`, `method`,
  `semantic_property`, plus `enabled?`.
- An `agentic_hateoas` section with `not_delegable :action` — an action that
  stays advertised (flagged `ah:notDelegable`) but is executed only by a
  credential a configured `commit_authority` deems committing. A refusal is a
  `403` `hydra:Error` carrying, under `ah:projection`, what the action would have
  done — read from the transitions and gate chain, never executed.
