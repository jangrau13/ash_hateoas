# Change request: four sections marked implemented that the emitted document does not carry

**Status:** **closed — all four implemented.** Each was overlooked rather than
declined, and the reason was one mistake made twice: both requests were handed
over in a form carrying only some of their sections, and each file's status line
was written against what was handed over rather than against what the file says.
See the "What was implemented" section of each for the correction.
**Touches:** `AshHateoas.Hydra.ApiDocumentation.supported_classes/3`,
`AshHateoas.Hydra.Renderer.render/2` and `put_expects/3`,
`AshHateoas.Resource.Transformers.DeriveActionRoutes.route_specs/2`
**Raised from:** comparing the emitted documents against the two requests that
claim to have changed them

## What this is

`change-request-callable-operations.md` and
`change-request-vocabulary-noise.md` are both marked **implemented**. Most of
what they ask for is in the emitted documents: `ah:template` on every operation,
a success status in `hydra:possibleStatus`, `hydra:returns` naming a collection
class on a collection route, no route class in an operation's `@type`, and no
`rdfs:isDefinedBy` on a vocabulary node. All of that is there and correct.

Four sections are not, and this request is only those four. Each is quoted from
the request that asked for it and measured against a capture of the server
taken after both were marked done. The counts come from a demo API in a sibling
repository covering 18 resources and 115 operations; the domain does not matter.

Nothing here is a new idea. If a section was reconsidered and dropped, that is a
fine answer and the request that carries it should say so, because a document
marked implemented is how the next reader learns what the emitted shape is.

## 1. A collection operation is still declared on the member class

`change-request-vocabulary-noise.md` §1 asks for a collection class per resource
in `hydra:supportedClass`, carrying the `:index` and `:post` operations.

Measured: **0 of 18** supported classes is a collection class, and **32 of 115**
operations are still invoked at a collection URL while hanging off the member
class. `vocab#Exam` continues to advertise an operation POSTed to `/exam` and
another `GET` at `/exam`, neither of which is invoked against an Exam.

The class itself is minted correctly for to-many relationships by
`Ontology.collection_class/3`, and `Context.collection_class_iri/1` now exists
and is used by `put_collection_returns/3`, so `hydra:returns` already names
`vocab#Exam/Collection`. That class is named as a return type and never
declared as a supported class, which leaves a client told what comes back and
not told what it supports.

## 2. A node still repeats what holds in every state

`change-request-vocabulary-noise.md` §5 asks that a node's operation carry
`@type` and `ah:href`, since those are the only two that vary per request.

Measured across the captured node responses: **40 operations**, of which 40
still carry `hydra:method`, 40 still carry `hydra:returns` and 12 still carry
`hydra:expects`. The measurement in that section stands: those 40 operations
occupy 22,354 bytes and would occupy 6,729 carrying the two keys alone.

That section asked for a decision rather than assuming one, so a reasoned "no"
is a legitimate outcome. What is not legitimate is the current state, where the
request says the node is thinned and the node is not.

## 3. A fieldless write still omits `hydra:expects`

`change-request-vocabulary-noise.md` §4 asks that an operation whose method can
carry a body declare an input class even when it is empty, so that "send
nothing" is stated rather than inferred from silence.

Measured: **17 of 61** write operations carry no `hydra:expects`. Every one of
them is a `PATCH`, so a client is given a method that normally carries a body,
no description of that body, and no way to tell an empty body from an
undescribed one.

`GET` and `DELETE` are correctly left alone: RFC 9110 says a client should not
send content in a `GET`, and a `DELETE` body has no defined semantics, so
omission there is unambiguous and this request does not ask for it.

## 4. A named sub-action is still `PATCH`

`change-request-callable-operations.md` §4 asks for `:post` on a named
sub-action and `:patch` on the primary update, on the grounds that RFC 5789
defines a `PATCH` body as *"a set of instructions describing how a resource
currently residing on the origin server should be modified"*, which a named
transition does not send.

Measured: **45 operations** are a `PATCH` at a sub-action path. `open_sitting`
sends no body at all, so it is a `PATCH` with no patch document, which has no
defined meaning.

This is the section most likely to have been declined deliberately, since it
changes every sub-action URL's verb and moves every client and every fixture
with it. If it was, say so in that request and this section closes.

## What to do with each

| section | if it was overlooked | if it was declined |
|---|---|---|
| 1 | implement, reusing `collection_class_iri/1` | say why a collection class may be named as a return and not declared |
| 2 | implement | record the decision in §5, whose measurement then argues the other way |
| 3 | implement for `POST`/`PATCH`/`PUT` only | say what a client should read silence as |
| 4 | implement, with the author override | say so, and drop the RFC argument from that request |

## Verifying

The paper this was raised from holds written listings of the expected shape and
a checker that compares them against a fresh capture. Whatever is decided here,
one command answers whether the emitted documents match, and exits non-zero when
they do not:

    make verify

in `phd/papers/paper1`, after re-running `node demo/capture.mjs`.

It reports the four sections above as four groups of failures rather than as
prose, so a section that lands closes a named check:

- §1 is two checks, and neither names a collection class, so an implementation
  reaching the same end another way passes. Group E holds every operation
  against the subject its class gives it and reports each one whose address
  carries no path variable, which was the 32 above. Group C reads the catalogue
  the way a client holding a class reads it, and reports a class that answers
  twice over: before this landed, `Exam/readAction` gave two addresses and two
  return types, so the join a thinned node depends on had no single answer.
- §2 is group B, which sweeps every operation in every captured response and
  counts the keys a node still carries beyond its class and its address.
- §3 is group E, which names every write declaring no `hydra:expects`.
- §4 is group D, which assembles three requests out of the two documents and
  reports the method each one is given.

Group G is the same test pointed the other way. The paper's appendix captions
describe what is wrong with the documents they print, so each of them fails once
the request it describes is implemented. A caption saying an operation's `@type`
names a route class is already failing, which is how the sections that did land
were confirmed.

## Outcome

All four were overlooked, so all four are implemented; none was declined. Against
the fixture domain, which is smaller than the captured API but moves the same way:

| section | before | after |
|---|---|---|
| 1 — collection operation on the member class | 0 collection classes; 32 of 115 operations misfiled | 33 collection classes; **0** operations under a member class invoked at a collection URL |
| 2 — node repeats what holds in every state | 40 operations carrying method / returns / expects | node operations carry `@type` and `ah:href` and nothing else |
| 3 — fieldless write omits `hydra:expects` | 17 of 61 writes silent | **0** `POST`/`PATCH`/`PUT` without one; 68 input classes referenced and 68 declared |
| 4 — named sub-action still `PATCH` | 45 PATCHes at a sub-action path | **0** |

Two things this request did not ask for and that fell out of it:

- **The member/collection split was by route kind**, and §4 broke it: a
  sub-action becoming a `POST` filed 45 member operations under the collection.
  It is by the route's path now (`AshHateoas.Route.member?/1`), which is also what
  §1 needs. The old lists had `:route` in **both**, so a generic action at
  `/:id/<name>` was offered on a collection with no id to give it.
- **The router ignored a declared method** except on a `:route` kind, so an
  author's `method :sit, :patch` override would have been advertised by the
  documentation and refused by the router.

The one deliberate stop: a named **destroy** keeps `DELETE`. §4's argument is
about `PATCH` semantics and does not carry to `DELETE` on its own, and moving a
URL's verb wants an argument actually made. Say the word and it changes.

## Verifying

Re-run `node demo/capture.mjs` against a server built on this and the checker
named above should agree. The clients are the next piece of work and are not done
as of this line.
