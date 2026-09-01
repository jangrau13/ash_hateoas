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
| an affordance | a `hydra:Operation` — `@type: ["Operation", <the action's own class>]`, `hydra:method`, `hydra:title`, `hydra:expects` (a write) and `hydra:returns` (the resulting class — including a destroy, which returns the record it destroyed) |
| an operation's **identity** | a minted class IRI, `<Class>/<action>Action`, in the operation's `@type`. `Operation` alone is carried by every operation and separates none of them; this is what a client resolves, subclasses and annotates against |
| one **route** onto an action | **nothing.** Two routes onto one action share the action's class, since they invoke the same action; they are told apart by `ah:template` and `hydra:returns`, which are facts about the call. A subclass per route was minted for a while and withdrawn — for an action with one route it had exactly its parent's members, and its segment (`%Route{}.type`) read as an HTTP method |
| an operation's URL | **`ah:href`**, on every operation. Hydra core mints no term for it, which is a gap in the vocabulary rather than a claim that an operation has no target — it plainly has one. No `schema:target`: it ranges over `schema:EntryPoint`, a whole second model of an invocation for the sake of one URL |
| an operation's *declared role* | `rdfs:subClassOf` on the action's class, in the `ApiDocumentation`'s `@included` — a schema.org `Action` naming what the operation is *for*, the one thing Hydra cannot express. Declared **only** where a `semantic_action` supplies it; a subtype inferred from the HTTP method would restate `hydra:method`. See [semantic-affordances.md](semantic-affordances.md) |
| the affordance set on a record | the node's `hydra:operation` array — **every** affordance, including named sub-actions. Each entry carries `@type` and `ah:href` and nothing else: those are the two facts that vary per request, and the rest of an operation's shape is stated once in the catalogue, joined by the class in `@type` |
| which class a **collection-level** operation is filed under | `<Class>/Collection`, a second `hydra:supportedClass` per resource. `hydra:supportedOperation` on a class says an *instance* of it supports the operation — you cannot POST to an exam to create an exam, and listing exams is not something one exam does. Split by the route's **path**: `:id` in it means the member class |
| the method for a **named transition** | `POST`, not `PATCH`. RFC 5789 defines `PATCH` by its body — "a set of instructions describing how a resource … should be modified" — and a transition sends no such thing; `open_sitting` sends nothing at all. RFC 9110's `POST` is "resource-specific processing on the request content". The primary update keeps `PATCH`, and `method :sit, :patch` is the author's override |
| a write action's fields | `hydra:expects` → a `hydra:Class` (with its own `@id`) carrying one `hydra:SupportedProperty` per field. Emitted for **every** `POST`/`PATCH`/`PUT`, with an empty property list where the action takes nothing: absence in RDF is the absence of a statement, so a client could not tell "send an empty body" from "the body is undescribed". `GET` and `DELETE` are left alone — RFC 9110 says a client should not send content in a `GET` and a `DELETE` body has no defined semantics, so silence there is unambiguous |
| a query/search read's fields | a `hydra:IriTemplate` (`hydra:template`, `hydra:mapping` of `hydra:IriTemplateMapping`). On a **node** it rides under `hydra:expects`, where the address is already resolved as `ah:href`; in the **catalogue** it is part of the address and rides in `ah:template` with the path |
| a route's address, in the catalogue | **`ah:template`**, a `hydra:IriTemplate` on every `hydra:supportedOperation`. `%Route{}.route` is `/exam/:id` or `/exam` — actor- and state-independent, which is exactly what a catalogue holds. Without it a client holding only the documentation could see that a class supports nine operations and issue none of them, and a sub-action gated off by the record's state had no URL in **any** document. A collection route needs no variables and stays a template rather than becoming a second shape |
| `field.allow_nil?` | `hydra:required` (inverted at the edge) |
| a field / attribute | `hydra:property` → `{"@id": <property-iri>}` (a reference; `hydra:property` ranges over `rdf:Property`); the value's type rides alongside as `sh:datatype` (xsd scalars), `sh:nodeKind sh:IRI` (links), `rdfs:range` (structurals via `jsonschema:`), `rdfs:range ah:Script` + `ah:scriptLanguage` (scripts), or `schema:rangeIncludes` (unions) |
| a public `belongs_to`'s generated key | **nothing.** Ash defines `<name>_id` and it inherits the relationship's `public?`, so it reaches no emitter path: the link states the edge, and the key is storage the write path refuses anyway. A key the domain declared itself stays — the signal is `define_attribute?` on the relationship, never the `_id` suffix |
| a public to-many relationship | on a node: a property keyed by the relationship name → a `hydra:Collection` whose `@id` is the relationship's route (`/articles/7/comments`), carrying `hydra:totalItems` and its members — as bare `{"@id"}` references when unloaded (bounded, with a `hydra:view` to page), expanded in place when the action loaded them or `?load=<name>` asked; in the ontology: an `owl:ObjectProperty` + `hydra:Link` whose `rdfs:range` is the property's own **collection class** (not the member class — the value *is* the collection, so a member range would say the collection is one of its own members) |
| a to-many's member class | a `hydra:Collection` subclass carrying `hydra:memberAssertion` (`hydra:property rdf:type`, `hydra:object <class>`) — the spec's pattern for a strongly typed collection. Named per owning property (`#ArticleComments`), since two properties may reach one class by different relationships |
| a **narrowed** to-many (`has_many … filter: expr(kind == :review)`) | the same, asserting the class the filter names rather than the destination — but **only** where the filter pins an attribute to a single literal *and* a class of that name is declared in the destination's domain. Any other filter falls back to the destination: weaker, never wrong. Without this every narrowing of one base asserts that base, leaving the collections identical apart from `rdfs:label` — and a label is not a claim |
| an operation's possible outcomes | `hydra:possibleStatus` in `ApiDocumentation` — `hydra:Status` nodes. The **success** first, from the route kind (200 read/index/update/generic, 201 create, 200 *and* 204 for a destroy), then the gate chain (403 if authorizers, 422 for a write, 404 for a member op). Listing failures alone made every entry read as an operation that can only fail, and left a generated handler to hardcode which status means success |
| a collection | a `hydra:Collection` — `hydra:member`, `hydra:totalItems`, `hydra:memberAssertion` (what its members are), `hydra:view` |
| what a **collection route** returns | the resource's own minted collection class, `<Class>/Collection`, not the member class. `GET /exam` answers with `hydra:member` and `hydra:totalItems`, which an Exam has neither of — so the two routes onto a primary read used to differ only in a status list and one of them was untrue. `hydra:Collection` alone would be true and would not say *of what*, so the class carries a `hydra:memberAssertion` and the served collection carries the identical one |
| pagination | a `hydra:PartialCollectionView` — `hydra:first` / `previous` / `next` / `last` |
| the API's type catalogue | `hydra:ApiDocumentation` → `hydra:supportedClass` (each a `hydra:Class` with `hydra:supportedProperty` + `hydra:supportedOperation`) |
| the entry point | a node whose `hydra:collection` maps each reachable type to `{"@id", "@type": "Collection"}`; the `ApiDocumentation` carries `hydra:entrypoint` |
| a record's structural links | `hydra:collection` → `{"@id", "@type": "Collection"}`, `hydra:view` → `{"@id", "@type": "Resource"}` (typed node references, never `{href, rel}`) |
| the actor's granted set | an `odrl:permission` list on the node — one `odrl:Permission` per granted affordance, naming under `ah:action` the very class IRI the operation carries in its `@type`, so the two lists join (`odrl:action` from the method: GET→`read`, PATCH→`modify`, DELETE→`delete`, else `use`; `odrl:target` = the URL the action is invoked on, so a sub-action targets its own `ah:href` rather than the record). Permission-only: a denied action is omitted, so there is no `odrl:Prohibition`. A `not_delegable?` action carries an `odrl:duty` to `odrl:obtainConsent`. See [odrl-mapping.md](odrl-mapping.md) |
| an error / refusal | a `hydra:Error` (`hydra:statusCode`, `hydra:title`, `hydra:description`); RFC 7807 on request |

Facts Hydra core has no term for are carried under an `ah:` extension
vocabulary declared in the emitted `@context`: which operation a permission is
about (`ah:action`), an operation's invocation URL (`ah:href`) and how to build
one (`ah:template`), error metadata keys (`ah:*`). All are emitted **prefixed**; the `@context` declares only the
prefixes (`ah`, `xsd`, `owl`, `schema`, `odrl`, `sh`, `jsonschema`), no per-term
aliases.

Standard ontology terms (`sh:datatype`, `sh:nodeKind`, `rdfs:range`,
`schema:rangeIncludes`) replace the former `ah:datatype` for value type
information.

One value type has no published term and so mints one: an
`AshHateoas.Type.Lua` attribute ranges on **`ah:Script`**, declared in the
ontology as an `rdfs:Datatype` restricting `xsd:string`, with
**`ah:scriptLanguage`** naming the grammar. `xsd:string` is true of source code
and useless — it is what leaves a client rendering a formula as prose — while
the restriction keeps a consumer that does not know the term reading a string.

An **operation's inputs** carry the same pair as `sh:datatype` +
`ah:scriptLanguage`, since an argument is not a property of any class and so
has no declaration to carry a range. Both are read from the type itself, so the
declaration and the usage site state one fact rather than two that can drift.

### On term spelling (`hydra:` prefix vs bare)

Every Hydra term is emitted **with the `hydra:` prefix**. Under the referenced
`@context` a bare `method` and `hydra:method` expand to the *same* core IRI, so
the choice is cosmetic to a JSON-LD-aware client — but unambiguous to a
raw-JSON reader that keys on the literal string. `@type` **values**
(`"Operation"`, `"Collection"`, `"Class"`, …) are bare tokens the context
resolves. The reasoning, and what is genuinely non-conformant vs cosmetic, is
recorded in [`hydra-conformance-notes.md`](hydra-conformance-notes.md).

## Where an operation attaches

**`hydra:operation` is the whole answer.** Every affordance the actor holds is
one entry in that array, and a client asking "what may I invoke on this node?"
reads it and nothing else.

**Every operation states where it is invoked, as `ah:href`.**

Hydra core mints no term for an operation's target. That is a gap in the
vocabulary, not a statement that an operation has no target: a client cannot
invoke anything without a URL, so the URL exists and something has to carry it.

```json
"hydra:operation": [
  { "@type": ["Operation", "vocab#Document/updateAction"],
    "hydra:method": "PATCH",
    "ah:href": { "@id": "/documents/7" },
    "hydra:returns": { "@id": "vocab#Document" } },

  { "@type": ["Operation", "vocab#Document/approveAction"],
    "hydra:method": "PATCH",
    "ah:href": { "@id": "/documents/7/approve" },
    "hydra:returns": { "@id": "vocab#Document" } }
]
```

The gap used to be filled by a **rule** — "an operation is invoked against the
node it hangs on" — with `ah:href` written only where that rule did not hold.
That made the common case implicit, and an implicit URL holds only while the
operation is still attached to its node: lift one out to log it, queue it, or
hand it to another process, and it no longer says where it goes. Materialising
the rule costs one term per operation and makes an operation mean the same thing
wherever it is read. A named sub-action is then not a special case, only a
different value.

The one place it is absent is the `ApiDocumentation`, which describes a **class**
rather than a record: there is no instance to invoke anything against, and a
template URL would be a different statement.

`ah:href` is an `owl:ObjectProperty` with domain `hydra:Operation` and range
`hydra:Resource`, declared in `AshHateoas.Hydra.Ontology`. Its value is a node
reference (`{"@id": …}`) rather than a string, so it expands to an edge to the
resource the request is sent to.

### What identifies an operation

**A class IRI, in the operation's own `@type`.**

```json
{ "@type": ["Operation", "vocab#Document/approveAction"],
  "hydra:method": "PATCH",
  "ah:href": { "@id": "/documents/7/approve" } }
```

`Operation` is carried by every operation this package emits, so it separates
none of them. What separated them was `ah:action`, a bare string — and a string
cannot be dereferenced, cannot be a subclass of anything, and cannot be the
target of an annotation. It is also local: a consumer meeting two APIs, each
with an action called `approve`, had no way to tell whether they were the same
kind of thing. The class is minted under the API's *own* vocabulary, so the two
`approve`s are visibly different IRIs.

The class comes from the action's name and **never** from the HTTP method: two
`update`-shaped actions on one resource are both `PATCH` returning the same
class, so the method cannot separate them and the name can. Minting an IRI for
something the payload already named as a string adds no claim about what the
operation is *for* — it gives the name an address.

The domain's own word survives as `rdfs:label` on the minted class, which is
where a label belongs: it is a fact about the action, so it is stated once for
the API rather than repeated on every offer of it.

Named the way an input class already is (`<Class>/<action>Input`), so the two
read as one scheme.

#### The claim this makes

`"@type": ["Operation", "…/approveAction"]`, with
`…/approveAction rdfs:subClassOf schema:ConfirmAction`, entails that the
operation **is** a `schema:ConfirmAction`. `schema:potentialAction` said it
*has* one. The stronger reading is the accurate one here: the node is the offer
to act, not a thing with an action attached — and `schema:potentialAction` is
defined with domain `Thing` and range `Action`, which makes an `Operation` an
awkward subject for it. So `schema:potentialAction` is no longer emitted.

#### One action, two routes — one class

`AshHateoas.Route` holds `type` and `route` separately from `action`, so two
routes may carry the same action, and the standard case is exactly that: a
resource with both a member route and a collection route for its primary read.
They **share** the action's class, which is correct — they invoke the same
action. What differs is where the request is sent and what comes back, and both
are facts about the call rather than about what the operation is:

```json
{ "@type": ["Operation", "vocab#Article/readAction"],
  "ah:template": { "hydra:template": "/articles/{id}" },
  "hydra:returns": { "@id": "vocab#Article" } },

{ "@type": ["Operation", "vocab#Article/readAction"],
  "ah:template": { "hydra:template": "/articles" },
  "hydra:returns": { "@id": "vocab#Article/Collection" } }
```

The catalogue's `@type` is therefore the **same two-element list a node
carries**, so joining the two documents is an identity rather than a walk up a
subclass chain.

**A subclass per route was minted for a while, and withdrawn.** It named
`%Route{}.type` — `vocab#Article/readAction/get` — and there were two objections,
either of which is enough:

- **It usually stated nothing.** An action with one route, which was most of
  them, got a subclass with exactly its parent's members: it added no property
  and constrained nothing. In a vocabulary that is a node saying a thing is
  itself. In one captured API, 48 of 70 route classes were of this kind.
- **It read as a claim about HTTP.** The segment is an Ash route kind that spells
  like a method, so `vocab#Exam/sitAction/patch` parses as "sitting an exam is a
  kind of PATCH". That is precisely the inference this package refuses elsewhere:
  the renderer declines to derive `schema:ReadAction` from a GET on the grounds
  that a role a method already implies states nothing.

And the case it was minted for was the wrong end of the problem. The two entries
for a primary read were indistinguishable because the catalogue stated no address
and declared the same return class for both. Both are fixed, so the entries are
told apart by what they do.

If a case appears where two routes onto one action genuinely need separate
identities and cannot be told apart by template and return type, mint the class
then, and only for that action. The stability argument that produced "mint
unconditionally" applies to a name a consumer has published against, and there is
none.

### Why not a link node

A sub-action used to be a link property `ah:<action>` whose `@id` was the URL and
whose `hydra:operation` held a single-element array. Three things were wrong
with it, and one thing was right.

- The action was **named twice** — as the key and as `ah:action`.
- The array was **always length one** by construction: `AshHateoas.Route` holds
  one `action` and one `method`, and the wrapper was built once per route.
- A client had **two traversal paths for one concept**. Answering "what may I
  invoke?" meant reading `hydra:operation` *and* walking every `ah:*` key for
  objects that happened to contain one — and those keys are data-driven, so
  their names could not be known in advance. That also broke what `ah:action`
  was minted for: `ApiDocumentation`'s `hydra:supportedOperation` is a **flat**
  list including sub-actions, so matching a live offer against the catalogue
  needed a flattening step first.

What was right was that a link node's `@id` looked followable. It was not:
`AshHateoas.Hydra.Plug` routes GETs through `serve_get/4`, which matches
`:member`, `:collection` and `:related` only, while a sub-action path is matched
by `match_write/3` — reached for POST, PATCH and DELETE. A GET on
`/documents/7/approve` is a 404, asserted in `hydra/followable_test.exs`. So the
wrapper was redundant rather than a trade-off.

**What this gives up.** A JSON-LD consumer no longer sees the statement
`<document> ah:approve <document/approve>`. The URL is still in the document,
inside the operation rather than as an edge on the resource. That edge pointed
at a 404 and nothing consumed it — but it is the one thing the change removes.
Were `serve_get/4` ever taught to answer a sub-action URL with the operation's
description, `ah:href` would point at something dereferenceable and the document
would gain a genuinely followable edge; that is a separate decision, and this
shape neither assumes nor blocks it.

## Where a term says it is defined — and why it does not

The `@included` vocabulary declares one node per class and per property. It
carries an `owl:Ontology` node for the namespace itself, and **no term points
back at it**.

`rdfs:isDefinedBy` earns its place in a published vocabulary because a term IRI
does not always say where its definition lives. `http://purl.org/dc/terms/title`
is a **slash** IRI, and no mechanical rule takes it to
`http://purl.org/dc/terms/`; the vocabulary has to say so.

This package mints **hash** IRIs — `Context.vocab_iri/1` appends to a namespace
ending in `#` — so RDF's own rule already answers it: the part before the
fragment is the document and the fragment is the term. A consumer holding one
lifted node truncates the `@id` and gets the same IRI the triple would have
given. Stating it per node states the rule as data; in one captured API it was
232 of 237 nodes and 15 KB of a 358 KB document.

**Two changes bring it back**, and a later author should read the condition here
rather than rediscover it:

- `Context` minting `<namespace>/<term>` — a slash IRI, where truncation is
  undefined;
- more than one namespace emitted as first-class nodes, since the answer then
  differs per node.

The ontology's own invariant is untouched either way: it is about `@id` — every
IRI a document references must be declared — not about what a node says of
itself.

## A `:map` attribute's inner keys must be prefixed

**This is the one rule an application has to follow, and breaking it is silent.**

`@context` is built from a resource's attributes and relationships, so an
attribute named `location` gets a term. When that attribute's type is `:map` or
`{:array, :map}`, the **value** is serialised into the document verbatim, and
its inner keys are application data this package has no schema for. They are
therefore never declared, no `@vocab` is set, and a JSON-LD processor **drops
them on expansion**. They are in the JSON and absent from the graph, with
nothing reported.

```elixir
attribute :location, :map, public?: true
```

```json
"location": { "@type": "schema:Place", "address": "…", "name": "…" }
```

`@type` survives, because it is a keyword. `name` survives if the resource
declares a `semantic_property :name`. **`address` is dropped.**

The package cannot invent IRIs for an application's map keys, and setting
`@vocab` would mint meaningless ones. So the rule is the author's, and it costs
nothing: a key inside a `:map` value must be **prefixed** (`"schema:address"`)
or a term the resource declares. Every prefix is already bound by the emitted
`@context`, so a prefixed key needs no code at all.

`AshHateoas.Hydra.Plug` warns once per key on any bare one it emits. A
compile-time check is impossible — the keys are runtime data — and the check
itself is `AshHateoas.Hydra.Context.undeclared_keys/2`, which is public so a
test can use it too. `hydra/no_dropped_keys_test.exs` covers the served shape.

## What a node states, and what it does not

**`@type` and `ah:href`.** Everything else about an operation holds in every
state and for every actor, so it is stated once in the `ApiDocumentation`:

| on an operation | varies | why |
|---|---|---|
| its presence in `hydra:operation` | **yes** | `Ash.can?/3` and the state gate decide it per request |
| `ah:href` | **yes** | the record's own id is in it |
| `hydra:method` | no | a property of the action |
| `hydra:expects` | no | read from the action's `accept` and its public arguments |
| `hydra:returns` | no | the class the action yields |
| `hydra:title` | no | the action's description |

The class in `@type` is the key that joins the two documents. On a captured API
40 node operations occupied 22,354 bytes and occupy 6,729 carrying the two keys;
13 responses were repeating 92 statements the catalogue already made once.

The rule is not "a node never states a shape". It is:

> the catalogue states the shape; a node may restate it; a node that says nothing
> means the catalogue's answer stands.

Nothing in Ash makes an action's accepted input depend on a record's state today
— `accept` and `arguments` are declared on the action — so nothing restates one.
If an application ever narrows an input for a single state, the node is where the
narrower statement belongs, and one rule covers both.

**What it costs.** A node is no longer readable on its own: anything holding one
response and no catalogue — a test, a log line, a client that ignored the `Link`
header — cannot say what a request to that operation looks like. Every response
carries `Link: <…>; rel="…apiDocumentation"`, and the catalogue is one fetch,
cacheable, and the same document for every actor. **That header is load-bearing
now**, so a path that omits it is a correctness bug rather than a missing
convenience.

## Catalogue vs. availability

`ApiDocumentation` deliberately enumerates the operations each class *supports* —
their method and expected input — actor-independently. What a client may invoke
*now*, on *this* record, is the gated `hydra:operation` array on the node. The
documentation is the stable catalogue; the node is the live offer. Authorization
and the state gate apply only to the node.

The split is deliberate and stays. A state-aware server publishing a state-blind
list is not a contradiction: the two answer different questions. The node answers
*what may I do now*; the catalogue answers *what exists at all* — which
operations a class has, and so which states are reachable in principle. A client
that only ever sees gated nodes cannot tell a permanently absent operation from
one merely unavailable in this state, to this actor, right now. Being plain and
stateless is the catalogue's job, not a defect in it.

### What the catalogue has to answer

Being state-blind is not the same as being incomplete. A client reading a
`hydra:supportedOperation` should be able to **issue** it, and that takes four
answers:

| question | term |
|---|---|
| where do I send it? | `ah:template` |
| what do I send? | `hydra:expects` — a body, and in this document only a body. Stated even when it is empty |
| what comes back? | `hydra:returns` — the member class, or the collection class for a collection route |
| what may happen? | `hydra:possibleStatus` — the success first, then the gate chain |

And **which class the entry is filed under** is itself a statement. A resource
yields two: `vocab#Exam` for what one exam supports, and `vocab#Exam/Collection`
for what the set supports. A collection response names the second in its `@type`,
and so does every row of the entry point, so a client reaching either can look up
what it may do there without fetching a record first.

The first and the last were missing, and the third was wrong for a collection
route. That is one defect in three places: the entry described the *shape* of an
operation and not the *call*.

`ah:template` is the catalogue's counterpart to a node's `ah:href`, and the
asymmetry is the split itself: a node has a record to resolve an address
against, and a class does not. It is a sub-action that makes it matter. A member
URL can be reached by following links — an entry point lists collections, a
collection lists members with full `@id`s, a node states its own — but a
sub-action's URL appeared in exactly one place, `ah:href` on an operation a node
is currently offering. An operation the record's state gates off therefore had no
URL in any document at all.

**`hydra:expects` narrows here.** A node's GET affordance still renders its query
arguments as an `IriTemplate` under `hydra:expects`; in the documentation those
variables are part of the address and ride in `ah:template` with the path, so
`hydra:expects` means a request body and nothing else. Hydra defines `expects` as
"the information expected by the Web API" — a template carrying a path variable
and no body is not that, and one key answering two questions would leave a client
reading the value's `@type` to find out which.

## Rules a conforming server follows

1. **Only advertise what the actor may invoke.** The per-node operation set is
   resolved per request from the requesting actor's context; two actors may
   receive different operations on the same record.
2. **Never emit a sensitive input's default.** The `hydra:SupportedProperty`
   still appears — the client must know to supply it — but no `sh:defaultValue`.
3. **Never expose a private input.** An input the server does not accept from
   clients does not appear as a property.
4. **Collections carry collection-level operations only.** A `hydra:Collection`
   advertises the type's operations (such as create) at the top level; its
   members carry navigation but no per-record operations. This bounds a
   collection response to be independent of its page size.
4a. **A collection says what it is a collection of.** Every `hydra:Collection`
   carries a `hydra:memberAssertion`, so a client holding one response and no
   catalogue can still tell — including on an empty page, which has no members
   to infer it from. It is the same statement the collection's declared class
   makes, built by one function, so the two cannot drift.
5. **Affordances are advisory.** The server re-runs authorization, validation and
   state checks on invocation; a stale operation degrades to a clean
   `hydra:Error`, never an invalid write.
