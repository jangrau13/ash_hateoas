# Hydra conformance notes — verified against the normative sources

These are the findings that decide how `ash_hateoas` shapes its JSON-LD, each
checked against a **normative** Hydra source (the vocabulary `.jsonld` or the
spec text), not against memory or a single blog rendering. Where two sources
disagreed, the vocabulary file wins — it is the machine-readable normative
artifact.

## Sources

- **Vocabulary (normative):**
  `https://raw.githubusercontent.com/HydraCG/Specifications/master/spec/latest/core/core.jsonld`
  — the RDF definitions of every Hydra term (each term's `@type`, `range`,
  `domain`).
- **JSON-LD `@context` (normative for term expansion):**
  `http://www.w3.org/ns/hydra/context.jsonld`
  — the term-to-IRI mapping a client applies when expanding a document.
- **Published vocabulary:** `http://www.w3.org/ns/hydra/core` — the same
  definitions, served from the namespace IRI itself.

Re-verified against all three on 2026-08-03. Note every Hydra term quoted here
carries `vs:term_status: "testing"`, and the specification is a Community Group
editor's draft rather than a W3C Recommendation — these definitions can change.

### 1. Bare terms vs. `hydra:`-prefixed keys — cosmetic

Both `"collection"` and `"hydra:collection"` are **identical after JSON-LD
expansion**. The spec text confirms there is *no normative preference*: term
formatting is purely a `@context` concern; the only requirement is that terms
resolve to the correct IRI.

**Consequence:** switching key spelling fixes **no bug**. It only matters to
*raw-JSON* readers (that key on the literal string without JSON-LD expansion) —
and for them a rename is a **breaking change**. The knowledge-base examples
happen to use bare terms, but that is style, not conformance.

**Decision for this package:** keep the `hydra:`-prefixed keys the server already
emits. They are equally conformant and do not break existing raw-JSON consumers.

**This applies to Hydra terms only, and the distinction is load-bearing.** A
bare `collection` is safe because the referenced Hydra context defines it. A
bare key the context does *not* define is a different thing entirely, and a
record node's keys are exactly that — `title`, `comments`, `name` are the
resource's own vocabulary, not Hydra's. Two ways it goes wrong, both measured on
emitted nodes:

- **Undefined → silently dropped.** A processor discards a key no term resolves,
  so `comments` — a relationship link — produced **no triple at all**. The link
  was in the JSON and absent from the graph.
- **Defined by Hydra → captured.** `title` and `name` *are* Hydra terms, so a
  record's own `name` expanded to `hydra:name` ("the name of the link"). Not a
  drop but a **wrong** triple, which a reasoner consumes without complaint.

So the rule is narrower than section 1 states on its own: a bare key is cosmetic
when the context defines it *as the term you mean*. Every other key must be
bound, which is what `Context.context_for/1` now does — each of a node's keys to
the property IRI the ApiDocumentation declares for it.

### 1a. A relative `@id` needs `@base`

`base_url` is optional, so a node may legitimately carry `"@id": "/articles/1"`.
A relative IRI still has to resolve against something, and JSON-LD resolves it
against the document's location. For a document parsed from a string there is no
location, and a processor falls back to the last context it loaded — Hydra's.

Measured: every record in the API expanded to an identity under
**`http://www.w3.org/`**, colliding with any other API's records resolved the
same way. The `@id` reads exactly as intended in the JSON.

`@base` is the term for stating what relative IRIs resolve against, and the
request already knows the origin. It is emitted on every document and is inert
when `base_url` makes the hrefs absolute.

### 1b. Why these were found late

Sections 1, 1a and the `@context` term-definition bug (see
`AshHateoas.Hydra.Context`) share one cause: **every test asserted on raw JSON**,
where all three are invisible. A key bound to nothing, a key bound to the wrong
IRI, and an identity resolved against the wrong base all produce byte-identical
documents.

The package's claim is that a client can read meaning off the wire, and meaning
is what a *processor* extracts. So `json_ld` is a test dependency and
`AshHateoas.Test.JsonLd` expands documents before asserting on them. Hand-rolling
term resolution would only re-encode the emitter's assumptions and agree with
itself.

### 2. `hydra:collection` is a real term — the key was already correct

The normative vocabulary defines it:

```json
{ "@id": "hydra:collection", "@type": "hydra:Link",
  "comment": "Collections somehow related to this resource.",
  "range": "hydra:Collection" }
```

(An earlier reading of the *prose* spec claimed no such predicate existed — that
was wrong; the vocabulary `.jsonld` is authoritative and has it.)

Because its `range` is `hydra:Collection`, the **value** should be a node
reference to a collection: `{"@id": <url>, "@type": "hydra:Collection"}`.

- `hydra:view` is likewise a `hydra:Link`; its value is the
  `PartialCollectionView` (or, for an "up"/parent link, a `hydra:Resource`
  reference).
- `hydra:member` is a `hydra:Link` whose values are the member nodes.

### 3. `{href, rel}` was the genuine bug (this is what the requirement doc flags)

`rel` and `href` are **web-linking (RFC 8288 / HAL) terms, not Hydra terms**.
They do not appear in the Hydra vocabulary at all, so under the Hydra `@context`
they expand to nothing meaningful. Emitting a collection link as
`{"href": …, "rel": "collection"}` is therefore non-conformant.

**Fix:** the value of `hydra:collection` / `hydra:view` is a typed node reference
`{"@id": …, "@type": "hydra:Collection" | "hydra:Resource"}`. This is the only
value-shape change required at the navigation layer.

### 4. `hydra:property` is `rdf:Property` — a property IRI reference, not a datatype-typed node

```json
{ "@id": "hydra:property", "@type": "rdf:Property", "range": "rdf:Property" }
```

So inside a `SupportedProperty` (and an `IriTemplateMapping`), `hydra:property`'s
value is a **reference to the property itself** — `{"@id": <property-iri>}` (a
bare IRI string is the compacted equivalent). The value's **datatype/range is a
fact about the property, not about this reference** — it does not belong *on* the
`hydra:property` node.

**Previous bug:** the renderer emitted
`"hydra:property": {"@id": …, "@type": "xsd:string"}`. That `@type` asserts *the
property is an xsd:string*, which is wrong (a property is an `rdf:Property`, and
`xsd:string` is the datatype of its *values*). The datatype must move off the
property reference.

**Fix:** `hydra:property` → `{"@id": <iri>}`; carry the value datatype separately
under a standard ontology term (`sh:datatype`, `sh:nodeKind`, `rdfs:range`, or
`schema:rangeIncludes`) so no information is lost while the property reference
stays honest.

### 5. `hydra:expects` / `hydra:returns` — reference a Class

```json
{ "@id": "hydra:expects", "@type": "hydra:Link",
  "rangeIncludes": ["rdfs:Resource","hydra:Resource","rdfs:Class","hydra:Class"] }
{ "@id": "hydra:returns", "@type": "hydra:Link",
  "rangeIncludes": ["rdfs:Resource","hydra:Resource","rdfs:Class","hydra:Class"] }
```

The normative value is a **Class reference** — `{"@id": <class-iri>}`, which is
what `rangeIncludes` above establishes.

**On `owl:Nothing` for a destroy — dropped, and the citation behind it was
wrong anyway.** An earlier revision of this file attributed
`"returns": "…owl#Nothing"` to the specification's examples. That citation does
not hold up: re-verified against the current sources, the token `Nothing` occurs
**zero** times in the spec prose (864 KB), zero times in `core.jsonld`, and zero
times in the published vocabulary at `http://www.w3.org/ns/hydra/core`. The only
`owl` mentions in any of them are the prefix declaration and `owl:Ontology` on
the vocabulary document itself — Hydra says nothing about OWL anywhere.

The practice went with it, for a better reason than provenance: **a destroy now
returns the record it destroyed**, so there is a class to name. Ash hands the
record back for the asking (`return_destroyed?: true`), and returning it saves a
client that wants to show what it deleted from having to GET first and hold the
result across the delete. `hydra:returns` names the resource's own class, like
every other operation that yields a record.

`owl:Nothing` survives only where a destroy action genuinely yields no record,
which sends no body at all. Had it been kept for the ordinary case it would
still have been defensible — it is the empty class, so "an instance of this is
returned" is unsatisfiable, which is the honest reading of "no body" — but it is
now the narrow case rather than the rule.

- An **inline class node with an `@id`** (carrying `supportedProperty`) is
  *permitted* — it is still a class reference, just an expanded one — but the
  minimal conformant form is the bare `{"@id"}` reference.
- **Previous gap:** `hydra:returns` was never emitted. It should be present:
  the resource's own class IRI for read/create/update, and for destroy too —
  it returns the record it destroyed.
- **Previous nit:** the `hydra:expects` class was an **anonymous blank node**
  (no `@id`) — a client cannot reference or dedupe it. Giving it an `@id`
  (`<class>/<action>Input`) makes it a real, referenceable class.

### 6. No `EntryPoint` class exists in Hydra — resolved by omission

Confirmed absent from both the vocabulary and the fetched `@context` (the token
`EntryPoint` is `<<NOT IN CONTEXT>>`). Hydra models the entry point only as the
target of `hydra:entrypoint` on `ApiDocumentation`; the entry-point *resource*
is typed by its own domain class, not a Hydra one.

**Resolution:** the root document now carries no `@type` — `hydra:collection`
alone is sufficient for a generic Hydra client to navigate the API.

### 7. A named sub-action as a link node — conformant but redundant

`ash_hateoas` emitted a named sub-action (`/:id/approve`) as a link property
`ah:<action>` whose `@id` was the URL and whose `hydra:operation` held a
single-element array. Nothing in Hydra forbids this: an extension term may take
an object, and a resource node may carry a `hydra:operation`. So the shape was
**conformant**.

It was redundant. The action was named twice (as the key, and as `ah:action`);
the array was length one by construction, since `AshHateoas.Route` holds one
action and one method; and a client had two traversal paths for one question,
the second over keys whose names it could not know in advance.

The one thing that would have justified it — the URL sitting on a followable
edge — was not true. `AshHateoas.Hydra.Plug` routes GETs through `serve_get/4`,
matching `:member`, `:collection` and `:related` only; a sub-action path is
matched by `match_write/3`, reached for POST, PATCH and DELETE. A GET on it is a
404, now asserted in `hydra/followable_test.exs`.

**Resolution:** every affordance is one entry in `hydra:operation`, and an
operation whose URL is not the node's own states it as `ah:href` — a minted
`owl:ObjectProperty` with domain `hydra:Operation` and range `hydra:Resource`.
Hydra gives `Operation` no target-URL property, so an extension term is the only
place that URL can go; `schema:target` was passed over because it ranges over
`schema:EntryPoint` and brings a second model of an invocation with it.

This is a **design change, not a bug fix** — the old shape was conformant, and
the new one is smaller. It belongs in the changelog as such.

### 8. A multi-valued `@type` on an `Operation` — conformant

An operation carries `"@type": ["Operation", "<vocab>#Class/actionAction"]`, in
the node and in the catalogue alike. (A third element, a class per route, was
emitted for a while and withdrawn — see §12.)

Nothing in Hydra forbids this. JSON-LD 1.1 §4.2 defines `@type` as taking one
IRI *or an array of them*, and Hydra defines `hydra:Operation` as a class
without saying it is the only one an operation may be an instance of. A generic
Hydra client filters on `Operation` and finds it exactly where it always was.

It is worth a row anyway, because a **strict** consumer may not expect it: code
written as `if (op["@type"] === "Operation")` breaks where
`op["@type"].includes("Operation")` does not. That is a JSON-shape assumption
rather than a conformance one, and it is the kind of thing that goes unnoticed
until a document changes.

**Resolution:** kept. The bare `Operation` stays first in the array, so a
consumer reading position 0 also survives.

### 9. An operation's address under an `ah:` term rather than `hydra:expects`

A `hydra:supportedOperation` now carries `ah:template`, a `hydra:IriTemplate`
describing the URL the operation is sent to. The obvious alternative was
`hydra:expects`, which already takes an `IriTemplate` on a node's GET
affordance, so the question is why a second term exists at all.

**Hydra mints no term for an operation's target.** `hydra:Operation` is defined
with `hydra:method`, `hydra:expects`, `hydra:returns` and `hydra:possibleStatus`
and nothing that says *where*. That is a gap in the vocabulary rather than a
claim that an operation has no target — a client cannot invoke anything without
a URL — and it is the same gap `ah:href` fills on a node. `ah:template` is its
catalogue-side twin: the node states the address it resolved, the documentation
describes a class and states how to build one.

`hydra:expects` is the wrong home for it. Hydra defines `expects` as "the
information expected by the Web API", which is the request **body**: a template
carrying a path variable and no body is not an input description, and putting
both under one key would leave a client reading the value's `@type` to learn
which question the key was answering. So in the documentation `hydra:expects`
now means a body and only a body; a GET's query variables are part of the
address and ride in the template with the path.

A node is unchanged — its GET affordance still renders query arguments as an
`IriTemplate` under `hydra:expects`, where the address is already resolved as
`ah:href` and the template really is about what to send.

**Resolution:** `ah:template` is declared in `AshHateoas.Hydra.Ontology` as an
`owl:ObjectProperty` with domain `hydra:Operation` and range
`hydra:IriTemplate`, beside `ah:href`. Conformant: an extension term on an
operation node asserts nothing Hydra denies.

### 10. `hydra:memberAssertion` with `property` and `object` — one of three legal pairs

A collection route's `hydra:returns` names a minted collection class
(`<vocab>#Exam/Collection`), declared `rdfs:subClassOf hydra:Collection` with

```json
"hydra:memberAssertion": {
  "hydra:property": {"@id": "rdf:type"},
  "hydra:object": {"@id": "<vocab>#Exam"}
}
```

and the served collection carries the identical assertion.

The spec is normative about the arity: *"A memberAssertion MUST use two and only
two of the subject, property and object predicates."* This uses the
property/object pair, which is the spec's own worked example for a strongly
typed collection (`api:UserCollection` with `{property: rdf:type, object:
api:User}`). `hydra:subject` is the third and is deliberately absent: on a class
it would name one specific parent record, which is an instance-level fact; on a
response it would restate the collection's own `@id`.

Stating it on the **response** as well as on the class is not a second claim. It
is the same triple pattern, built by one function
(`AshHateoas.Hydra.Collection.member_assertion/1`), because a client holding one
response and no catalogue cannot otherwise tell what it is a collection of — and
an empty page carries no members to infer it from.

**Resolution:** kept, both places. The alternative — `hydra:returns` naming the
member class for a collection route — was not a conformance question but a false
statement: `GET /exam` answers with `hydra:member` and `hydra:totalItems`, which
an Exam has neither of.

### 11. `possibleStatus` carrying successes — explicitly permitted

The list used to hold failures only (403, 422, 404), so every catalogue entry
read as an operation that can only fail.

Hydra does not restrict it. An Operation *"may document the status codes that
might be returned by the server using the `possibleStatus` property"*, with no
mention of failure, and the spec adds that the list *"has not to be considered
as an extensive list of all potentially returned status codes; it is merely a
hint"*. Nothing there licenses omitting the one status a caller most needs.

**Resolution:** the success status is derived from the route kind and listed
first — 200 for a read, an index, an update and a generic action; 201 for a
create; 200 **and** 204 for a destroy, since `respond_destroy/7` answers 200 with
the destroyed record and 204 when the data layer yields none. Listing both is
what settles `hydra:returns` naming the resource's class on a destroy: the class
is what comes back when a body does, and the 204 is where "sometimes there is
none" is stated. Naming `owl:Nothing` alongside it would be an intersection with
the empty class — unsatisfiable, and read as "returns nothing, ever".

### 12. Two vocabulary nodes that stated nothing — withdrawn

Neither was non-conformant. Both were noise, and both were introduced by the
change that gave an operation a class IRI.

**A class per route.** `<vocab>#Exam/sitAction/patch rdfs:subClassOf
<vocab>#Exam/sitAction`, minted for every route onto every action. Where an
action had one route — 48 of 70 in a captured API — the subclass had exactly its
parent's members, added no property and constrained nothing: in a vocabulary, a
node saying a thing is itself. And its segment was `%AshHateoas.Route{}.type`, an
Ash route kind that spells like an HTTP method, so the axiom parsed as "sitting
an exam is a kind of PATCH" — the inference `renderer.ex` explicitly refuses when
it declines to derive `schema:ReadAction` from a GET.

The remaining 22 were the two routes onto each of 11 primary reads, and they were
minted because those two catalogue entries differed in `hydra:possibleStatus` and
nothing else. That was the wrong end of the problem: they were indistinguishable
because the catalogue stated no address and declared the same return class for
both. §9 and §10 fix that end, so the two are told apart by what they do.

**Resolution:** withdrawn. `Context.route_class_iri/3` is gone, and a catalogue
entry's `@type` is the same two-element list a node carries — so the join between
the documents is an identity rather than a walk up a subclass chain.

**`rdfs:isDefinedBy` on every term.** 232 of 237 `@included` nodes carried
`{"@id": "<namespace>#"}`, all the same value, and that value was the `@id` of the
`owl:Ontology` node in the same document. True, and computable from the node's own
`@id` by truncating at the fragment.

The property earns its place where a term IRI does not say where its definition
lives: `http://purl.org/dc/terms/title` is a **slash** IRI and no mechanical rule
reaches `http://purl.org/dc/terms/`. This package mints **hash** IRIs, so RDF's
own rule already answers it, and restating it per term states the rule as data —
15 KB of a 358 KB document.

**Resolution:** dropped from the term nodes; the `owl:Ontology` node stays, since
that is what makes the namespace a thing in the graph rather than a prefix in a
`@context`. `hydra-mapping.md` records the two changes that would bring it back:
slash IRIs, or more than one namespace emitted as first-class nodes.

### 13. A collection-level operation on a member class — wrong subject

`hydra:supportedOperation` on a `hydra:Class` says: an *instance* of this class
supports this operation, invoked against that instance. That is Hydra's whole
model for where an operation attaches, and it is why `hydra:Operation` has no
target-URL property of its own.

Every derived route used to hang off the one class a resource yields, and some
routes are not member routes. `vocab#Exam` advertised an operation POSTed to
`/exam` and another `GET` at `/exam`: you cannot POST to an exam to create an
exam, and listing exams is not something one exam does. On a captured API that
was 34 of 115 operations filed under a subject they are not about.

It is also where the doubling came from. One Ash `read` produced two entries
under `vocab#Exam`, because both its routes were forced under the member class —
and the two then had to be told apart by something, which is what produced a
class per route (§12) and, before that, two entries a client could not
distinguish at all.

**Resolution:** a resource yields a second supported class, `<Class>/Collection`,
and collection-level operations are filed there. The split is by the route's
**path** — `:id` in it means the member class — rather than by route kind, which
stopped tracking it the moment a named transition became a `POST` (§14). The
collection class is the same one `hydra:returns` already named, so it is now
described as well as returned; a collection response and every entry-point row
name it in `@type`, so a client reaching either can look up what it supports.

### 14. `PATCH` for a named transition — wrong method

Every non-primary `update` action became a `PATCH` at `/:id/<name>`, because the
route kind was read off the Ash action's type. In a captured API that put one verb
on three unlike operations of one class: a real partial modification, a transition
taking one argument, and a transition taking nothing.

RFC 5789 defines `PATCH` by its body — *"The enclosed entity contains a set of
instructions describing how a resource currently residing on the origin server
should be modified to produce a new version"*. `open_sitting` carries no entity at
all, so it was a `PATCH` with no patch document, which has no defined meaning.
RFC 9110 gives the method for this: `POST` performs *"resource-specific
processing on the request content"*.

**Resolution:** `:patch` for the primary update, `:post` for a named transition.
`hydra:method` carries a real distinction again. A named **destroy** keeps
`DELETE` — the argument above is about `PATCH` semantics and does not carry over
on its own, and moving a URL's verb wants an argument actually made. The author
override (`method :sit, :patch`) is now read for any non-primary action, not only
for a generic one; the router reads it too, so the catalogue and the route table
cannot disagree.

**Breaking**: every sub-action URL's verb moves, and every client and captured
fixture with it.

### 15. An omitted `hydra:expects` — silence read as a statement

An operation whose action takes nothing carried no `hydra:expects`; 71 of 115 in
a captured document, 17 of them `PATCH`. Absence in RDF is the absence of a
statement, not a negative one, so a client could not tell **"send an empty
body"** from **"this document does not describe the body"** — and for a write
that is a guess about a write.

**Resolution:** every `POST`/`PATCH`/`PUT` declares its input class, with an
empty `hydra:supportedProperty` where the action takes nothing. *"These are the
properties, and there are none"* is a statement.

Not `owl:Nothing`, although `Renderer.put_returns/3` reserves it for a response
with no body: `hydra:expects owl:Nothing` says an instance of the empty class is
expected, which is unsatisfiable and reads as "no valid request to this operation
exists". Right on the way out, wrong on the way in — the two directions are not
symmetric.

`GET` and `DELETE` are left alone. RFC 9110 says a client should not generate
content in a `GET`, and a `DELETE` body has no defined semantics, so omission
there is unambiguous. A `DELETE` whose action takes arguments still describes
them.

Every input class is now **declared** in `@included` too — 68 referenced and 0
declared before, which was the ontology's own invariant broken in the one place
its resource walk cannot reach. The class is declared; its properties are not,
on the rule that already governs arguments: `approve` takes a `note`, and a
Document does not *have* one.

### 16. A node repeating what holds in every state — conformant, and paid for per response

A node's operation carried `@type`, `ah:href`, `hydra:method`, `hydra:expects`
and `hydra:returns`. Only the first two vary per request: which operations are
present is decided by `Ash.can?/3` and the state gate, and `ah:href` holds the
record's id. The method, the input and the return are read off the *action*, so
they are the same for every record of the class and every actor who may invoke
it.

Nothing about it was non-conformant. It was 92 statements repeated across 13
responses that the catalogue already made once: 40 node operations occupying
22,354 bytes where the two keys occupy 6,729.

**Resolution:** a node's operation states `@type` and `ah:href`. The class in
`@type` is the key that joins the two documents, which is what
`change-request-classed-affordances.md` minted it for. The rule is stated so a
client implements it once:

> the catalogue states the shape; a node may restate it; a node that says nothing
> means the catalogue's answer stands.

**Breaking, and the largest break in this series.** A consumer reading a node's
operation for its method, input or return finds none of them, and a node is no
longer readable on its own — a test, a log line, or a client that ignored the
`Link` header cannot say what a request looks like. Every response carries
`Link: <…>; rel="…apiDocumentation"` and the catalogue is one cacheable fetch,
so **that header is load-bearing now**: a path that omits it is a correctness bug
rather than a missing convenience.

## Net: what is actually non-conformant (and must change) vs. cosmetic

| # | Item | Verdict | Action |
|---|---|---|---|
| 1 | bare vs `hydra:` keys, **for Hydra terms** | **cosmetic** — both expand identically | keep existing `hydra:` keys; no wire change |
| 1 | bare keys for a **resource's own** properties | **non-conformant** — dropped, or captured by the Hydra context | bind every node key to its declared property IRI |
| 1a | relative `@id` with no `@base` | **wrong** — identities resolved under `w3.org` | emit `@base` from `base_url` or the request origin |
| 2 | `hydra:collection` key | already correct | keep |
| 3 | `{href, rel}` link values | **non-conformant** (not Hydra terms) | → `{"@id", "@type"}` node refs |
| 4 | `hydra:property` datatype-typed node | **wrong** (`@type` mistypes the property) | → `{"@id"}` ref; datatype to standard ontology term (`sh:datatype` etc.) |
| 5 | missing `hydra:returns` | **incomplete** | emit `returns` (the class IRI; a destroy returns its record) |
| 5 | anonymous `hydra:expects` class | nit (blank node) | give it an `@id` |
| 6 | `"@type": "EntryPoint"` | **non-conformant** (undefined term) | → `ah:EntryPoint` |
| 7 | `ah:<action>` link node wrapping one operation | **conformant but redundant** — named twice, array always length one, two traversal paths | flatten into `hydra:operation`; the URL becomes `ah:href` |
| 8 | multi-valued `@type` on an `Operation` | **conformant** — JSON-LD allows an array; Hydra does not claim exclusivity | keep; `Operation` stays first in the array |
| 9 | a catalogue entry with no address | **incomplete** — an entry a client cannot issue | emit `ah:template`, an `IriTemplate` per route; `hydra:expects` narrows to the body |
| 10 | `hydra:returns` naming the member class on a collection route | **wrong** — `GET /exam` answers with a Collection | name a minted collection class carrying `hydra:memberAssertion`; the response carries the same assertion |
| 11 | `possibleStatus` listing only failures | **incomplete** — Hydra places no such restriction | add the success status per route kind; a destroy declares 200 and 204 |
| 12 | a class per route | **conformant, vacuous** — co-extensive with its parent, and its segment reads as an HTTP method | withdrawn; two routes onto one action share the action's class |
| 12 | `rdfs:isDefinedBy` on every term | **conformant, redundant** — computable from a hash IRI | dropped from term nodes; the `owl:Ontology` node stays |
| 13 | a collection-level operation on the member class | **wrong subject** — an instance of the class cannot answer it | a second supported class, `<Class>/Collection`; split by the route's path |
| 14 | `PATCH` for a named transition | **wrong method** — RFC 5789 defines PATCH by a body a transition does not send | `:post` for a sub-action, `:patch` for the primary update; author override honoured by the router too |
| 15 | omitted `hydra:expects` on a fieldless write | **incomplete** — silence is not a statement | declare the input class with an empty property list; GET and DELETE left alone; declare every input class |
| 16 | a node repeating method / expects / returns | **conformant, repeated** — none of the three varies per request | a node states `@type` and `ah:href`; the catalogue states the shape once |

Rows 3–6 change the wire, as do the two rows added later (a resource's own bare
keys, and `@base`). Renaming *Hydra* keys is intentionally **not** done: it is
cosmetic and would break raw-JSON consumers for no conformance gain.

Note the two later rows change only the `@context`, not the keys themselves — a
raw-JSON consumer sees the same document, while a JSON-LD consumer finally sees
the triples it always should have.

Rows 7 and 8 are the exceptions to the framing of this table: neither is a
conformance defect, and both are recorded here so that a reader comparing an old
capture against a new one finds the shape change written down beside the
others.

