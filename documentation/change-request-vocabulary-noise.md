# Change request: which document states what about an operation

**Status:** **all five sections implemented.** §2 and §3 landed first, and the
file claimed the whole request for a while — see "What was implemented" at the
foot for that, since a status line is how the next reader learns what the emitted
shape is. §1, §4 and §5 followed.
**Touches:** `AshHateoas.Hydra.ApiDocumentation.supported_classes/3` and
`supported_operations/3`, `AshHateoas.Hydra.Context.route_class_iri/3`,
`AshHateoas.Hydra.Ontology`, `test/ash_hateoas/hydra/api_documentation_test.exs`,
`test/ash_hateoas/hydra/ontology_test.exs`,
`documentation/hydra-mapping.md`, `documentation/semantic-affordances.md`

## Where this comes from, and what it depends on

Five sections, one question: which of the two documents a client reads should
carry a given statement about an operation, and which statements neither carries
today. §1 and §5 are about placement, §2 and §3 remove nodes that state nothing,
§4 adds a statement whose absence is being read as one.

`change-request-classed-affordances.md` is implemented. §2 withdraws part of it;
§5 is the question it deliberately held out, now with a measurement attached.

**Apply this after `change-request-callable-operations.md`.** That request gives
a catalogue entry its own address and a correct return class, and mints
`<Class>/Collection` for the latter. §1 needs the same class and should reuse it
rather than mint a second one, and §5 depends on it outright: a thinned node
sends a client to the catalogue for the method and the input, so the catalogue
has to be able to answer. §3 and §4 are independent and can land in any order.

Order to implement: §1, then §2, then §4, then §5, with §3 wherever convenient.

The examples are captured output from a demo API built on this package, in a
sibling repository. Its domain does not matter; what matters is the shapes. One
resource appears throughout as `vocab#Exam`, with a primary `read` reached by
both a member and a collection route, a `create`, an `update`, a `destroy` and
four named sub-actions, one of which appears as `sit` and is the only one of them
carrying a `semantic_action`. Every count is from that API's `ApiDocumentation`,
which covers 18 resources, and is an illustration of a structural problem rather
than a measurement of how common it is.

## 1. A collection operation is declared on the member class

`hydra:supportedOperation` on a `hydra:Class` says: an instance of this class
supports this operation, invoked against that instance. That is Hydra's whole
model for where an operation attaches, and it is why `hydra:Operation` has no
target-URL property.

`supported_operations/3` maps over `routes(resource)` and hangs every result on
the one class `supported_classes/3` emits for that resource. Some of those routes
are not member routes:

```elixir
defp primary_specs(:read),
  do: [{:get, [route: "/:id", primary?: true]}, {:index, [route: "/"]}]

defp primary_specs(:create), do: [{:post, [route: "/"]}]
```

So `vocab#Exam` advertises an operation invoked at `/exam`, and another one
POSTed to `/exam`. Neither is invoked against an Exam. You cannot POST to an
exam to create an exam, and listing exams is not something one exam does.

In the captured documentation, **34 of 115 operations** are `:index` or `:post`,
which is 34 entries attached to a subject they are not about, across all 18
classes.

**This is where the doubling comes from.** One Ash `read` action becomes two
entries under `vocab#Exam` because both of its routes were forced under the
member class, and the two then had to be told apart by something. That is what
produced the route class in §2 and, before it, two entries a client could not
distinguish at all. The doubling is not a property of the action. It is two
different affordances, one on a record and one on a collection, filed under one
subject.

**Change.** Emit a collection class per resource in `hydra:supportedClass`, and
put the collection-level operations on it.

```json
"hydra:supportedClass": [
  { "@id": "vocab#Exam", "@type": "Class",
    "hydra:supportedOperation": [
      "read at /exam/:id, update, destroy, and the named sub-actions" ] },

  { "@id": "vocab#Exam/Collection", "@type": "Class",
    "hydra:supportedOperation": [
      "read at /exam, create" ] } ]
```

The class already exists in this package. `Ontology.collection_class/3` mints one
for a to-many relationship, with `rdfs:subClassOf hydra:Collection` and a
`hydra:memberAssertion` saying the members are of the resource's class. Keying it
on the resource rather than on a relationship is the same change
`change-request-callable-operations.md` §2 asks for, and both should call one
function.

Route kinds map cleanly, so nothing is guessed: `:get`, `:patch`, `:delete` and
`:route` go on the member class, `:index` and `:post` on the collection class.
`collection_read?/1` already sorts a named read into `:index` for exactly this
reason, and the comment above it already says why: *"the action is a collection
operation wearing a member's URL"*. This applies the same judgement one level up.

**What a client gains.** It can ask what a collection supports without holding
one, which is the entry-point question: how do I list these, how do I make one.
Today that answer sits under a class whose instances cannot answer it.

## 2. A route class with one route is its own parent

With §1 applied, no action has two routes under one class, and this follows.
Stated separately because it is also true on its own.

`Ontology.action_class_nodes/2` mints a class per action and then one per route
beneath it:

```json
{ "@id": "vocab#Exam/sitAction", "@type": "owl:Class",
  "rdfs:label": "sit",
  "rdfs:subClassOf": {"@id": "https://schema.org/RegisterAction"} },
{ "@id": "vocab#Exam/sitAction/patch", "@type": "owl:Class",
  "rdfs:subClassOf": {"@id": "vocab#Exam/sitAction"} }
```

`sit` has one route, so the second class has exactly the members the first has,
adds no property and constrains nothing. It is a node asserting that a thing is
itself. In the captured documentation there are 59 action classes and 70 route
classes, and **48 of the 70 are the only route onto their action**, so 48 are
provably co-extensive with their parent. The remaining 22 are the two routes onto
each of 11 primary reads, which §1 separates onto two classes.

The name also claims something it should not. The segment is
`%AshHateoas.Route{}.type`, an Ash route kind, and it reads as an HTTP method, so
the axiom parses as "sitting an exam is a kind of PATCH". `renderer.ex` refuses
that inference in the other direction on the grounds that a role a method implies
states nothing.

**Change.** Drop `Context.route_class_iri/3`, stop emitting the route half of
`action_class_nodes/2`, and let `supported_operations/3` emit
`["Operation", <action class>]`, which is the list a node's operation already
carries. The join between the two documents becomes an identity rather than a
walk up a subclass chain.

## 3. `rdfs:isDefinedBy` restates the term's own IRI

Every term node carries

```json
"rdfs:isDefinedBy": {"@id": "https://example.com/api/vocab#"}
```

written at 21 sites in `Ontology` as `%{"@id" => Context.vocab_iri("")}`. In the
captured document 232 of 237 `@included` nodes carry it, all with the same value,
and that value is the `@id` of the `owl:Ontology` node the same document
declares. The statement is true, it is computable from the node's own `@id` by
deleting everything after the `#`, and it is 15 KB of a 358 KB document.

`rdfs:isDefinedBy` earns its place in published vocabularies because a term IRI
does not always say where its definition lives. `http://purl.org/dc/terms/title`
is a **slash** IRI, and no mechanical rule takes it to
`http://purl.org/dc/terms/`. This package mints **hash** IRIs:
`Context.vocab_iri/1` appends to a namespace ending in `#`, so the part before
the fragment is the document and the fragment is the term. Restating RDF's own
rule for a hash IRI, once per term, states the rule as data.

**Change.** Drop the pair from the term nodes and keep the `owl:Ontology` node,
which is what makes the namespace a thing in the graph rather than a prefix.
`Ontology`'s invariant, that every IRI a document references is declared, is
about `@id` and is untouched.

**When to put it back**, and both deserve a line in `hydra-mapping.md` so a later
author reads the condition rather than rediscovering it: if `Context` ever mints
`<namespace>/<term>`, since truncation is then undefined; or if terms from more
than one namespace are emitted as first-class nodes, since the answer then
differs per node.

## 4. An omitted `hydra:expects` is not a statement

`Renderer.put_expects/3` opens with

```elixir
defp put_expects(op, %Affordance{fields: []}, _opts), do: op
```

so an operation whose action takes nothing carries no `hydra:expects` at all. In
the captured documentation **71 of 115 operations** have none, and 17 of those are
`PATCH`. A client reading one cannot tell "send an empty body" from "this
document does not describe the body", because absence in RDF is the absence of a
statement rather than a negative statement. The generated request is then a
guess, and for a `PATCH` it is a guess about a write.

**Change.** Declare it for every operation. For an action with no fields the
honest declaration is the input class it would otherwise have, carrying an empty
`hydra:supportedProperty`:

```json
{ "@type": ["Operation", "vocab#Exam/open_sittingAction"],
  "hydra:method": "POST",
  "hydra:expects": { "@id": "vocab#Exam/open_sittingInput", "@type": "Class",
                     "hydra:supportedProperty": [] } }
```

"These are the properties, and there are none" is a statement. A client
generating a form draws nothing and posts an empty body, and it knows that is
what the server wants.

**Not `owl:Nothing` here**, although `renderer.ex` reserves it for a return with
no body. `hydra:expects owl:Nothing` says an instance of the empty class is
expected, which is unsatisfiable, so it reads as "no valid request to this
operation exists". That is the right reading on the way out, where nothing comes
back, and the wrong one on the way in, where an empty body is a perfectly valid
request. The two directions are not symmetric.

`Ontology` must declare the empty input class like any other, since
`input_class_iri/2` already names it and the module's invariant is that every
IRI a document references is declared.

**`hydra:returns` is already stated on all 115**, so the return side needs no new
key here. What it needs is for the value to be true, which is
`change-request-callable-operations.md` §2: a collection route names the member
class, and a destroy that answers 204 names a class it does not send.

## 5. A node repeats what holds in every state

`hydra-mapping.md` already states the split: the documentation is the stable
catalogue, the node is the live offer. The emitted documents do not keep to it.

A node's operation carries `@type`, `ah:href`, `hydra:method`, `hydra:expects`
and `hydra:returns`. Two of those vary:

| on an operation | varies by actor or state | why |
|---|---|---|
| its presence in `hydra:operation` | **yes** | `Ash.can?/3` plus the state gate decide it per request |
| `ah:href` | **yes** | the record's own id is in it |
| `hydra:method` | no | a property of the action |
| `hydra:expects` | no | `Descriptor.build/4` reads the action's `accept` and its public arguments, both declared on the action |
| `hydra:returns` | no | the class the action yields |
| `hydra:title` | no | the action's description |

So the affordance set is the state-dependent fact, and the shape of each
affordance is not. In the captured node responses, 40 operations occupy 22,354
bytes and would occupy 6,729 carrying `@type` and `ah:href` alone, which is 30%.
The same 13 responses carry 92 keys that hold in every state, and the catalogue
carries every one of them once.

**Change.** A node's operation states `@type` and `ah:href`. The catalogue states
the rest, and the class in `@type` is the key that joins them, which is what
`change-request-classed-affordances.md` minted it for.

**Keep the override, because "usually" is not "always".** Nothing in Ash makes an
action's accepted input depend on the record's state today, since `accept` and
`arguments` are declared on the action. If that ever changes, or if an
application wants to narrow an input for one state, the node is where the
narrower statement belongs. So the rule is not "the node never states a shape"
but:

> the catalogue states the shape; a node may restate it; a node that says nothing
> means the catalogue's answer stands.

That is one rule a client implements once, and it leaves room for the case
without paying for it on every response.

**What this costs, and it is the reason it was held out before.** A node stops
being readable on its own. Anything holding one response and no catalogue, a
test, a log line, a client that ignored the `Link` header, can no longer say what
a request to that operation looks like. The mitigation is that every response
already carries the `Link` header pointing at the catalogue, and the catalogue is
one fetch, cacheable, and the same document for every actor. Whether that trade
is worth making is the decision this section asks for; the measurement above is
what it is worth.

## What this gives up

`hydra:supportedClass` grows by one entry per resource, and a consumer counting
classes to count resources gets a different number. In the captured document that
is 18 more entries, and the operations move rather than multiply.

A consumer looking up `create` under the member class breaks. It was reading a
statement about the wrong subject.

A consumer that lifted a route class out of an operation's `@type` breaks.
Nothing has, since those classes were minted in the working tree and never
released.

A consumer reading a node's operation for its method, input or return finds none
of them. This is the §5 trade and the largest break in the request, which is why
§5 states its measurement and asks for a decision rather than assuming one.

The catalogue grows: an empty input class per fieldless operation, 71 of them in
the captured document. It is fetched once and cached, which is the same argument
that carried the vocabulary into `@included`.

## Knock-on effects to settle before implementing

- **`hydra:collection` on the member class.** A node already carries a
  `hydra:collection` pointing at the collection's URL. With a collection class in
  the catalogue, the class-level statement is the one that says which class that
  collection is an instance of, and the two should be minted from one function.
- **`Ontology` completeness.** The collection class and every empty input class
  must be declared. `collection_class/3` already does the first for
  relationships, and `input_class_iri/2` already names the second.
- **The entry point.** `plug.ex` serves an index of collections. Each of those is
  an instance of one of the new classes, and saying so in the entry point is what
  makes the catalogue reachable from it.
- **`Collection.wrap/2`.** A collection response should say which class it is an
  instance of, or a client holding one has to match the URL against the catalogue
  to find out.
- **The `Link` header is load-bearing after §5.** It is already emitted on every
  response by `put_link_header/2`, and a thinned node depends on it, so any path
  that skips it becomes a correctness bug rather than a missing convenience.
- **Tests.** `api_documentation_test.exs` asserts that a resource yields one
  supported class and that every route appears under it. `renderer_test.exs`
  asserts `hydra:method`, `hydra:expects` and `hydra:returns` on node
  operations, all of which §5 removes.

## What was implemented

**§2 and §3 only.** The other three sections are untouched, and this file said
otherwise for a while — the correction matters more than the work, so it is
first.

### What happened

This request was handed to me as **two sections**, quoted in full, under the
title *"two kinds of vocabulary node that state nothing"*: the route class and
`rdfs:isDefinedBy`. Those are §2 and §3 here. I implemented both, then wrote the
notes below into the file whose name matched — this one, which carries five
sections — and marked the whole of it implemented.

So §1, §4 and §5 were never read, never weighed and never rejected. **Nothing
here has been reconsidered or dropped.** A reader who took the old status at its
word would have concluded the emitted document carries a collection class in
`hydra:supportedClass`, states `hydra:expects` on a fieldless write, and thins
its nodes — and it carries none of the three. That reader existed:
`change-request-not-delivered.md` is the measurement, taken against a capture of
the server after this file was marked done.

The lesson is narrow and worth keeping: a request's **title** is what says which
request it is, and a filename that merely looks related is not the same claim.

### §2 — the route class is withdrawn

- `Context.route_class_iri/3` is gone. `Ontology.action_class_nodes/2` emits one
  class per action, and `supported_operations/3` emits
  `["Operation", <action class>]` — the same list a node's operation carries, so
  the join is an identity.

### §3 — `rdfs:isDefinedBy` is withdrawn

- `rdfs:isDefinedBy` is gone from the term nodes (18 emission sites); the
  `owl:Ontology` node stays. The condition for bringing it back — slash IRIs, or
  more than one namespace as first-class nodes — is recorded in
  `hydra-mapping.md` under "Where a term says it is defined", where a later
  author reads it rather than rediscovers it.

Measured on the fixture domain, whose numbers are smaller than the captured
API's but move the same way: **0** route classes (was one per route), **0** nodes
carrying `rdfs:isDefinedBy` (was every term), and every catalogue entry's `@type`
is a two-element list.

Two tests were replaced rather than deleted, since a withdrawn shape is worth
asserting the absence of:

- `ontology_test.exs` — "a route mints no class beneath its action" sweeps for
  anything named `<something>Action/<word>` rather than naming the two it knows
  about, and "the two routes onto one read name one class" states the positive.
- `ontology_test.exs` — "no term restates where it is defined" is a sweep, and
  "the rule it restated still answers the question" shows what a consumer does
  instead: truncate the `@id` at the fragment and reach the `owl:Ontology` node
  the same document declares.

### One thing worth knowing

`api_documentation_test.exs` picked its entries by route class IRI, which was the
convenient handle and is now gone. Its helpers select by **action** and, for a
primary read, split the two by the address they state (`member_entry/3`,
`collection_entry/3`). That is not a workaround: it is the same discriminator a
client has, so the tests now fail if the thing that replaced the route class ever
stops distinguishing them.

### §1 — the collection class

A resource yields a second `hydra:supportedClass`, `<Class>/Collection`, and
collection-level operations are filed there. It is the same class `hydra:returns`
already named, so nothing new is minted: `Context.collection_class_iri/1` is the
one function, as this request asked.

**One deviation, and it is required by §4 of the other request.** This section
says the split is by route kind — `:get`, `:patch`, `:delete`, `:route` on the
member class; `:index`, `:post` on the collection. That was true when it was
written and is not any more: a named transition is now a `:post` at `/:id/<name>`,
and sorting by kind files 45 member operations under the collection. The split is
by the route's **path** (`AshHateoas.Route.member?/1`), which is the fact the kind
lists were approximating and the same predicate `put_possible_status/4` already
used for 404. Measured after: 89 operations under a member class, 0 of them
invoked at a collection URL.

The knock-ons this request lists are all in:

- `hydra:collection` — an entry-point row is typed
  `["hydra:Collection", "<Class>/Collection"]`, so the catalogue is reachable from
  the index rather than only from a record.
- `Collection.wrap/2` — an addressed collection carries the class in `@type`.
  A **related** collection deliberately does not: `/articles/7/comments` is one
  record's related set and supports neither the create nor the named reads filed
  under `Comment/Collection`, so claiming that class would advertise operations
  the URL refuses. It carries the member assertion, which is the part that is true
  of both.
- `Ontology` — the collection class is declared wherever one is used, on the same
  path predicate rather than on `type == :index`.

### §4 — the empty input class

Every `POST`/`PATCH`/`PUT` declares `hydra:expects`, with an empty
`hydra:supportedProperty` where the action takes nothing. `GET` and `DELETE` are
left alone, as `change-request-not-delivered.md` §3 clarified; a `DELETE` whose
action takes arguments still describes them, since silence being ambiguous is the
point rather than DELETE never carrying input.

**Every input class is declared**, which this request required and which had never
been true: 68 referenced, 0 declared. They are collected from the **built
document** rather than derived a second time from the route table — which
operations carry a `hydra:expects` is decided in `Renderer.put_expects/3`, and
restating that rule in `Ontology` would be a second copy free to drift.

### §5 — the thinned node

A node's operation states `@type` and `ah:href`. `Renderer.operation/2` is
unchanged and still builds the full shape for the catalogue, which is also where a
node would restate a narrowed input — the rule is "the catalogue states the shape;
a node may restate it", not "a node never does".

The `Link` header is now load-bearing, so `plug_test.exs` asserts it on a member
read rather than leaving it to the discovery tests.

**This is the largest break in the series**, and the clients are the work that
follows it: every consumer that read `hydra:method` or `hydra:expects` off a node
now reads them from the catalogue, joined by the class in `@type`.
