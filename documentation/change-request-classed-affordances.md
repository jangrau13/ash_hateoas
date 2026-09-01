# Change request: everything in a document should be an IRI

**Status:** **implemented.** Kept as the record of why, since every capture
taken before it shows the shape it replaces. What landed, and the three places
it differed from this request, are recorded at the end under
"What was implemented".
**Touches:** `AshHateoas.Hydra.Renderer.operation/2` and
`put_potential_action/3`, `AshHateoas.Hydra.ApiDocumentation.supported_operations/2`,
`AshHateoas.Hydra.Context`, `AshHateoas.Hydra.Ontology`, `AshHateoas.Resource`,
`documentation/hydra-mapping.md`, `documentation/semantic-affordances.md`

## The principle

Every name a document uses should be an IRI, and a published IRI wherever a
published one fits. That is what makes a document readable by something not
written against this API: an IRI can be dereferenced, can be a subclass of
something, and can be the target of an annotation. A bare string is none of
those.

This package already holds to that in most places. A resource has a class IRI
from `Context.class_iri/1`. Attributes resolve through `@context`. Hydra, ODRL,
SHACL and schema.org terms are all prefixed. Three places break it, and they are
this request. A fourth is a modelling note, not a code change.

## Where the examples come from

The JSON below is captured output from a demo API built on this package, in a
sibling repository. Nothing about its domain matters; what matters is the
shapes. Two of its resources appear:

- One resource, appearing below as `vocab#Exam`. It has a `create`, a primary
  `read` reached by both a member and a collection route, an `update`, a
  `destroy`, four **named sub-actions** that move it through a lifecycle (one of
  which appears below as `open_sitting`), and two `:map` attributes.
- The `ApiDocumentation` that API serves, covering 14 resources.

Counts given as "in this API" are from those captures. They are illustrations
of a structural problem, not a measurement of how common it is.

## Where this follows on from

`change-request-flat-operations.md` is **implemented**, and this request assumes
the shape it left. Three things carry over:

- **One array.** A node states its affordances in `hydra:operation` and nowhere
  else, since `link_node/3` is gone. So everything below can talk about typing
  an operation rather than about finding one.
- **`ah:href` exists**, declared in `Ontology` as an `owl:ObjectProperty` with
  domain `hydra:Operation` and range `hydra:Resource`, and `hydra:Operation` is
  declared `owl:Class` beside it. Subclassing `hydra:Operation` needs no new
  machinery.
- **`odrl:permission` is a flat list on the node**, not nested per operation,
  and its targets follow `ah:href`.

One thing that request deliberately did not settle: `ah:action` stayed, kept as
the string a client matches against the catalogue. That is what this request
reopens, and only because a class can do that job better.

## Two documents, and which one changes

Everything below touches both, differently. `hydra-mapping.md` already puts the
split as "the documentation is the stable catalogue; the node is the live
offer".

| | `ApiDocumentation` | the resource node |
|---|---|---|
| answers | what exists at all | what may be done now |
| varies by actor | no | yes |
| varies by state | no | yes |
| fetched | once, via the `Link` header | per request |
| holds | `hydra:supportedOperation`, `hydra:supportedProperty`, `hydra:possibleStatus`, `@included` vocabulary | `hydra:operation`, `odrl:permission`, the data |

An action's class belongs on **both**, and that is not a contradiction: a class
is a fact about the action, not about a request. The catalogue says a class
exists, is a subclass of something, expects an input and is invoked with a
method. The node says this actor may invoke it on this record now.

So the catalogue stays actor-blind and state-blind. A client that only ever saw
gated nodes could not tell a permanently absent operation from one merely
unavailable in this state, and the catalogue is what answers that.

Two consequences, both load-bearing below:

- `rdfs:subClassOf` axioms go in the catalogue's `@included` and **never** on a
  node. An axiom holds in every state, so repeating it per response is the
  duplication this request is against.
- The class IRI is the join between the two documents, so
  `Renderer.operation/2` and `supported_operations/2` must mint it identically.
  That argues for one function in `Context`, called by both.

## 1. An operation has no IRI

`Renderer.operation/2` opens with a constant:

```elixir
%{
  "@type" => "Operation",
  "hydra:method" => ...,
  "ah:action" => to_string(affordance.name)
}
```

Every operation this package emits therefore carries the same type, and the
type separates none of them. What separates them is `ah:action`, a string:

```json
{ "@type": "Operation",
  "ah:action": "open_sitting",
  "hydra:method": "PATCH",
  "hydra:returns": { "@id": "vocab#Exam" } }
```

`"open_sitting"` cannot be dereferenced, cannot be a subclass of anything, and
cannot be the target of an annotation. It is also local: a consumer that meets
two APIs, each with an action it calls `approve`, has no way to know whether
they are the same kind of thing.

`put_potential_action/3` already fixes this where a `semantic_action` is
declared, so the mechanism exists. In the captured API it reaches 10 of 40
operations on resource nodes, because a role is opt-in and most actions have no
published equivalent.

**Change.** Mint a class per action, exactly as `Ontology.class_node/2` already
mints one per resource, and put it in the operation's `@type`:

```json
{ "@type": ["Operation", "vocab#Exam/open_sittingAction"],
  "hydra:method": "PATCH",
  "hydra:returns": { "@id": "vocab#Exam" } }
```

The name follows `input_class_iri/2`, which already builds
`Context.class_iri(type) <> "/" <> action <> "Input"`. This is the same with
`"Action"`. `ah:action` then states the identity a second time and goes; the
domain's own word belongs on the minted class as `rdfs:label`, which is where
`class_node/2` already puts a resource's.

**This does not reopen the settled question.** `renderer.ex` argues that no role
may be inferred from the HTTP verb, because a role a method already implies
states nothing. That holds, and nothing here is inferred from a method. The
class comes from `route.action`, which the method does not carry: any two
`update`-style actions on one resource are both `PATCH` returning the same
class, so the method cannot separate them and the action name can. Minting an
IRI for something the payload already names as a string adds no claim about what
the action is for. It gives the name an address.

## 2. Two routes on one action are the same string

`supported_operations/2` maps over `routes(resource)` and names each result
`to_string(route.action)`. `%Route{}` holds `type` and `route` separately from
`action`, so **two routes may carry the same action**, and the standard case is
exactly that: a resource with both a member route and a collection route for its
primary read.

The two are not interchangeable. `put_possible_status/4` already knows this:

```elixir
|> maybe_status(member_route?(route), 404, "Not Found — no such record.")
```

so the member route can answer 404 and the collection route cannot. In the
captured documentation this surfaces as two entries that differ only there:

```
ah:action  method  possibleStatus
read       GET     403, 404
read       GET     403
```

A client cannot tell them apart, and neither can anything published against
either. This gets worse once §1 lands, because a class minted from the action
name alone gives both the same class, and the class is meant to be the key a
client resolves against.

**Change.** Mint the class from the route as well, under the action's, and
declare the axioms in the catalogue's `@included`:

```json
"@included": [
  { "@id": "vocab#Exam/readAction", "@type": "owl:Class" },
  { "@id": "vocab#Exam/readAction/member", "@type": "owl:Class",
    "rdfs:subClassOf": { "@id": "vocab#Exam/readAction" } },
  { "@id": "vocab#Exam/readAction/collection", "@type": "owl:Class",
    "rdfs:subClassOf": { "@id": "vocab#Exam/readAction" } }
]
```

`%Route{}.type` is already there, so nothing is inferred. A consumer written
against the action class serves both routes; one written against the collection
class serves only that. Where a `semantic_action` is declared it becomes
`rdfs:subClassOf` on the **action** class, so a chain runs from the route class
to the action class to the published class and on up schema.org's own
hierarchy.

**Do this unconditionally**, even for an action with one route today. If the
route segment appeared only where an action has two, then adding a second route
later would rename the class of the first, and anything published against it
would break.

## 3. A `:map` attribute puts undeclared terms in the document

This is the one unambiguous bug here, and it is general to an attribute type
rather than to any resource.

`Context` builds `@context` from a resource's attributes and relationships, so
an attribute named `location` gets a term. When that attribute's type is `:map`
or `{:array, :map}`, the **value** is serialised into the document verbatim, and
its inner keys are application data the package has no schema for. They are
therefore never declared. No `@vocab` is set either, so a JSON-LD processor
**drops them on expansion**. They are in the JSON and not in the graph.

From the captured API, an attribute declared

```elixir
attribute :location, :map, public?: true
```

serialises as

```json
"location": { "@type": "schema:Place", "address": "…", "name": "…" }
```

`@type` survives, because it is a keyword. `name` survives, because the resource
happens to declare a `semantic_property :name`. `address` is dropped. Across the
14 resources, three such keys are lost at 18 sites.

Any application that puts a bare key inside a `:map` attribute hits this, and
nothing tells it so. The value looks correct in the JSON and is silently
incomplete in the graph.

**Change, and it is small.** The package cannot know an application's map keys,
so it should not try to invent IRIs for them; setting `@vocab` would mint
meaningless ones. What it can do:

1. **Say so.** Document that a key inside a `:map` value must be a prefixed term
   (`"schema:address"`) or a term the resource declares, because a bare key is
   dropped. The prefixes are already in `@context`, so a prefixed key needs no
   code change at all.
2. **Check it.** Walk emitted map values and warn on any bare key that is
   neither a JSON-LD keyword nor a declared term. A compile-time check is not
   possible, since the keys are runtime data, so this is a log at render or a
   test helper.

A test worth having regardless: expand every emitted document and assert no key
disappears. That is what `no_dropped_keys_test.exs` is named for, one level
further out than it currently reaches.

## 4. A local IRI where a published one exists

Not a code change, but it belongs to the principle.

An attribute with no `semantic_property` gets a minted IRI under the API's own
vocab. That satisfies the letter of the principle, and nothing outside the API
knows the term. The captured API does this for a lifecycle-status attribute,
although `schema:creativeWorkStatus` fits it exactly: domain `CreativeWork`,
range `DefinedTerm` or `Text`, defined as "the status of a creative work in
terms of its stage in a lifecycle", and explicitly allowing an organisation's
own vocabulary of stages.

The mechanism is already there. `semantic_property` maps an attribute to a
published IRI, the same way `semantic_type` maps a resource and
`semantic_action` maps an action.

**Change.** A line in `semantic-affordances.md` saying that a minted property
IRI is the fallback and not the default, and that an author should look for a
published term first.

## What this gives up

A consumer reading `schema:potentialAction` breaks. The class it read is still
in the document, in `@type` rather than in a key of its own.

A consumer matching on `ah:action` breaks. The class is minted from that same
string, so the mapping is mechanical, but it is a rename.

Every operation gains an IRI, and a resource with six actions gains twelve class
nodes in the vocabulary, six for actions and six for routes. The vocabulary is
fetched once and cached.

## The claim being made, stated plainly

`"@type": ["Operation", "schema:RegisterAction"]` asserts that this operation
**is** a `schema:RegisterAction`, where `schema:potentialAction` asserted that it
**has** one. The stronger reading is the accurate one here: the node is the offer
to act, not a thing with an action attached, and `potentialAction` is defined
with domain `Thing` and range `Action`, which makes an `Operation` node an
awkward subject for it. If that reading is rejected, §1 does not survive in this
form and should be discussed rather than softened.

## Knock-on effects to settle before implementing

- **ODRL.** `odrl:permission` entries are keyed by `ah:action` as a string. They
  still have to say which operation they are about, so that key takes the class
  IRI as its value.
- **The catalogue.** `supported_operations/2` carries the same `@type` list, and
  `api_documentation.ex:532`, which copies `schema:potentialAction` forward,
  copies `@type` instead. Per "Two documents" above, this adds a stable fact to
  a stable document and does not make the catalogue state-aware.
- **One minting function.** The class IRI is the join between the two documents.
  It belongs in `Context` next to `class_iri/1`, called by both renderers rather
  than written out twice.
- **Ontology completeness.** `ontology.ex` exists so that every IRI a document
  references is declared. The minted action and route classes must be emitted
  there, or its own invariant breaks on the first operation.
- **Root actions.** `derive_root_actions.ex` calls `semantic_action_iri(:save)`,
  returning `ah:SaveAction`. `ah:SaveAction` and `ah:RunAction` are already
  declared classes with `rdfs:subClassOf`, so they slot in as parents unchanged.
- **Tests.** `renderer_test.exs`, `api_documentation_test.exs`,
  `ontology_test.exs`, `no_dropped_keys_test.exs` and `vocabulary_test.exs`
  assert on the current shape.
- **Conformance.** Hydra does not forbid an `Operation` carrying additional
  types, so this reads as conformant. A row in `hydra-conformance-notes.md`
  should say so, because a multi-valued `@type` on an operation is the kind of
  thing a strict consumer may not expect.

## A separate question this raises

Once operations are classed, a node could be thinned: `hydra:method`,
`hydra:expects` and `hydra:returns` hold in every state, so a node could carry
`@type` and `ah:href` alone and let the catalogue state the rest. On one
captured response that is 267 lines down to 136, because 131 of them restate an
input class the catalogue already carries.

It is deliberately **not** part of this request. It changes what a single
response means: a node stops being actionable on its own, and anything
inspecting one response, a test or a log, needs the catalogue too. That is a
bigger call than giving a name an address, and should be decided separately.


---

# What was implemented

All four sections landed, and the tests, documentation and the three sibling
consumers were updated with them. Three decisions are worth recording, because
each is a place the implementation had to choose and the request left room.

## §1 — the operation's class

As specified. `Renderer.operation/2` emits
`@type: ["Operation", Context.action_class_iri(type, name)]`, `ah:action` is gone
from operations, and the domain's word moved to `rdfs:label` on the minted class
— a label is a fact about the action, so it is stated once for the API rather
than repeated on every offer of it.

`schema:potentialAction` is no longer emitted anywhere. A declared
`semantic_action` is `rdfs:subClassOf` on the minted class, in `@included`.

With no resource type there is no vocabulary to mint under, so `operation/2`
falls back to the bare `"Operation"` rather than inventing an IRI.

## §2 — the route class, and where the two documents differ

**The route segment is `%Route{}.type` verbatim** — `/get`, `/index`, `/post`,
`/patch`, `/delete`, `/route` — not the `/member` and `/collection` this
request's example IRIs used. Three reasons:

- it is the declared fact, with no translation table to keep in step with the
  route kinds;
- `member`/`collection` collapses six kinds into two buckets, so an action with
  two routes in one bucket would collide again — the very failure §2 is about;
- `:get` versus `:index` *is* member versus collection in this package's own
  vocabulary.

**This is a wire-visible naming choice and cheap to change**: one function,
`Context.route_class_iri/3`, plus its callers' expectations in
`ontology_test.exs` and `api_documentation_test.exs`.

**Which class each document carries:**

| | node | `ApiDocumentation` |
|---|---|---|
| `@type` | `["Operation", <action class>]` | `["Operation", <action class>, <route class>]` |

A node offers an *action*, not a route-table entry, and the request's own §1
example shows the node carrying the action class alone. The catalogue carries
both, so "the class IRI is the join between the two documents" stays a lookup
rather than a walk up the subclass chain.

**Left open.** A node's operation still cannot say which route it is. In practice
`ah:href` disambiguates, and `%Affordance{}` carries no route type today —
`Descriptor.build/4` does receive the route, so adding one is a small change, but
it widens a public struct beyond what this request asked for.

## §3 — the `:map` attribute

Both halves landed:

- `Context.undeclared_keys/2` walks an emitted value and returns the bare keys
  nothing can resolve — a key survives if it is a JSON-LD keyword, a declared
  term, an absolute IRI, or prefixed with a prefix the emitted `@context` binds.
  The prefix set is read from the context rather than hardcoded, so a customer's
  own `semantic_vocab` prefix counts without this knowing its name.
- `Plug` warns from it, **once per key**, via `:persistent_term`. This runs on
  every node of every page, so a plain `Logger.warning` would turn one modelling
  mistake into a flood and get the log turned off.

`AshHateoas.Test.Placed` is the fixture — `:map` and `{:array, :map}` attributes
with prefixed inner keys, which is the correct usage. `no_dropped_keys_test.exs`
sweeps the served node, mutates one key to bare to demonstrate the drop on a real
response, and asserts the checker flags it.

## §4 — the modelling note

`semantic-affordances.md` gained a section saying outright that a minted property
IRI is the fallback and not the default, with `schema:creativeWorkStatus` as the
worked example and a table of the three declarations that avoid it.

## The knock-ons, settled

- **ODRL.** An `odrl:Permission` names its operation under `ah:action` as
  `{"@id": <action class>}` — the very IRI the operation carries in its `@type`.
  `ah:action` stays an `owl:AnnotationProperty`: an annotation property may take
  an IRI without description-logic consequence, and the class is being
  *mentioned* here, not used to type anything.
- **The catalogue.** `supported_operations/2` carries the `@type` list;
  `put_shape/5` no longer copies `schema:potentialAction`, because nothing emits
  it. The catalogue stays actor- and state-blind.
- **One minting function.** `Context.action_class_iri/2` and
  `Context.route_class_iri/3`, called by both renderers.
- **Ontology completeness.** `Ontology.action_class_nodes/2` emits both, mirroring
  `supported_operations/2`'s traversal exactly. `ontology_test.exs` sweeps every
  class an operation's `@type` names and asserts each is declared.
- **Root actions.** Unchanged: `derive_root_actions.ex` declares `semantic_action`
  entries, so `ah:SaveAction` and `ah:RunAction` slot in as superclasses through
  the ordinary path.
- **Conformance.** `hydra-conformance-notes.md` §8 — a multi-valued `@type` on an
  `Operation` is **conformant** (JSON-LD 1.1 §4.2 allows an array; Hydra does not
  claim exclusivity). `Operation` is kept first in the array, so a consumer
  reading position 0 survives.
