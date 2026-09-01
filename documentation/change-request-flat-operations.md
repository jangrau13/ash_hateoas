# Change request — a named sub-action should be an operation, not a node wrapping one

**Status:** **implemented.** Kept as the record of why, since the shape it
replaces is what every capture taken before it shows.
**Raised from:** writing a paper figure against captured output
(`genui-thesis/demo/fixtures/exam.jsonld`, `course.jsonld`)
**Touches:** `AshHateoas.Hydra.Renderer.render/2` and `link_node/3`,
`AshHateoas.Hydra.Ontology`, `documentation/hydra-mapping.md`,
`documentation/odrl-mapping.md`

## Superseded in one respect

`ah:href` is now carried by **every** operation, not only by one whose URL is not
the node's own. This request's "an entry with no `ah:href` is invoked against the
node's own `@id`" was true when it landed and is not any more: filling the gap
with a *rule* left the common case implicit, and an implicit URL survives only
while the operation is still attached to its node. See `hydra-mapping.md`,
"Where an operation attaches".

## What landed, and where it differed from the request

- `link_node/3` is gone; `render/2` emits one `hydra:operation` list, and
  `put_href/3` adds `ah:href` only where the URL is not the node's own.
- `ah:href` is declared in `AshHateoas.Hydra.Ontology` as an
  `owl:ObjectProperty` (domain `hydra:Operation`, range `hydra:Resource`), and
  `hydra:Operation` is declared `owl:Class` alongside it, since the domain axiom
  mentions it.
- The 404 the justification rests on was **verified, not assumed** — see
  `hydra/followable_test.exs`, "a GET on a named sub-action's URL is a 404".
- **The ODRL note was half wrong about the current state.** `odrl:Permission`
  is not nested inside each operation, as `odrl-mapping.md` claimed and the
  "knock-on effects" section assumed; it is a flat `odrl:permission` list on the
  node. The defect it predicted was therefore already present rather than about
  to be introduced: every permission targeted the record, including a
  sub-action's. Targets now follow `ah:href`, and `odrl-mapping.md` was
  corrected to describe the list the code actually emits.
- **Two things not in the request.** A collection now passes its own `@id` to
  the renderer, so a `create` POSTed to the collection URL states no redundant
  `ah:href`. And the node a `DELETE` returns drops `odrl:permission` as well as
  `hydra:operation` — dropping one key used to leave the permission list *and*
  every `ah:<action>` node behind, so the "carries no operations" the code
  claimed was two thirds false.

## Scope

This changes the **resource node only**. `ApiDocumentation` is out of scope and
should stay exactly as it is — see "Why the catalogue is not part of this"
below, because the obvious first reaction is to want it changed too.

## The problem

A named sub-action is emitted as a link node whose only content is a
single-element `hydra:operation` array:

```json
"ah:close_sitting": {
  "@id": "http://localhost:4020/api/catalogue/exam/e-4711/close_sitting",
  "hydra:operation": [
    { "@type": "Operation",
      "ah:action": "close_sitting",
      "hydra:method": "PATCH",
      "hydra:returns": { "@id": "vocab:Exam" } }
  ]
}
```

Three things are wrong with it.

1. **The action is named twice** — once as the key `ah:close_sitting`, once as
   `"ah:action": "close_sitting"`.
2. **The array is always length one.** `AshHateoas.Route` holds a single
   `action` and a single `method`:

   ```elixir
   defstruct [:type, :method, :route, :action, :relationship, primary?: false]
   ```

   and `link_node/3` is reached once per route, so the list is one element by
   construction. Nothing can ever put a second operation in it.
3. **A client has two traversal paths for one concept.** Answering "what may I
   invoke on this node?" means reading `hydra:operation` *and* walking every
   `ah:*` key for objects that happen to contain a `hydra:operation`. Those
   keys are data-driven, so a consumer cannot know their names ahead of time.

Point 3 also breaks the thing `ah:action` was minted for. `hydra-mapping.md`
says the key exists so a client can "match a live offer against the operation
the documentation describes" — but `supported_operations/2` returns a **flat**
list including named sub-actions, while the node wraps those same actions. The
two sides are not the same shape, so the matching needs a flattening step
first. Flattening the node removes it.

## Why the current shape exists, and why the reason no longer holds

`hydra-mapping.md` records it:

> Hydra's `Operation` has no target-URL property — a client invokes an
> operation against the resource node it hangs on (`@id`). So a named
> sub-action needs a distinct URL, and becomes a link property whose `@id` is
> that URL. The distinct URL stays followable.

The first half is true: Hydra core gives `Operation` no target property, so a
sub-action URL has to be carried somehow. The second half is not. **A GET on a
sub-action URL returns 404.** In `AshHateoas.Hydra.Plug`, `dispatch/5` routes
GETs to `serve_get/4`, which matches only `:member`, `:collection` and
`:related`; sub-action paths are matched by `match_write/3`, which is reached
only for `POST`, `PATCH` and `DELETE`. So `.../e-4711/close_sitting` is a write
target and nothing else, and dereferencing it yields no node.

Followability was the wrapper's one genuine benefit and it is not real, so the
wrapper is redundant rather than a trade-off.

*(Traced through the source, not executed. Worth a one-line test before
implementing, since the whole justification rests on it.)*

## The change

Put every affordance in `hydra:operation`, and carry the URL on the entry that
needs one:

```json
"hydra:operation": [
  { "@type": "Operation", "ah:action": "read", "hydra:method": "GET",
    "hydra:returns": { "@id": "vocab:Exam" } },
  { "@type": "Operation", "ah:action": "update", "hydra:method": "PATCH",
    "hydra:returns": { "@id": "vocab:Exam" },
    "hydra:expects": { "@id": "vocab:Exam/updateInput" } },
  { "@type": "Operation", "ah:action": "close_sitting", "hydra:method": "PATCH",
    "ah:href": { "@id": "vocab:catalogue/exam/e-4711/close_sitting" },
    "hydra:returns": { "@id": "vocab:Exam" } }
]
```

No `ah:<action>` key. An entry with no `ah:href` is invoked against the node's
own `@id`, which is Hydra's own rule and stays the default. *(Superseded — see
the note at the top: every operation now states its `ah:href`.)*

`ah:href` is a new minted term: an `owl:ObjectProperty` with domain
`hydra:Operation` and range `hydra:Resource`, declared in
`AshHateoas.Hydra.Ontology` alongside the other `ah:` terms.

`schema:target` was considered and rejected in `hydra-mapping.md` because it
"restated the `@id`". That reasoning holds where the URL *is* the node's own;
for a sub-action it restates nothing, so the rejection does not carry over.
`ah:href` is still preferable, because `schema:target` drags an
`EntryPoint`/`EntryPointDescription` reading along with it that does not apply.

### What this gives up

A JSON-LD consumer loses the statement `<exam> ah:close_sitting
<exam/close_sitting>`. The URL is still in the document, inside the operation
rather than as an edge on the resource. Nothing in the codebase or the demo
client consumes that edge today, and it pointed at a 404, so the loss looks
like bookkeeping — but it is the one thing the change actually removes and
should be a conscious call rather than a side effect.

## Why the catalogue is not part of this

The tempting next step is to delete `hydra:supportedOperation` from
`ApiDocumentation` on the grounds that a state-aware server should not also
publish a state-blind list. That is wrong, and the split should stay as
`hydra-mapping.md` already describes it:

> The documentation is the stable catalogue; the node is the live offer.

The two answer different questions. The node answers *what may I do now*, which
is this package's contribution. The catalogue answers *what exists at all* —
which operations a class has, and therefore which states are reachable in
principle. A client that only ever sees gated nodes cannot tell a permanently
absent operation from one that is merely unavailable in this state, to this
actor, right now. Being plain and stateless is the catalogue's job, not a
defect in it.

So `supportedOperation` stays actor- and state-independent, and this request
touches only how the node states an operation it *is* offering.

## Knock-on effects to settle before implementing

- **ODRL targets.** `odrl-mapping.md` specifies that a sub-action's nested
  `odrl:Permission` takes the **link node's own `@id`** as `odrl:target`, not
  the parent's. Flattening moves the permission into the array, where the
  target would naturally default to the node's `@id` and quietly become wrong.
  It must follow `ah:href` where one is present. This is the change most likely
  to regress silently, and it deserves the test.
- **Tests.** `hydra/followable_test.exs` and `hydra/no_dropped_keys_test.exs`
  assert on the current shape. The followability test in particular is
  asserting a property that a GET does not actually deliver, so it is worth
  reading before rewriting.
- **Ontology.** `ah:href` needs declaring in `AshHateoas.Hydra.Ontology`.
- **Captured fixtures.** `genui-thesis/demo/fixtures/*.jsonld` are real
  captures and need regenerating through `demo/capture.mjs`.
- **Conformance.** As far as I can tell the present shape is *conformant but
  redundant* rather than wrong, so this is a design change for the changelog
  and not a bug fix. A row in `hydra-conformance-notes.md` should say which it
  is.

## Open: should a sub-action URL answer a GET?

Out of scope here, but the 404 is worth a decision of its own. If GET on
`.../close_sitting` returned the operation description, `ah:href` would point
at something dereferenceable and the document would gain a genuinely followable
edge. That is a change to `serve_get/4`, independent of this one, and this
request neither assumes nor blocks it.
