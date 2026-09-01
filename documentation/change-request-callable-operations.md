# Change request: a catalogue entry should describe an operation a client can call

**Status:** **all four sections implemented.** Kept as the record of why, since
every capture taken before it shows the shape it replaces.

§1–§3 landed first. **§4 was missed**, because this request was handed over in a
form carrying only the first three, and the status line was written against what
was handed over rather than against what the file says. `change-request-not-delivered.md`
is the measurement that caught it. §4 is in now — see "§4, afterwards" at the
foot.
**Touches:** `AshHateoas.Hydra.ApiDocumentation.supported_operations/2` and
`put_possible_status/4`, `AshHateoas.Hydra.Renderer.put_returns/3` and
`iri_template/2`, `AshHateoas.Hydra.Context`, `AshHateoas.Hydra.Ontology`,
`documentation/hydra-mapping.md`, `documentation/hydra-conformance-notes.md`

## The principle

`hydra:supportedOperation` says an operation exists. A client reading one should
be able to issue it: where to send it, what to send, what comes back, and what
may go wrong. This package answers the middle two and does not answer the first,
and its answer to the last is failures only.

Three defects follow, and they are one defect in three places. Each is stated
from the package's own code first; the JSON is captured output from a demo API
built on this package, in a sibling repository, and its domain does not matter.
The resource appearing below as `vocab#Exam` has a primary `read` reached by both
a member route and a collection route, an `update`, a `destroy`, a `create` and
four named sub-actions.

## 1. An entry carries no address

`supported_operations/2` builds each entry from `@type`, `hydra:method`,
`hydra:title`, `put_shape/5` and `put_possible_status/4`. None of those is a URL,
and `Renderer.put_href/2` documents the omission:

> Omitted only when there is nothing to say: no href was derived and no node URL
> was supplied, which is the `ApiDocumentation`'s case — it describes a class
> rather than a record.

That is right about a *record* and wrong about a *route*. `%Route{}.route` is
`/exam/:id` or `/exam`, and those are facts about the class, actor-independent
and state-independent, exactly what belongs in the catalogue. A client holding
only the documentation therefore knows that `vocab#Exam` supports nine
operations and cannot issue one of them.

It is worse for a sub-action. A member URL can be reached by following links: an
entry point lists collections, a collection lists members with full `@id`s, and a
node states its own. A sub-action URL appears in exactly one place, `ah:href` on
an operation a node offers, so an operation the current state does not offer has
no URL in any document. `close_sitting` is in the catalogue and, while the record
is `scheduled`, is unaddressable.

**Change.** Emit an address per supported operation. The machinery exists:
`Renderer.iri_template/2` already builds a `hydra:IriTemplate`, `path_variables/1`
already rewrites `:id` to `{id}`, and `path_mappings/3` already declares the path
variable as required. Today they run only for a GET whose action has fields.

```json
{ "@type": ["Operation", "vocab#Exam/readAction", "vocab#Exam/readAction/get"],
  "hydra:method": "GET",
  "ah:template": {
    "@type": "IriTemplate",
    "hydra:template": "/api/catalogue/exam/{id}",
    "hydra:variableRepresentation": "BasicRepresentation",
    "hydra:mapping": [
      { "@type": "IriTemplateMapping", "hydra:variable": "id",
        "hydra:property": {"@id": "vocab#exam/id"}, "hydra:required": true } ] } }
```

Under a property of its own rather than under `hydra:expects`, because the two
say different things: `hydra:expects` is the body, and a template with a path
variable and no body is not an input description. `ah:template` pairs with
`ah:href` the way the catalogue pairs with a node: the node states the address it
resolved, the catalogue states how to build one.

**A collection route needs no variables**, so its template is a constant string
and stays a template rather than becoming a second shape a client must branch on.

## 2. A collection route declares that it returns one record

`Renderer.put_returns/3` names `Context.class_iri(type)` for every operation
yielding a record, and `put_shape/5` copies it into the catalogue. The route kind
is not consulted, so both routes onto a primary read declare the same thing:

```
@type                                    method  returns
vocab#Exam/readAction/get                GET     vocab#Exam
vocab#Exam/readAction/index              GET     vocab#Exam
```

`Collection.wrap/2` says the second is untrue:

```elixir
%{"@type" => "Collection", "hydra:member" => members}
|> put_unless_nil("hydra:totalItems", ...)
```

`GET /exam` answers with a `hydra:Collection` carrying `hydra:member` and
`hydra:totalItems`, and the document tells a client to expect an Exam. A client
that believes the declaration looks for the resource's properties on a node that
has none of them. `plug.ex`'s own module doc has said so all along: *"`GET
<collection>` | a `hydra:Collection` with `member` + `totalItems`"*.

This is the one plainly wrong statement of the three, and it also removes the
objection that the two `read` entries differ only in a status list. Once the
return type is right, they differ in what they answer with, which is the
substance.

**Change, and this package already knows how.** `Ontology.collection_class/3`
mints exactly the class this needs, with the spec's own pattern for a strongly
typed collection:

```elixir
%{
  "@id" => collection_class_iri(resource, name),
  "@type" => ["owl:Class", "hydra:Class"],
  "rdfs:subClassOf" => %{"@id" => "hydra:Collection"},
  "hydra:memberAssertion" => %{
    "hydra:property" => %{"@id" => "rdf:type"},
    "hydra:object" => %{"@id" => Context.class_iri(member)}
  },
  ...
}
```

It is reached from `property_nodes/2` for a resource's **to-many
relationships** and from nowhere else, so `vocab#Course/exams` has a collection
class and `vocab#Exam` itself, which is served at a collection URL, does not.
The same function, keyed on the resource rather than on a relationship, gives
`vocab#Exam/Collection`, and `hydra:returns` on the `:index` route names it. A
client then learns both that a collection comes back and what is in it, where
`hydra:Collection` alone would be true and would not say of what.

The comment above that function already states the reasoning, including why
`hydra:subject` is deliberately absent, so this change adds a caller rather than
an argument.

**The collection response should carry the same assertion.** `Collection.wrap/2`
emits `@type`, `hydra:member` and `hydra:totalItems`, so a client holding one
response and no catalogue cannot tell what it is a collection of. One
`hydra:memberAssertion` there says it, and is the same statement rather than a
second one that could drift.

Two smaller cases in the same family, both to settle rather than assume:

- a **destroy** answering `:ok` with no record sends no body, and `put_returns/3`
  already reserves `owl:Nothing` for that path. The catalogue entry has no way to
  say "one of these two", so it names the class and is right only half the time.
- a **`hydra:collection`** entry on the class in `hydra:supportedClass`, giving
  the collection's URL. A node already carries one, and repeating the fact where
  the class is described is what makes §1's template unnecessary for that route.

## 3. Every declared outcome is a failure

`put_possible_status/4` builds the list from three calls, and all three are
errors:

```elixir
[]
|> maybe_status(authorized?(resource), 403, "Forbidden — the actor may not perform this.")
|> maybe_status(write?(action), 422, "Unprocessable — the input failed validation.")
|> maybe_status(member_route?(route), 404, "Not Found — no such record.")
```

So a catalogue entry reads as an operation that can only fail:

```json
{ "@type": ["Operation", "vocab#Exam/readAction", "vocab#Exam/readAction/index"],
  "hydra:method": "GET",
  "hydra:possibleStatus": [{"@type": "Status", "hydra:statusCode": 403}],
  "hydra:returns": {"@id": "vocab#Exam"} }
```

Hydra says otherwise. An Operation "may document the status codes that might be
returned by the server using the `possibleStatus` property", with no restriction
to failures, and the spec adds that the list "has not to be considered as an
extensive list of all potentially returned status codes; it is merely a hint".
Nothing there licenses omitting the one status a caller most needs.

The statuses this package actually sends are in `plug.ex`: 200 for a read, an
update and a sub-action, 201 where `respond_write` is called with
`created: true`, and 204 from `respond_destroy/7` when a destroy yields no
record. None of them is ever declared.

The cost is not cosmetic. A client generating a request handler from the
catalogue has to hardcode which status means success, which is the one thing a
description of an operation should not leave to convention.

**Change.** Add the success status to the list, from the route kind, which is
already in hand:

| route kind | success |
|---|---|
| `:get`, `:index`, `:patch`, `:route` | 200 |
| `:post` | 201, or 200 where the write is not a create |
| `:delete` | 200 with the destroyed record, 204 without |

Where two are possible, list both: `possibleStatus` is a set of what may happen,
so a destroy declaring 200 and 204 is a more accurate document than one declaring
either alone.

## 4. A named transition is advertised as a partial modification

`route_specs/2` sends every non-primary action to
`non_primary_type(action.type)` at `/:id/<name>`, so an Ash `update` action
becomes a `PATCH` whatever it does. In the captured API that gives three
operations the same verb on one class:

```
vocab#Exam/updateAction/patch          PATCH   expects updateInput (10 properties)
vocab#Exam/sitAction/patch             PATCH   expects sitInput (1 property)
vocab#Exam/open_sittingAction/patch    PATCH   expects nothing
```

Only the first is a PATCH. RFC 5789 defines the method by its body: *"The
enclosed entity contains a set of instructions describing how a resource
currently residing on the origin server should be modified to produce a new
version."* `open_sitting` carries no entity at all, and a PATCH with no patch
document has no defined meaning. `sit` carries a `student_id`, which is an
argument to a transition rather than a description of how the exam is to be
modified.

RFC 9110 gives the method for this: POST performs *"resource-specific
processing on the request content"*, which is what a named transition is.

**Change.** Derive `:patch` for the primary update and `:post` for a named
sub-action. The author override already exists, since `generic_specs/2` reads
`AshHateoas.Resource.Info.method/2`, so extending that to non-primary actions
gives an author the escape hatch for a sub-action that genuinely takes a patch
document.

**This is not the rule `renderer.ex` guards.** That rule forbids reading a
*role* out of a method, because a role the method implies states nothing. This
runs the other way: it picks the method that matches what the action does. After
it, `hydra:method` carries a real distinction again, POST for a transition
against PATCH for a partial modification, where today the same token sits on
three unlike operations.

**Settle first:** it changes the URLs' verbs, so every client and every captured
fixture moves with it, and `plug.ex`'s `match_write/3` routes sub-action paths by
method.

## What this gives up

Three entries grow. An operation gains a template of roughly six lines, a
resource gains one collection class in the vocabulary, and each entry gains one
or two statuses. The `ApiDocumentation` is fetched once and cached, which is the
argument that carried the vocabulary into `@included` in the first place.

A consumer reading `hydra:returns` on a collection route and expecting the member
class breaks. It was reading a false statement.

## Knock-on effects to settle before implementing

- **One minting function.** `Context` already owns `class_iri/1`,
  `input_class_iri/2`, `action_class_iri/2` and `route_class_iri/3`. A collection
  class belongs beside them, not written out in the renderer.
- **Ontology completeness.** `ontology.ex` exists so every IRI a document
  references is declared. A minted collection class and any `ah:template`
  property must be emitted there.
- **`ah:template` as a term.** An `owl:ObjectProperty` with domain
  `hydra:Operation` and range `hydra:IriTemplate`, declared beside `ah:href`,
  which it is the catalogue-side twin of.
- **Conformance.** `hydra-conformance-notes.md` §6 records that Hydra has no
  `EntryPoint` class and §7 that a link node was redundant. Two notes belong in
  the same file: why an operation carries a template under an `ah:` term rather
  than under `hydra:expects`, and that `hydra:memberAssertion` is used with
  `property` and `object` and no `subject`, which is one of the three legal
  pairs.
- **Tests.** `api_documentation_test.exs` asserts the current entry shape, and
  `no_dropped_keys_test.exs` should gain a case that every emitted template
  expands to a path rather than to a bare query fragment.

## What was implemented

All three sections, and both smaller cases in §2 were settled rather than
assumed. Where the implementation departed from the request:

- **`hydra:expects` narrowed rather than merely gaining a neighbour.** §1 says
  the template goes "under a property of its own rather than under
  `hydra:expects`, because the two say different things". Taken at its word: a
  catalogue entry for a query read no longer carries the same `IriTemplate`
  under both keys — `ah:template` states the whole address including the query
  variables, and `hydra:expects` means a request body and only a body. Emitting
  the identical node under two keys is the redundancy the flat-operations change
  removed one level up.

  **A node is untouched.** Its GET affordance still renders query arguments as an
  `IriTemplate` under `hydra:expects`, where the address is already resolved as
  `ah:href` and the template genuinely is about what to send. Three consumers
  read that shape.

- **The template is prefixed.** A route is stored as the mount path plus the
  path, so `AshHateoas.Hydra.Plug` now passes `:prefix` into
  `ApiDocumentation.build/2`. Without it a client has to know where the API hangs
  to expand a template, which is the knowledge the documentation exists to
  remove.

- **`hydra:mapping` is omitted when a template has no variables**, rather than
  emitted empty. An empty JSON-LD array states nothing, so the key would be
  present in the JSON and absent from the graph — the silent drop
  `no_dropped_keys_test.exs` exists to catch.

- **The member assertion is one function, called from four places.**
  `AshHateoas.Hydra.Collection.member_assertion/1`. The collection class
  declares it, and the served resource collection, related collection and inline
  to-many all carry it. That last one was the collection shape built by hand
  rather than through `Collection.wrap/2`, and it now goes through it — being the
  one that could drift is what made it the one that would have been missed.
  `Ontology.member_class_iri/2` is public for the same reason: a *narrowed*
  relationship's served collection reads its member class from the function that
  declares it, so the two cannot disagree.

- **`hydra:Collection` and `hydra:IriTemplate` are now declared.** The first was
  the superclass of every to-many's collection class from the start and had never
  been — the gap this ontology exists to close, in the one place it was not
  looking at itself.

### The two smaller cases, settled

- **A destroy answering `:ok` with no record.** `hydra:returns` keeps naming the
  resource's class, and the entry declares **200 and 204**. `hydra:returns`
  ranges over a class, so naming both it and `owl:Nothing` would be an
  intersection with the empty class — unsatisfiable, and read as "returns
  nothing, ever". The class is what comes back when a body does; the 204 is where
  "sometimes there is none" is stated. §3 is what makes that complete rather than
  half-true.

- **`hydra:collection` on the class in `hydra:supportedClass`.** **Not emitted.**
  §1's template is emitted for *every* route uniformly, so the collection URL is
  already in the catalogue and this would be a second spelling of it — and the
  two could disagree. Its Hydra reading does not fit either: `hydra:collection`
  says a *resource* has a collection, and a `hydra:Class` node is a class rather
  than an instance of the type being collected.

### What was not done

- **The route-class segment is still `%Route{}.type` verbatim** (`/readAction/get`,
  `/readAction/index`), from the classed-affordances change. Unchanged here.

## §4, afterwards

Implemented as asked: a named sub-action of an `update` action derives `:post`,
the primary update keeps `:patch`.

- The **author override** was already `AshHateoas.Resource.Info.method/2`, read by
  `generic_specs/2`. It is now read for any non-primary action, so
  `method :sit, :patch` restores the old verb for one action.
- **The router had to learn it too.** `AshHateoas.Hydra.Plug.route_method/1` read
  an explicit `method` only for a `:route` kind, so an author's override would
  have been advertised by the documentation and refused by the router — the
  catalogue saying one verb and the router answering another. It reads a declared
  method first now, whatever the kind implies.
- **A named destroy keeps `DELETE`.** The argument here is about `PATCH`
  semantics; `DELETE` at `/:id/archive` has the same shape of problem and does not
  follow from it, and moving a URL's verb wants an argument actually made. Say so
  and it changes.

### What it broke, and what caught it

The member/collection split. `AshHateoas.Candidates` sorted routes into "record"
and "collection" by **route kind** — `[:get, :patch, :delete, :route]` against
`[:index, :post, :route]` — so the moment a sub-action became a `:post`, all 45
of them were filed as collection operations and vanished from the records that
offer them. 33 tests failed at once, which is what a real behavioural suite is
for.

The fix is `AshHateoas.Route.member?/1`: `:id` in the route's path. That is the
fact both lists were approximating, it is the same predicate
`put_possible_status/4` already used to decide which operations can answer 404,
and `change-request-vocabulary-noise.md` §1 needs exactly it. Two faults went with
the old lists: `:route` appeared in **both**, so a generic action at `/:id/<name>`
was offered on a collection that has no id to give it.
