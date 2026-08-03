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

Rows 3–6 change the wire, as do the two rows added later (a resource's own bare
keys, and `@base`). Renaming *Hydra* keys is intentionally **not** done: it is
cosmetic and would break raw-JSON consumers for no conformance gain.

Note the two later rows change only the `@context`, not the keys themselves — a
raw-JSON consumer sees the same document, while a JSON-LD consumer finally sees
the triples it always should have.
