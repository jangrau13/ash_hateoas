# HATEOAS core — requirements

One engine computes authorization- and state-aware **affordances** ("what may be
done next"). Every transport is a **rendering** of that one engine's output:
JSON:API today, MCP today, more later (UI action bar, CLI, HAL-FORMS). This
document is the requirement set; implementation lives in the package (§5).

> **Status:** design, not yet built. No `lib/` code exists here and none will —
> this ships as **one standalone Ash package** carrying the core and both
> renderings (§5).
>
> **Verified against** **ash 3.29.3 / ash_json_api 1.7.1 / ash_ai 0.7.2 /
> spark ≥ 2.6**. Findings marked VERIFIED were read from those sources.

---

## 1. Problem

HATEOAS (Richardson Level 3): the client discovers every available state
transition from what the server embeds in responses; it follows what it is given
and never constructs URLs or relies on out-of-band knowledge of operations.

JSON:API is strong on **navigation** and absent on **affordances**:

| HATEOAS aspect | AshJsonApi |
|---|---|
| `self` / `related` / pagination links | ✅ auto-derived |
| compound docs / `included` graph | ✅ |
| **"actions you may take next"** | ❌ |
| **request-shape (operation) descriptors** | ❌ |

The gap is affordance *discovery*. Closing it is cheap on Ash because everything
an affordance needs is already declared: actions, JSON:API routes, **policies**
(`Ash.can?/3` answers "may this actor run this action on this record now?"), and
`AshStateMachine` transitions where a resource has a state machine. Most
backends cannot answer that cheaply; Ash can.

---

## 2. Requirements

### R1 — Automatic. A resource author never writes affordances.
They are derived from what is already declared:
- **which actions exist** → `Ash.Resource.Info.actions/1`
- **which are exposed** → the resource's existing `AshJsonApi` **routes**
- **which the actor may run** → `Ash.can?/3`
- **valid from current state** → `AshStateMachine` transitions, where present

Default: advertise every routed action the current actor is authorized to invoke
and that is legal from the record's current state. Zero per-resource config.

### R2 — The DSL is override-only.
An optional per-resource block carries deviations only: `exclude` an action that
is routed but must not be advertised, `override` an action's derived `href`.
There are no per-action "enable" entries. A compile-time verifier rejects an
`exclude`/`override` naming an action that does not exist.

Applied once per `Ash.Domain`; every resource in that domain gets affordances
automatically.

### R3 — Every transport renders affordances natively. **MUST.**
The backbone produces one affordance set (R5). Each transport MUST express it in
that transport's own idiom — never a generic blob bolted onto a response, and
never one transport tunnelled through another. A client asks in its own protocol
and gets affordances in the form that protocol already understands.

| Backbone output | rendered in JSON:API as | rendered in MCP as |
|---|---|---|
| an action that may be taken next | a `links.<action>` object | a tool in `tools/list` |
| the affordance set for a state | the record's `links` | the `tools/list` result |
| field descriptor (R4) | link `meta.fields` | the tool's `inputSchema` |
| action `description` (R4) | link `title` / `meta` | the tool's `description` |
| structural navigation (R9) | `collection`/domain/root links | the `resources/*` primitive |

Adapters are **peers**. Neither is primary, neither is layered on the other, and
adding a third (UI action bar, CLI, HAL-FORMS) MUST require no backbone change.
Per-transport specifics are §5.

**The set is resolved per request, from the requesting client's own context** —
its actor, and the record or session position it is asking about. Two clients
hitting the same resource may legitimately receive different affordances.

### R4 — Affordances are self-documenting.
Ash already collects `description` on actions and arguments, and arguments carry
`default`, `constraints` and `sensitive?`.
The descriptor MUST surface them: the action's `description`; per field its
`description`, `default` and a `constraints.enum` derived from `one_of`.

Two rules: only **public** arguments become fields; **never emit a `sensitive?`
argument's `default`** (a sensitive argument may still appear as a field so the
client knows to supply it, without its value).

### R5 — The output envelope has a fixed, documented shape.
The envelope is a map of action name → **Affordance**. An Affordance carries
`href`, `method`, `description`, a list of **Field**s, and an optional
`multi_step` flag. Each Field carries `name`, `type`, `required`, `description`,
`default` (omitted when sensitive) and `constraints`.

Only the **set** of actions is dynamic — it lives in the map keys and is resolved
per record, actor and state at runtime. Everything below that key is fixed.

The shape MUST be settled from the start: the renderer must not emit structurally
different affordances across records or transports, MCP's `inputSchema` (§5.2)
projects from it, and changing it after release is a breaking change for every
client reading the links.

**Affordances stay out of the generated OpenAPI document.** They are a runtime
hypermedia concern, discovered in the response — not part of the static API
description. The shape is documented in the published profile (R3), which is
where clients look; it is not injected into OpenAPI schema generation.

### R6 — Validity: advisory, and never a parallel reimplementation.
Four senses of "valid", and how each is met:

| Sense | Met by |
|---|---|
| exists & is routed | route introspection (R1) |
| actor is authorized | `Ash.can?/3` |
| legal from current state | AshStateMachine gate (§3) |
| inputs are satisfiable | **deliberately not predicted** — see below |

Input-satisfiability is not pre-computed: it cannot be known before the caller
supplies input, and dry-running every action per record would be expensive and
still inexact. The descriptor's `fields`/`constraints` (R4) let a client validate
up front; anything remaining surfaces as a precise `422` at invocation.

One invariant:
- **Single source of truth.** Filtering MUST call `Ash.can?/3` and the real state
  machine — never a parallel reimplementation of a policy. Otherwise affordances
  and endpoints diverge.

**Posture on undecidable authorization: follow Ash.** The gate calls
`Ash.can?/3` as Ash provides it, with its own defaults. Ash returns `true` when
a decision cannot be reached without running queries (`maybe_is: true` is the
`can?/3` default), so an affordance whose authorization is record-dependent and
unresolved **is advertised**. This matches `AshAi.exposed_tools/1`, which
filters MCP tools the same way.

The consequence is explicit and accepted: a client may occasionally be offered
an action it turns out not to be permitted, and receive a `403` on invocation.
That is tolerable because affordances are **advisory** — the endpoint re-runs
the same policies, state machine and validations on invocation, so a stale or
optimistic proposal degrades to a clean error, never an invalid write.

Rejected alternative: passing `maybe_is: false` to fail closed. It would suppress
affordances whenever a policy is record-dependent and unresolved — the common
case for `relates_to_actor_via` and `exists(…)` — making the affordance set
quietly narrower than the actor's real permissions, which is its own broken
promise. Deviating from the framework's default posture on an
authorization-adjacent surface also invites divergence from every other Ash
consumer. Revisit only if a deployment demonstrates that over-offering is
causing real harm.

### R7 — Errors are loud.
An affordance is dropped silently for the expected "not permitted" outcome. Any
**exception** raised while evaluating authorization (bad expression, nil deref,
DB blip) MUST be logged with context before the affordance is dropped. Silently
degrading a real bug into a missing affordance is unacceptable on an
authorization-adjacent surface.

Note the limit of what is achievable here: `Ash.can?/3` raises on error rather
than returning a tagged tuple, so the gate rescues and cannot cleanly separate
"a policy check blew up" from "authorization was refused by exception". Both are
logged; neither is swallowed. `Ash.can/3`'s tuple form is available if precise
classification ever becomes necessary.

### R8 — Cost is bounded and correctness is never traded for speed.
The entire cost is `Ash.can?/3`; every other stage is in-memory DSL work with no
I/O. Cost therefore depends on policy shape: attribute checks are negligible;
relationship/expression checks (`relates_to_actor_via`, `exists(…)`) can each emit
a Postgres query. On a collection this multiplies as roughly *M records × N
actions × policy-query cost*.

Requirements:
- **On by default, opt-*out*.** Affordances are a hypermedia contract: a client
  must not have to remember a flag to get a navigable response, and a client
  that forgets one must not silently receive a non-hypermedia response. So the
  default is **on**, and it is switched off — not on — when not wanted. A single
  `enabled?` declaration per resource, with a domain-level default it inherits,
  so a deployment can turn a hot endpoint off without forking.
- **Collections never compute per-record affordances.** A collection response
  carries **collection-level** affordances only (`create`, index-style reads) in its
  top-level `links`; records inside it carry navigation but no affordances.
  This removes the `M × N` multiplication *structurally* rather than defaulting
  it off, so cost on a collection is `N` — independent of page size — and there
  is no flag to forget. It also serves the cold-start case directly: a client
  entering at a collection is told it may `create`, which is the first thing it
  needs (R9).

**No cross-record caching.** Every `Ash.can?/3` call is evaluated per record.
Caching per `(actor, action)` is only sound when a policy's outcome is
independent of the record, and **Ash exposes no way to determine that**: there
is no `record_dependent?` introspection, and a check module's `type()`
(`:simple | :filter | :manual`) describes how a check integrates, not what data
it reads. Any classifier would be a heuristic, and a wrong guess returns a
**wrong authorization answer** — record 1's verdict applied to records 2..M.

The trade is favourable because the multiplication is already gone: the policies
unsafe to cache are precisely the expensive ones (`relates_to_actor_via`,
`exists(…)`), while the ones safe to cache (`actor.role == :admin`) are
in-memory comparisons that cost almost nothing. Caching would have risked
mis-authorization to speed up the cases that were already fast.

Rejected alternatives: precomputing per `(resource, role, state)` process-wide
dissolves the cost but is unsound the moment any policy is record-dependent, and
adds cache invalidation. A static actor-scoped/record-dependent classifier is
unsound for the reasons above. Revisit only with profiling showing real cost,
and prefer an **explicit author declaration** over inference — the person who
wrote the policy knows its semantics; a static classifier cannot.

### R9 — Navigation: enter anywhere, reach anything.
Affordances answer *"what can I do with this?"*. Navigation answers *"where am I,
what else exists, and where do I start?"* — the other half of HATEOAS. A client
MUST be able to hardcode **one** entry point and from there reach every type,
every collection and every record, being told at each stop what it may do.

Three structural links are required, all derivable from existing declarations:

| Navigation need | Derived from |
|---|---|
| root: which types exist | `Ash.Domain.Info.resources/1` + the domain's declared routes |
| collection URL per type | the transport's declared collection route (`base_route`) |
| record → its collection | resource route introspection (the `:index` route) |
| record → its domain | `Ash.Resource.Info.domain/1` |
| domain → domain edges | `Ash.Domain.Info.related_domain/…`, `resource_references/1` |
| walk the data graph | `Ash.Resource.Info.public_relationships/1` |
| what may I do on a *type* | `Ash.Resource.Info.actions/1` + `action_inputs/2` + `Ash.can?/3` |

Nothing here is new author config — it is the R1 principle (read what is already
declared) extended from actions to structure.

**Collection-level affordances — a second backbone entry point.** Some actions
apply to a **type**, not a record: `create`, and index-style reads. A client that
has just entered the system has no record in hand, so this is the *first* thing it
needs. The backbone MUST therefore answer two shapes:

- `affordances(record, actor, …)` — record-level; the state gate applies.
- `affordances(resource, actor, …)` — collection-level; there is no record, so
  **no state gate** applies, but `Ash.can?/3` still does.

Both feed every adapter. R6's fail-closed rule and R8's cost rules apply to both.

**Authorization applies to navigation too.** Structural links MUST NOT reveal
types or collections the actor may not access. An unreachable branch is omitted,
not rendered-and-rejected — the same fail-closed posture as R6.

---

## 3. The backbone

**Input:** a record, the actor, and the **domain** (routes are declared at the
domain level, so the domain must be threaded through; a resource-only lookup is
insufficient).

**Pipeline:**
1. **Candidate set** — actions reachable via the resource's declared JSON:API
   routes, minus `exclude`s.
2. **Authorization gate** — `Ash.can?/3` per candidate (R6, R7).
3. **State gate** — where the resource has a state machine, drop actions that are
   not legal transitions from the record's current state.
4. **Descriptor** — per surviving action: `href` (from the declared route or an
   override), method, `description`, `fields` (R4).

**Output:** the typed envelope (R5), or nothing when no action survives.

### The gates are a pluggable pipeline
Steps 2–3 MUST be an **ordered, composable chain of filters**, not hardcoded
branches. Each filter receives the candidate set with the record, actor and
domain, and returns a possibly-reduced set; the chain short-circuits when the set
empties. Three consequences, all of which the requirements need anyway:
- The optional state gate becomes just another entry in the chain, present only
  when `ash_state_machine` is — no capability branching threaded through the
  backbone body.
- Consumers can insert their own filter (a tenancy rule, a feature flag) without
  forking the package.
- Each filter is independently testable, which matters most for the two that
  carry correctness weight (R6 fail-closed, R8 statically-gated caching).

Precedent: `ash_commanded` uses a declared middleware chain over commands
(`middleware AuditLogger`, `middleware {Authorization, roles: [:admin]}`) in a
Spark extension of the same shape as this one. Confirm its ordering and
short-circuit mechanics against its source before modelling on it closely.

### The state gate
Authorization ≠ validity from the current state. An actor authorized to run a
transition must still not see it advertised from a state the transition is not
legal from. Advertise an action only if the actor is authorized **and** (it is
not a transition at all, or it is a legal transition from the record's current
state). Transitions are in-memory DSL data — no DB hit.

`ash_state_machine` is an **optional dependency**: the backbone capability-checks
each resource and applies the gate only where a state machine exists. Resources
without one are unaffected. Introspection uses the public `AshStateMachine.Info`
API — `state_machine_transitions/1`, `state_machine_all_states/1`,
`state_machine_state_attribute/1` (bang variants available; each accepts a module
or a DSL map).

### Reactor-backed actions
From the outside a Reactor-backed action is an action with a name, arguments and
a route — discovery treats it like any other, and `fields` still derive from its
declared arguments. Internal saga steps MUST NOT be exposed as affordances. An
optional `multi_step` flag may signal a compound operation.

---

## 4. The package

**One standalone hex package** (working name `ash_hateoas`), **not split per
transport**: it carries the core plus both
renderings. Splitting would contradict the architecture — the transports are
projections of a single backbone, so the backbone needs one home.

It extends AshJsonApi and AshAI through public surface only (route/type
introspection, a Spark extension, `exposed_tools`, and the serialized document),
so it is not app-coupled and runs on **stock, unmodified dependencies** — no
fork, no patched dep, no upstream change required.

**Modules, by role.** Exact layout, dep pins, CI matrix and `hex.publish`
metadata are decided when the repo is created:
- *Core (transport-agnostic):* the backbone (§3); the Spark resource extension with
  its override-only section and entity struct; a verifier; a transformer that
  wires the backbone onto every resource carrying the extension.
- *JSON:API rendering:* the `links.<action>` renderer and the post-serialization
  transform that injects it (§5.1) — self-contained, stock deps.
- *MCP rendering:* the tool-list projection and the `list_changed` push (§5.2).

### Conventions taken from established Ash extensions
Read from source; adopt rather than reinvent.

**Generate the Info module — do not hand-write it.** `ash_archival`'s entire
introspection module is `use Spark.InfoGenerator, extension: …, sections: […]`,
which generates options, entity and per-option config functions (with bang
variants). Our override-only section (R2) gets its reader for free this way.
`ash_paper_trail` shows the hand-written fallback for entity filtering —
`Spark.Dsl.Extension.get_entities/2` then `Enum.filter` on the entity struct —
which is the pattern to use where the generated functions do not suffice.

**Transformer discipline (from `ash_archival`'s `SetupArchival`).** Our
auto-wiring transformer MUST follow the same shape:
- declare ordering explicitly with `after?/1` and `before?/1` against named Ash
  transformers, rather than relying on incidental order;
- **bail out on embedded resources** — it checks
  `Transformer.get_persisted(dsl_state, :embedded?, false)` and returns
  unchanged. Embedded resources have no routes and no identity, so affordances
  are meaningless for them; skipping them is required, not optional;
- build entities via `Transformer.build_entity/4` and add them with the
  `Ash.Resource.Builder.add_new_*` helpers (note `add_new_`: idempotent, does not
  clobber an author's own declaration);
- thread `{:ok, dsl_state}` through each step so a failure short-circuits.

**Type mapping needs an explicit table (from `ash_typescript`).** R5 requires a
typed `Field.type`. `ash_typescript` does not stringify Ash types ad hoc — it
keeps an explicit map from `Ash.Type.*` modules *and* their atom shorthands
(`:string`, `:utc_datetime`, …) to target-type names, with a single dispatch
function. Our renderer MUST do the same rather than calling `to_string/1` on a
type module: the atom and module forms both occur, and unmapped types need a
deliberate fallback, not `Elixir.Ash.Type.Foo` leaking into the wire format.

**State-machine introspection is a public API (`AshStateMachine.Info`).** The
state gate (§3) uses `state_machine_transitions/1`, `state_machine_all_states/1`,
and `state_machine_state_attribute/1` (plus bang variants; each accepts a module
*or* a DSL map, so the gate works at compile time and runtime). No private
access, no reimplementation.

**Precedent for a second rendering: `ash_graphql`.** It renders the same
resources and actions into an entirely different transport alongside
`ash_json_api`, without either knowing about the other — the model stays the
single source and each transport is an independent projection. That is exactly
the relationship between the JSON:API and MCP adapters (§5).

**Optional deps.** `ash_json_api`, `ash_ai` and `ash_state_machine` are all
optional: installing the package gives the core plus whichever renderings the
host app's deps support. A JSON:API-only app never loads the MCP module.

**Build order:**
1. The backbone + tests — prove the `can?` gate against a real resource.
2. The JSON:API `links` rendering: the post-serialization transform (§5.1) plus the
   renderer, validated end-to-end against a live endpoint on **stock deps**.
   R3 is part of v1's definition of done, not a follow-up.
3. The Spark extension, transformer, override-only section and verifier.
4. The state gate (§3) and statically-gated `can?` caching (R8) — both land in
   the core, so **both renderings gain them at once**.
5. The MCP adapter (§5.2).

**Consuming it:** add the dep, then add the extension alongside the transport
extension(s) on the resources that should expose affordances. Nothing else per
resource unless one needs an `exclude`/`override` — and every adapter renders
from the same declaration, with no second setup.

Realistic v1: ~400–600 LOC plus tests.

---

## 5. The adapters

Each adapter takes the backbone's affordance set (§3) and encodes it. They share
the backbone entirely — resources, routes, policies, state, the gate pipeline —
and diverge only at the final encoding. An adapter contains **no affordance
logic**: no policy checks, no state reasoning, no filtering of its own.

Both are optional and independently installable (§4). An app with only
`ash_json_api` gets the JSON:API adapter; an app with only `ash_ai` gets the MCP
adapter; an app with both gets both, from one declaration.

### 5.1 JSON:API adapter

Affordances render as named link objects on the resource. Link names are **not**
restricted by JSON:API 1.1 — "a link's relation type should be inferred from the
name of the link" — and a link object may carry `href`, `rel`, `title`, `type`,
`hreflang`, and `meta`. Affordances *are* links, so this is the correct slot:

```json
"links": {
  "approve": {
    "href": "/document/123/approve",
    "rel": "https://example.com/rels/approve",
    "title": "Approve this document",
    "meta": {
      "method": "POST",
      "fields": [{ "name": "notify", "type": "boolean", "required": false }]
    }
  }
}
```

`rel` gives each affordance a real hypermedia relation type. The affordance is
self-describing via `title` and `meta` (R4) and does not link out to an external
operation description. `meta.actions` is an acceptable equivalent only if a
`links` seam proves impossible; serializing into `attributes` is **not** an
acceptable shipped end state.

Align the vocabulary with prior art — `spring-hateoas-jsonapi` renders affordances
as link `meta` with `name`, `link{rel,href}`, `httpMethod`,
`inputProperties[{name,type,required}]` — and with HAL-FORMS / Siren `actions`.
Publish the semantics as a JSON:API **profile** so it is a documented, shareable
convention rather than a private one.

**Navigation (R9).** Structural links use registered IANA relation types in the
same `links` object, so navigation and affordances arrive together:
- on a record: a `collection` link to its type's collection, and a link to the
  owning domain;
- on a collection: `self`, plus the collection-level affordances (`create`, …) as
  named links exactly like record affordances;
- at the API root: an entry document listing each reachable type and its
  collection link — the one URL a client hardcodes.

Relationship navigation is already emitted by AshJsonApi's `:related` /
`:relationship` routes; R9 adds only the structural layer above it.

**Context resolution.** The actor comes from the request; the record is the one
being serialized. **Defaults:** R8 — on for single-record reads, opt-in for
collections.

#### Delivery: the serializer seam (VERIFIED, `ash_json_api` 1.7.1)
Available:
- `AshJsonApi.Resource.Info.routes(resource, domain \\ [])` — routes are
  **domain-level**. Route structs carry `:action`, `:action_type`, `:method`,
  `:name`, `:type`, `:route`.
- `AshJsonApi.Resource.Info.type/1` — the base path segment.

Not available: **a per-record seam for `links` or `meta`.**
`serialize_one_record/3` builds a resource object with hardcoded private helpers
— `links` gets the self link only, and per-record `meta` gets the pagination
keyset only, never the rest of `record.__metadata__`. Both are `defp` with no
callback. Document-level `meta` exists but cannot express per-record affordances:
a collection of 25 records may have 25 different affordance sets.

**R3 is a MUST, and the package MUST satisfy it by itself.** The seam is
implemented **inside this package**, on stock `ash_json_api`. No upstream
contribution, no fork, no patched dependency — the package must not be blocked by
someone else's merge queue, and a consumer must not have to run modified deps to
get affordances.

**Mechanism: post-serialization transform.** The package ships a Plug (or
equivalent response step) that runs after AshJsonApi has serialized the document
and injects the affordance links into each resource object before the response is
sent. It reads the document it is handed, matches each resource object by
`type`+`id`, and merges the backbone's `links.<action>` entries into that object's
`links`.

Why this is sound rather than a workaround:
- It touches **no private functions** — it operates on the serialized document,
  which is public output, not internals.
- It is **version-robust**: the JSON:API document shape is fixed by the *spec*,
  so it does not break when `ash_json_api` refactors its private helpers.
- It is **self-contained**: everything lives in this package, installable on
  stock deps.

Requirements on the transform:
- It MUST honour the R8 defaults — no affordance computation and no document
  rewriting where affordances are off for that request (collection reads by
  default, or anything a resource/domain has switched off).
- It MUST handle both single-resource and collection documents, and `included`
  resources, matching objects by `type`+`id`.
- It MUST be a no-op for any resource that does not carry the extension.
- Streaming/chunked responses, if used, MUST be considered — the transform needs
  the whole document, so it is incompatible with a streamed body.

If a future `ash_json_api` exposes a public per-record links/meta hook, the
renderer can switch to it as a **pure internal optimisation** — the backbone output
is identical, so the renderer stays a thin, swappable layer and no consumer sees
a change.

### 5.2 MCP adapter

An MCP tool *is* an affordance: "which tools should this agent be offered, given
the current state?" is the question the backbone already answers.

One protocol fact makes this fit: **`tools/list` is a live server-computed
function**, not a fixed catalog — the server returns whatever it decides on each
call, full replacement (MCP spec 2025-11-25, `server/tools`). So the list is
recomputed per request against current state, and a client that re-lists after
acting always sees the truth.

**The MCP adapter mirrors the JSON:API adapter one-to-one, in MCP's own
language.** Neither is a client of the other (§5.3); both project the same
backbone output. The correspondence is what keeps them peers:

| JSON:API | MCP |
|---|---|
| root entry document | `resources/templates/list` |
| collection (`GET /orders`) | `resources/list` |
| record + its `links` (`GET /orders/123`) | `resources/read` + its affordances |
| following a link | `tools/call` |

A record's affordances therefore travel **in that record's representation**, as
they do in JSON:API — control state lives in the representation, not in a
side-channel.

**How record-scoped affordances reach `tools/list` is an open design question**
(§6). `tools/list` takes no arguments, so the server cannot be told which records
a client cares about without holding something across requests. Whatever
mechanism is chosen MUST be documented as a deliberate, bounded exception rather
than left implicit.

**Authorization is already built in (VERIFIED, `ash_ai` 0.7.2).**
`AshAi.exposed_tools/1` filters every candidate tool through an `Ash.can?`-backed
check against the connection's actor, domain, resource, action and tenant — the
same single-source-of-truth guarantee as R6, already satisfied on this side.

Two nuances of that check, which the adapter MUST reconcile with R6: it runs with
`maybe_is: true, run_queries?: false` (**fails open** on undecidable, to keep
`tools/list` cheap — the opposite of R6's fail-closed stance), and it
short-circuits when a resource has no authorizers. Left as-is, MCP over-offers
where JSON:API under-offers; the adapter MUST NOT inherit a laxer posture than
R6 requires.

**What the adapter adds: the state gate.** `exposed_tools` filters by `can?`, not
by transitions, so unmodified it offers a transition from states it is not legal
from.
Supplying the backbone's state-gated set is the adapter's job.

**Navigation (R9) uses MCP's `resources` primitive, not tools.** MCP already
separates the two concerns, and the split maps onto ours exactly: **tools** are
*actions you invoke* (affordances); **resources** are *addressable data you read
and navigate* (navigation). The adapter MUST use each for its purpose rather than
modelling navigation as tools.

- **`resources/templates/list`** — expose each resource *type* as an RFC 6570
  **URI template** (e.g. `document://{id}`). This is the direct analogue of a
  collection route: it advertises a type without enumerating every record, which
  is what makes "enter anywhere" tractable for large collections.
- **`resources/list`** — enumerate concrete, addressable entries where that is
  meaningful; it is paginated.
- **`resources/read`** — fetch by URI.
- **`resource_link` content** — a tool result MAY return links to resources. This
  is hypermedia navigation *inside* MCP: acting on something hands the agent its
  onward links, exactly as a JSON:API response does.
- **`notifications/resources/list_changed`** and, where useful,
  `resources/subscribe` + `notifications/resources/updated` — keep navigation
  current, mirroring the `tools/list_changed` loop above.

URIs MUST encode the domain/type/record hierarchy (custom schemes are explicitly
permitted). Collection-level affordances (R9) are always available — the direct
analogue of a JSON:API collection's top-level `links` — and do not depend on any
notion of a record being "current".

**Context resolution.** The actor comes from the connection (AshAuthentication API
key / token). **Delivery mechanism:** `tools/list` for affordances, `resources/*`
for navigation, `resource_link` on tool results for onward links.

**Constraint: `listChanged` must not be advertised unless it is emitted.**
`listChanged` / `notifications/tools/list_changed` is **ratified and in the spec
today**, and Claude Code honours it. Advertising the capability while never
sending the notification is worse than advertising `false`, because it tells a
client not to poll. Either wire it up or do not claim it.

**Emerging protocol work** (not required; the above rests only on ratified
`list_changed`):
- **SEP-1821 (Dynamic Tool Discovery)** — optional `query` string on `tools/list`
  plus a `ServerCapabilities.tools.filtering` flag. **Draft, seeking sponsor.**
  Adopt only once ratified and supported in AshAI.
- **SEP-1300 (Groups & Tags filtering)** — **rejected.** Noted so it is not
  re-proposed.

### 5.3 Adapters do not layer on each other
No adapter may be implemented as a client of another's output. Bridging MCP over
the JSON:API HTTP surface would lose the backbone's structured set to a
serialize/re-parse round trip, add a network hop and a second auth story, and
make MCP inherit JSON:API's encoding constraints — all to reach data it already
has in process.

The one thing MCP legitimately reuses is JSON:API's **declared routes**, read via
introspection, so route declarations stay the single source for what exists and
where it lives. Where `ash_json_api` is absent, the candidate set falls back to
the resource's actions directly.

---

## 6. Open items before implementation
- **How record-scoped affordances reach MCP's `tools/list` (§5.2).** `tools/list`
  takes no arguments, so the server cannot learn which records a client cares
  about from the request alone. The options are: hold a bounded per-session set
  of records the client has dereferenced (server-held state, an explicit
  exception to statelessness); return record-scoped tools for every record
  (unbounded); or leave record affordances discoverable via `resources/read` but
  not invocable from `tools/list`. Whichever is chosen must be documented as a
  deliberate trade, and any per-session state must be a **set, not a cursor** — a
  single overwritable position makes a read silently revoke tools the client was
  previously offered.
- Confirm the exact `Ash.can?` argument form and options for the pinned Ash
  (`{record, action}` vs input form; `maybe_is:`, `run_queries?:`).
- Confirm `AshJsonApi.Resource.Info.routes/2` return shape for a real
  domain+resource pair.
- Confirm how a renderer reads the **actor** from context in Ash 3.29.
- Confirm the `Spark.InfoGenerator` generated-function names for our section so
  the Info module can be generated rather than hand-written (§5).
- Confirm `ash_commanded`'s middleware chain mechanics (declaration, ordering,
  short-circuiting) from its source before modelling the gate pipeline (§3) on it.
- Confirm the response-step integration point for the post-serialization
  transform (§5.1) in a Phoenix/Plug pipeline, including how it resolves the R8
  on/off decision for the request (single-record vs collection, and any
  resource/domain override).

## 7. References
- JSON:API 1.1 — link objects (`rel`/`title`/`meta`), link names not
  restricted: https://jsonapi.org/format/ · extensions & profiles:
  https://jsonapi.org/extensions/
- JSON:API discussions on discoverable actions:
  https://github.com/json-api/json-api/issues/622 ·
  https://discuss.jsonapi.org/t/opinion-about-describing-behaivours-actions-in-links-section/127
- Prior art — `spring-hateoas-jsonapi` affordances as link `meta` (experimental):
  https://toedter.github.io/spring-hateoas-jsonapi/
- AshJsonApi: https://ash-json-api.hexdocs.pm/ · serializer:
  https://github.com/ash-project/ash_json_api/blob/main/lib/ash_json_api/serializer.ex
- AshAI (MCP server, `exposed_tools`): https://hexdocs.pm/ash_ai/
- MCP tools spec (`listChanged`, `notifications/tools/list_changed`):
  https://modelcontextprotocol.io/specification/2025-11-25/server/tools
- MCP resources spec (`resources/list`, `resources/templates/list` RFC 6570 URI
  templates, `resource_link`, subscriptions) — the navigation primitive (R9):
  https://modelcontextprotocol.io/specification/2025-11-25/server/resources
- MCP SEP-1821 (draft): …/modelcontextprotocol/issues/1821 · SEP-1300
  (rejected): …/issues/1300
- Spark extensions: https://hexdocs.pm/ash/writing-extensions.html ·
  `Spark.InfoGenerator`: https://spark.hexdocs.pm/Spark.InfoGenerator.html
- Extension design precedents (read from source): `ash_archival`
  (`SetupArchival` transformer, InfoGenerator) ·  `ash_paper_trail`
  (entity introspection, transformer-generated companion resource) ·
  `ash_typescript` (`Codegen.TypeMapper` type table) · `ash_graphql`
  (second transport over the same model)
- AshStateMachine: https://hexdocs.pm/ash_state_machine/
- AshCommanded — Spark extension precedent for a declared middleware chain and
  transformer-generated modules: https://hexdocs.pm/ash_commanded/ ·
  https://github.com/accountex-org/ash_commanded
- HAL-FORMS; Siren; Ion — affordance vocabularies to align with
