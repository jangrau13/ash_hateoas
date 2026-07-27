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
  `http://www.w3.org/ns/hydra/context.jsonld` — what a bare term expands to.
  Fetched and inspected directly (28 321 bytes).
- **Spec text:** `https://www.hydra-cg.com/spec/latest/core/` and the
  Markus-Lanthaler mirror. Explicitly self-described as *"a work in progress …
  several sections are incomplete, missing, or outdated"* — so it is used only
  to confirm the vocabulary, never over it.
- **Worked examples:** the local knowledge base `docs/03-examples.md`,
  `docs/06-json-ld.md`, and the Hydra cookbook.

## Findings

### 1. Bare terms vs `hydra:` prefix — cosmetic, NOT a conformance axis

The `@context` at `.../hydra/context.jsonld` maps **both** the bare token and the
`hydra:`-prefixed token to the same IRI. Verified directly against the fetched
context:

| token | expands to |
|---|---|
| `collection` | `http://www.w3.org/ns/hydra/core#collection` |
| `hydra:collection` | `http://www.w3.org/ns/hydra/core#collection` |
| `member`, `method`, `expects`, `supportedClass`, … | all aliased bare |

So `"collection"` and `"hydra:collection"` are **identical after JSON-LD
expansion**. The spec text confirms there is *no normative preference*: term
formatting is purely a `@context` concern; the only requirement is that terms
resolve to the correct IRI.

**Consequence:** switching key spelling fixes **no bug**. It only matters to
*raw-JSON* readers (that key on the literal string without JSON-LD expansion) —
and for them a rename is a **breaking change**. The knowledge-base examples
happen to use bare terms, but that is style, not conformance.

**Decision for this package:** keep the `hydra:`-prefixed keys the server already
emits. They are equally conformant and do not break existing raw-JSON consumers.

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
under an `ah:` extension term (`ah:datatype`) so no information is lost while the
property reference stays honest.

### 5. `hydra:expects` / `hydra:returns` — reference a Class

```json
{ "@id": "hydra:expects", "@type": "hydra:Link",
  "rangeIncludes": ["rdfs:Resource","hydra:Resource","rdfs:Class","hydra:Class"] }
{ "@id": "hydra:returns", "@type": "hydra:Link",
  "rangeIncludes": ["rdfs:Resource","hydra:Resource","rdfs:Class","hydra:Class"] }
```

The normative value is a **Class reference** — `{"@id": <class-iri>}`. The spec's
examples show `"expects": "…/vocab#Comment"` and
`"returns": "http://www.w3.org/2002/07/owl#Nothing"` (a `DELETE` returns
nothing → `owl:Nothing`).

- An **inline class node with an `@id`** (carrying `supportedProperty`) is
  *permitted* — it is still a class reference, just an expanded one — but the
  minimal conformant form is the bare `{"@id"}` reference.
- **Previous gap:** `hydra:returns` was never emitted. It should be present:
  the resource's own class IRI for read/create/update, `owl:Nothing` for destroy.
- **Previous nit:** the `hydra:expects` class was an **anonymous blank node**
  (no `@id`) — a client cannot reference or dedupe it. Giving it an `@id`
  (`<class>/<action>Input`) makes it a real, referenceable class.

### 6. No `EntryPoint` class exists in Hydra

Confirmed absent from both the vocabulary and the fetched `@context` (the token
`EntryPoint` is `<<NOT IN CONTEXT>>`). Hydra models the entry point only as the
target of `hydra:entrypoint` on `ApiDocumentation`; the entry-point *resource*
is typed by its own domain class, not a Hydra one.

**Previous bug:** the root document used `"@type": "EntryPoint"`, an
**undefined term** under the Hydra `@context`. It must be typed with a defined
term — this package's own `ah:EntryPoint` (declared via the `ah:` prefix in the
emitted `@context`) — or `hydra:Resource`.

## Net: what is actually non-conformant (and must change) vs. cosmetic

| # | Item | Verdict | Action |
|---|---|---|---|
| 1 | bare vs `hydra:` keys | **cosmetic** — both expand identically | keep existing `hydra:` keys; no wire change |
| 2 | `hydra:collection` key | already correct | keep |
| 3 | `{href, rel}` link values | **non-conformant** (not Hydra terms) | → `{"@id", "@type"}` node refs |
| 4 | `hydra:property` datatype-typed node | **wrong** (`@type` mistypes the property) | → `{"@id"}` ref; datatype to `ah:datatype` |
| 5 | missing `hydra:returns` | **incomplete** | emit `returns` (class IRI / `owl:Nothing`) |
| 5 | anonymous `hydra:expects` class | nit (blank node) | give it an `@id` |
| 6 | `"@type": "EntryPoint"` | **non-conformant** (undefined term) | → `ah:EntryPoint` |

Only rows 3–6 change the wire; row 1 (the bare-terms rename) is intentionally
**not** done, because it is cosmetic and would break raw-JSON consumers for no
conformance gain.
