# The Hydra mapping

`ash_hateoas` serves an Ash domain as a [Hydra](https://www.hydra-cg.com/) API:
plain JSON-LD keyed to the Hydra Core Vocabulary
(`http://www.w3.org/ns/hydra/core#`), served as `application/ld+json`. A generic
client discovers the API from the `apiDocumentation` `Link` header on any
response, dereferences it, and drives the API from the operations each resource
node offers — knowing nothing about Ash or this package.

## What maps to what

| Backbone output | Hydra / JSON-LD |
|---|---|
| an affordance | a `hydra:Operation` — `@type: "Operation"`, `hydra:method`, `hydra:title`, `hydra:expects` (a write) and `hydra:returns` (the resulting class, or `owl:Nothing` for a destroy) — plus a `schema:potentialAction` (see below) |
| an operation as a *verb* | `schema:potentialAction` — a schema.org `Action` (subtype inferred from the HTTP method: GET→`ReadAction`, POST→`CreateAction`, PATCH→`UpdateAction`, DELETE→`DeleteAction`; overridable per action with `semantic_action`) with `schema:target` (`urlTemplate`, `httpMethod`, `contentType`). See [semantic-affordances.md](semantic-affordances.md) |
| the affordance set on a record | the node's `hydra:operation` array (same-URL ops) + one `ah:<action>` link node per named sub-action |
| a write action's fields | `hydra:expects` → a `hydra:Class` (with its own `@id`) carrying one `hydra:SupportedProperty` per field |
| a query/search read's fields | a `hydra:IriTemplate` (`hydra:template`, `hydra:mapping` of `hydra:IriTemplateMapping`) |
| `field.allow_nil?` | `hydra:required` (inverted at the edge) |
| a field / attribute | `hydra:property` → `{"@id": <property-iri>}` (a reference; `hydra:property` ranges over `rdf:Property`); the value's type rides alongside as `sh:datatype` (xsd scalars), `sh:nodeKind sh:IRI` (links), `rdfs:range` (structurals via `jsonschema:`), or `schema:rangeIncludes` (unions) |
| a public to-many relationship | on a node: a property keyed by the relationship name → `{"@id": …/:id/<name>, "@type": "Collection"}`; in `ApiDocumentation`: a `hydra:SupportedProperty` whose `hydra:property` is typed `hydra:Link` |
| an operation's possible outcomes | `hydra:possibleStatus` in `ApiDocumentation` — `hydra:Status` nodes derived from the gate chain (403 if authorizers, 422 for a write, 404 for a member op) |
| a collection | a `hydra:Collection` — `hydra:member`, `hydra:totalItems`, `hydra:view` |
| pagination | a `hydra:PartialCollectionView` — `hydra:first` / `previous` / `next` / `last` |
| the API's type catalogue | `hydra:ApiDocumentation` → `hydra:supportedClass` (each a `hydra:Class` with `hydra:supportedProperty` + `hydra:supportedOperation`) |
| the entry point | a node whose `hydra:collection` maps each reachable type to `{"@id", "@type": "Collection"}`; the `ApiDocumentation` carries `hydra:entrypoint` |
| a record's structural links | `hydra:collection` → `{"@id", "@type": "Collection"}`, `hydra:view` → `{"@id", "@type": "Resource"}` (typed node references, never `{href, rel}`) |
| the actor's granted set | an `odrl:permission` list on the node — one `odrl:Permission` per granted affordance (`odrl:action` from the method: GET→`read`, PATCH→`modify`, DELETE→`delete`, else `use`; `odrl:target` = the node). Permission-only: a denied action is omitted, so there is no `odrl:Prohibition`. A `not_delegable?` action carries an `odrl:duty` to `odrl:obtainConsent`. See [semantic-affordances.md](semantic-affordances.md) | one `odrl:Permission` per granted affordance (`odrl:action` from the method: GET→`read`, PATCH→`modify`, DELETE→`delete`, else `use`; `odrl:target` = the node). Permission-only: a denied action is omitted, so there is no `odrl:Prohibition`. A `not_delegable?` action carries an `odrl:duty` to `ah:commit`. See [semantic-affordances.md](semantic-affordances.md) |
| an error / refusal | a `hydra:Error` (`hydra:statusCode`, `hydra:title`, `hydra:description`); RFC 7807 on request |

Facts Hydra core has no term for are carried under an `ah:` extension
vocabulary declared in the emitted `@context`: `ah:commit` (the ODRL duty action a
not-delegable permission is subject to), All are emitted
**prefixed**; the `@context` declares only the prefixes (`ah`, `xsd`, `owl`,
`schema`, `odrl`, `sh`, `jsonschema`), no per-term aliases.

Standard ontology terms (`sh:datatype`, `sh:nodeKind`, `rdfs:range`,
`schema:rangeIncludes`) replace the former `ah:datatype` for value type
information.

### On term spelling (`hydra:` prefix vs bare)

Every Hydra term is emitted **with the `hydra:` prefix**. Under the referenced
`@context` a bare `method` and `hydra:method` expand to the *same* core IRI, so
the choice is cosmetic to a JSON-LD-aware client — but unambiguous to a
raw-JSON reader that keys on the literal string. `@type` **values**
(`"Operation"`, `"Collection"`, `"Class"`, …) are bare tokens the context
resolves. The reasoning, and what is genuinely non-conformant vs cosmetic, is
recorded in [`hydra-conformance-notes.md`](hydra-conformance-notes.md).

## Where an operation attaches

Hydra's `Operation` has no target-URL property — a client invokes an operation
against the resource node it hangs on (`@id`). So:

- an operation whose href *is* the record's own URL (the REST `patch` / `delete`
  at `/:id`) attaches inline on the node's `hydra:operation`;
- a **named sub-action** (`/:id/approve`) needs a distinct URL, so it becomes a
  link property `ah:<action>` whose `@id` is that URL and whose `hydra:operation`
  carries the operation. The distinct URL stays followable.

## Catalogue vs. availability

`ApiDocumentation` deliberately enumerates the operations each class *supports* —
their method and expected input — actor-independently. What a client may invoke
*now*, on *this* record, is the gated `hydra:operation` array on the node. The
documentation is the stable catalogue; the node is the live offer. Authorization
and the state gate apply only to the node.

## Rules a conforming server follows

1. **Only advertise what the actor may invoke.** The per-node operation set is
   resolved per request from the requesting actor's context; two actors may
   receive different operations on the same record.
2. **Never emit a sensitive input's default.** The `hydra:SupportedProperty`
   still appears — the client must know to supply it — but no `ah:default`.
3. **Never expose a private input.** An input the server does not accept from
   clients does not appear as a property.
4. **Collections carry collection-level operations only.** A `hydra:Collection`
   advertises the type's operations (such as create) at the top level; its
   members carry navigation but no per-record operations. This bounds a
   collection response to be independent of its page size.
5. **Affordances are advisory.** The server re-runs authorization, validation and
   state checks on invocation; a stale operation degrades to a clean
   `hydra:Error`, never an invalid write.
