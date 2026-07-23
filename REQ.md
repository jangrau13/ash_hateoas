# HATEOAS core — requirements

One engine computes authorization- and state-aware **affordances** ("what may be
done next"). Every transport is a **rendering** of that one engine's output:
JSON:API here, and — via the published profile — anything else built against the
documents rather than against this package (§5.2). This document is the
requirement set; implementation lives in the package (§5).

> **Status:** built. This document is kept as the requirement set and the record
> of why each decision went the way it did — it is not a plan.
>
> **Verified against** **ash 3.29.3 / ash_json_api 1.7.1 / spark ≥ 2.6**.
> Findings marked VERIFIED were read from those sources.

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

**Routes are themselves derived.** Until now they were only an input — the
author declared them and this package read them. `DeriveActionRoutes` (§5.1)
now derives them too, from the same principle applied one level down: every
action is routed unless declared `unrouted`, and the `base` comes from the
domain's `short_name` plus the json_api `type`. A resource declaring a `type`
and its actions needs no `routes` block at all.

This inverts the exposure default, and the trade is worth stating plainly.
Under the old allow-list, forgetting to think about an action yielded a 404;
under this deny-list it yields a live endpoint, with no diff to show for it
because the omission is in a file nobody edited. What buys it back is that
`unrouted` is verified against the action list, so a rename fails the build
rather than silently republishing — and that policies, not routes, remain the
actual gate on what any actor may invoke.

Two things are read rather than guessed, deliberately. The `base` uses the
`type` verbatim and is **not** pluralised: ash#31 removed exactly this guess
across the framework — ash_postgres stopped guessing table names and
ash_json_api stopped guessing base routes in one decision — because
pluralisation is where the guessing lives (`person` → `/persons`, `status` →
`/statuss`). And a generic action's **method** cannot be derived at all, since
`action :tally, :boolean` says nothing about whether it mutates; POST is
assumed because it understates nothing, and the verifier warns so the
assumption is visible rather than silent.

### R2 — The DSL is override-only.
An optional per-resource block carries deviations only:

| entry | deviation |
|---|---|
| `exclude :action` | routed, but not advertised |
| `override :action, href:` | replaces the derived `href` |
| `unrouted :action` | not routed at all, so not reachable over HTTP |
| `method :action, :get` | the verb for a generic action, whose type declares none |

There are no per-action "enable" entries: saying nothing yields the full
surface, and every entry above subtracts from it or corrects it. A compile-time
verifier rejects any of them naming an action that does not exist.

This is why R10's `not_delegable` lives in its own section rather than here: it
declares a new fact about an action instead of deviating from a derived one, and
folding it in would cost this rule its meaning.

Applied once per `Ash.Domain`; every resource in that domain gets affordances
automatically.

### R3 — Every transport renders affordances natively. **MUST.**
The backbone produces one affordance set (R5). Each transport MUST express it in
that transport's own idiom — never a generic blob bolted onto a response, and
never one transport tunnelled through another. A client asks in its own protocol
and gets affordances in the form that protocol already understands.

| Backbone output | rendered in JSON:API as |
|---|---|
| an action that may be taken next | a `links.<action>` object |
| the affordance set for a state | the record's `links` |
| field descriptor (R4) | link `meta.fields` |
| action `description` (R4) | link `title` / `meta` |
| structural navigation (R9) | `collection`/domain/root links |

Adding a transport MUST require no backbone change. A transport built against
the published profile (§5.2) requires no change here at all — which is the
stronger form of the same rule, and the one to prefer. Per-transport specifics
are §5.

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
`href`, `method`, `description`, a list of **Field**s, an optional `multi_step?`
flag, and — under R10 — an optional `not_delegable?` flag. Each Field carries
`name`, `type`, `allow_nil?`, `description`, `default` (omitted when sensitive)
and `constraints`.

Both flags are of the same kind: a declared, actor-independent fact about the
action's execution character, false unless the author says otherwise. Adding
`not_delegable?` is a change to the shape this section fixes, and is therefore
subject to the rule below — it MUST land before release, not after.

Note `allow_nil?`, not `required`: the struct mirrors Ash's own name and
polarity, and each renderer inverts it at the edge, since the wire formats say
`required`. Everything upstream of the renderer reads the way the resource DSL
does. `default` is `{:ok, value} | :error` rather than a bare value, because
`nil` is itself a legitimate default and the two must stay distinguishable.

Only the **set** of actions is dynamic — it lives in the map keys and is resolved
per record, actor and state at runtime. Everything below that key is fixed.

The shape MUST be settled from the start: the renderer must not emit structurally
different affordances across records or transports, every consumer of the
profile projects from it, and changing it after release is a breaking change for
every client reading the links.

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
unresolved **is advertised**.

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

**The probe runs preparations, and a preparation can raise.** The probe passes
no arguments, and for a read/create/action `Ash.can?/3` builds the query via
`for_read(action, %{})`, which runs the action's preparations. A preparation
that dereferences a required argument then meets `nil` and raises — a semantic
search whose `prepare` embeds the query is the canonical case. That is the query
malformed by the empty probe, not authorization failing, so the gate retries
against a query built with the action set directly and `for_read` never called:
preparations do not run, the action is authorized on its policies alone, and it
is advertised. Skipping preparations does not weaken the check — policies
authorize the action, preparations shape which rows. A genuine policy fault
raises through the retry too and is logged-and-dropped (R7).

**Known gap — argument-gated policies (designed, not built).** An action whose
POLICY depends on an argument value — `authorize_if expr(^arg(:tier) ==
"public")` — is decided `false` under the argument-less probe and hidden, even
though some input would authorize it. This differs from a genuine denial: a
denial is `false` from facts already known (the actor, the record, a constant);
this is `false` *only* because an argument was not supplied. The two should be
distinguished — a genuine denial stays hidden, an argument-gated one is
advertised as an **ordinary affordance**: its `fields` say what the caller must
supply, and R6 makes the endpoint the authority, so no third "maybe" state is
needed — that was a wrong framing. It cannot be fixed soundly in this package:
Ash resolves an absent argument to `nil` and returns a definite `false`, erasing
the distinction, and recovering it means either guessing argument values or
coupling to Ash's private policy internals. The fix is an upstream Ash change
that stops collapsing an absent argument to `nil` so the decision stays
undecided (and is then advertised optimistically per R6); see
`documentation/argument-gated-affordances.md`.

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
| walk the data graph | `Ash.Resource.Info.relationships/1` + derived routes |
| what may I do on a *type* | `Ash.Resource.Info.actions/1` + declared routes + `Ash.can?/3` |

Nothing here is new author config — it is the R1 principle (read what is already
declared) extended from actions to structure.

Two rows needed investigating; the findings differ.

**Walk the data graph — built.** `ash_json_api` renders
`relationships.<name>.links` only from declared `related`/`relationship` routes,
and declares none by default, so a public relationship serializes as a name with
an empty `links` object: a client is told an edge exists and given nowhere to
go. `DeriveRelationshipRoutes` supplies them (§5.1), and a test follows the
emitted link rather than merely asserting its presence.

To-**one** relationships are deliberately skipped. `ash_json_api` 1.7.1 raises
`FunctionClauseError` in `encode_primary_key/1` when serializing a to-one
`relationship` route — the same crash occurs with a hand-declared
`relationship :document, :read`, so deriving is not the cause — and emitting a
route that 500s would be worse than emitting none. Revisit when upstream fixes
it.

**Domain → domain edges — nothing to build.** Investigated and dropped as a
requirement rather than deferred. `Ash.Domain.Info.resource_references/1`
returns a domain's own resources, which the root document already enumerates via
`resources/1`; `related_domain/3` answers with the same domain for any
relationship inside it. Several domains mounted in one router share a base path,
so there is no second place to point at — a link would go from `/` to `/`, which
is the `up` relation already emitted. A genuinely separate deployment is a
different API, which is what `AshHateoas.Type.ResourceLink` addresses.

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

### R10 — Some actions may be advertised but not exercised by a delegated credential.

> **Status:** built. This section is the requirement set and the record of what
> was decided; `test/req/r10_test.exs` is the check that it holds.

An actor may be *authorized* to run an action and still be the wrong party to
run it **alone**. An autonomous agent holding a scoped credential derived from
its principal's authority is the motivating case; a service account, a sandbox
session and a scripted human are the same shape. Ash has no way to say this:
`Ash.can?/3` is a boolean, and this is a third state between allowed and
forbidden.

The action is declared **not delegable**:

```elixir
agentic_hateoas do
  not_delegable :publish
end
```

**Why the negative name.** The flag says what the mechanism does — a delegated
credential cannot exercise this action — and not what one hopes follows from it.
Naming it for the outcome would promise an approval workflow this package does
not implement. `not_delegable` matches the `unrouted` idiom already in the DSL: a
negative declaration about one action, verified against the action list.

**The section is named for the audience, the entry for the mechanism**, and the
mismatch is deliberate. `agentic_hateoas` is where an author will look for this,
since delegated credentials are overwhelmingly agents in practice. The entry
inside it must stay literal, because the endpoint refuses *every* non-committing
credential — a sandbox session, a service account, a scripted human — and a name
promising otherwise would be wrong at exactly the moment someone debugged an
unexpected 403.

The behavioural rule, stated once: **an action declared `not_delegable` is
refused when `commits?/1` answers false for the requesting actor.** Both
conditions are required; neither alone refuses anything.

The section is separate from `hateoas` because R2 declares that block
override-only, and this subtracts from nothing — it is a new fact about an
action, closer in kind to `description`. It is **not** an option on the action
itself: Spark offers only `Spark.Dsl.Patch.AddEntity`, so an extension cannot add
an option to another extension's entity, and the action structs are closed
`defstruct`s. Even were it possible, an option in an `update` block would be a
compile error wherever the extension is absent, coupling every action's
compilation to this package.

#### Two filters, in order

Authorization and delegability are independent, and the gate runs first. The rows
below are for a **non-committing** actor; a committing one commits throughout.

| Authorized (R6) | `not_delegable` | The actor sees | On invocation |
|---|---|---|---|
| no | — | nothing | plain 403, **no projection** |
| yes | no | the affordance | **commits** |
| yes | yes | affordance + flag | **403 + projection** |

This gives two distinct tools for two distinct intentions, and they do not
interfere. *"This credential has no business here"* is expressed by withholding
authorization — invisible, and refused bare, with no escalation path. *"This
credential may propose it, but another must commit"* is expressed by the flag —
visible, flagged, and refused informatively.

Authorization is R6's, unchanged: `Ash.can?/3` over whatever the deployment's
policies express. Where those policies narrow a delegated credential below its
holder's own authority — an API key scoped to a subset of its user's roles, say —
row 1 is how that narrowing surfaces, and this package needs to know nothing
about the mechanism (§6).

It also bounds what the flag can leak. A delegated actor only ever sees actions
it is authorized for, and that authorization was granted deliberately.

#### The flag is actor-independent

The DSL entry `not_delegable :publish` produces the Affordance flag
`not_delegable?` (R5), surfaced identically for every actor. Only the
*endpoint's* behaviour varies. A committing actor sees the same flag and commits
anyway — the declaration documents the action, it does not describe the reader.

#### Commit authority is asked, never inferred. **MUST.**

Ash treats actors as opaque — a struct, a token, a map, whatever the host puts
there — so this package MUST NOT inspect one. Inspecting would mean guessing at a
field (`actor.type`, `actor.kind`), and an actor shape the guess does not
recognise reads as "commits" and the write proceeds. Silent fail-open is
unacceptable on an enforcement surface.

It asks a module a single question instead:

```elixir
@callback commits?(actor :: term()) :: boolean()
```

Named for what the endpoint branches on, not for what the actor is: this package
holds no definition of "agent", and the same answer serves sandboxes, service
accounts and scripted humans.

**One module, application-wide.** It is not per resource and not per domain — it
describes the deployment's authentication, and a deployment has one of those.
Two domains disagreeing about whether the same actor commits has no coherent
meaning, so the choice is not offered:

```elixir
config :ash_hateoas, commit_authority: AshHateoas.CommitAuthority.ApiKey
```

**The package ships the implementation.** An author writes no module for the
common case. `AshHateoas.CommitAuthority.ApiKey` reads the metadata
`ash_authentication`'s api_key strategy already stamps on the actor —
`__metadata__[:using_api_key?]`, the same field its own `UsingApiKey` policy
check reads — and answers false for a key-authenticated actor, true otherwise.
It pattern-matches a map key and references nothing from that package, so the
dependency is documentation, not code (§6). The `@callback` remains so a
deployment on different authentication can supply its own.

Note what the shipped module means: **"holds a delegated credential"**, not "is
an agent". A human scripting with an API key is refused too. That is correct — a
script is not a party exercising judgment — and it MUST be documented, or it will
be reported as a bug.

Two defaults, and the second deviates from this package's usual posture
deliberately:

- **Unconfigured → everyone commits.** No `commit_authority` set means the
  feature is inert and R10 changes nothing for an existing deployment. Unlike
  R8's posture, this defaults *off*: affordances are a contract and default on,
  but this changes what an endpoint does.
- **Raised → does not commit, logged loudly.** R7 drops an affordance and
  continues, justified because affordances are advisory. This is an
  **enforcement** decision, so it fails **closed**. Failing open here is an
  unapproved write; failing closed is an unnecessary escalation.

#### Refusal is 403, and carries a projection

A non-committing actor gets **403**. Not 2xx: the request was "publish this",
that did not happen, and every HTTP client branches on `status < 300` before
anything reads the body. Not 202, which promises the action is queued when
nothing is. Not 409, which invites a retry the actor can do nothing to make
succeed.

403 is the same code an unauthorized actor already receives, and that is the
point: the projection is **additive**. A client reading only status codes treats
this exactly as a refusal, which it is, and behaves correctly with no knowledge
of R10; a client reading the body learns what the action would have done.

The body MUST be a structured error — a named type carrying the action and the
projection — never prose. A consumer pattern-matching on an English sentence
breaks when the sentence is edited.

#### The projection describes; it never runs. **MUST.**

The refusal carries what the action *would* do, so the party who must commit is
approving a direction rather than a keystroke. A known failure mode of approval
systems is the indistinguishable request approved by reflex; a refusal that says
only "not permitted" invites exactly that.

Nothing is executed to produce it. `Ash.Changeset.for_update/4` was considered
and rejected: it runs change modules, and a change module doing I/O — a charge, a
webhook, a mail — fires at build time. No option makes an arbitrary action safe
to simulate, and a preview that issues ten refunds is worse than no preview.

What is derived instead:

| Projected | Derived from |
|---|---|
| the transition | `AshStateMachine.Info.state_machine_transitions/2` |
| affordances at the target state | the existing gate chain, run against that state |
| the delta | gained and lost, a set operation on the two |

**The cost is a full chain run, not a free one**, and R8 governs it. The
transition lookup is in-memory DSL data, but the second row re-runs the gates —
including `Ash.can?/3`, which may query per candidate. This is acceptable only
because it happens on a **refusal**: once, for one action, for an actor who was
going to receive an error anyway. It is never on the read path and MUST NOT be
computed while rendering affordances.

The primitive is one function: *given resource, record, actor and a target state,
return the affordance set there.* Its limits MUST be documented on the function:

- The record is correct in the **state attribute only** and stale in every other,
  so a record-dependent policy answers about a record that will not exist. It is
  a projection for a human to read and **MUST NOT** be used as an authorization
  decision.
- Where a transition declares several `to` states, the result is a set of
  possible futures and MUST be presented as such rather than one being chosen.
- An action outside a state machine yields no projection. The profile MUST
  distinguish "nothing downstream" from "not derivable".

Computed with the **requesting** actor. Projecting another actor's future into
this actor's refusal mixes two authorities in one payload.

#### What is out of scope

Grants, escalation records, the review flow, notification and audit are
**not** this package. They are state; everything here is declaration and
derivation. They belong in a peer of `hateoas_mcp` (§5.2) that consumes the
profile.

One consequence: where approval is asynchronous — the realistic case, since a
human may answer hours later — a projection captured at refusal time is stale
when read. The consumer MUST recompute it at review time, with the committing
actor. That is why the primitive is a function and not a stored field.

---

## 3. The backbone

**Input:** a record, the actor, and the **domain** (routes are declared at the
domain level, so the domain must be threaded through; a resource-only lookup is
insufficient).

**Pipeline:**
1. **Candidate set** — actions reachable via the resource's declared JSON:API
   routes, minus `exclude`s.
2. **State gate** — where the resource has a state machine, drop actions that are
   not legal transitions from the record's current state.
3. **Authorization gate** — `Ash.can?/3` per candidate (R6, R7).
4. **Descriptor** — per surviving action: `href` (from the declared route or an
   override), method, `description`, `fields` (R4).

Gates run **cheapest-first**, which is why the state gate precedes
authorization: transitions are in-memory DSL data, while `Ash.can?/3` can emit a
query per candidate. Since the chain short-circuits on an empty set, an illegal
transition is never paid for with an authorization check.

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
- Each filter is independently testable, which matters most for the ones that
  carry correctness weight — the authorization gate (R6) and the state gate.

Precedent: `ash_commanded` uses a declared middleware chain over commands
(`middleware AuditLogger`, `middleware {Authorization, roles: [:admin]}`) in a
Spark extension of the same shape as this one.

### The state gate
Authorization ≠ validity from the current state. An actor authorized to run a
transition must still not see it advertised from a state the transition is not
legal from. Advertise an action only if the actor is authorized **and** (it is
not a transition at all, or it is a legal transition from the record's current
state). Transitions are in-memory DSL data — no DB hit.

`ash_state_machine` is an **optional dependency**: the gate is present in the
chain only when the dependency is, and applies per resource only where a state
machine exists. Resources without one pass through untouched. Introspection uses
the public `AshStateMachine.Info` API — see §4 for the two functions used and
the `:*` traps they carry.

### Reactor-backed actions
From the outside a Reactor-backed action is an action with a name, arguments and
a route — discovery treats it like any other, and `fields` still derive from its
declared arguments. Internal saga steps MUST NOT be exposed as affordances. An
optional `multi_step` flag may signal a compound operation.

---

## 4. The package

**One standalone hex package** (working name `ash_hateoas`), **not split per
transport**: it carries the core plus the
JSON:API rendering. Splitting those would contradict the architecture — the
rendering is a projection of the backbone, so the two belong in one home.

It extends AshJsonApi through public surface only (route/type introspection, a
Spark extension, and the serialized document), so it is not app-coupled and runs
on **stock, unmodified dependencies** — no fork, no patched dep, no upstream
change required.

**Modules, by role.** Exact layout, dep pins, CI matrix and `hex.publish`
metadata are decided when the repo is created:
- *Core (transport-agnostic):* the backbone (§3); the Spark resource extension with
  its override-only section and entity struct; a verifier; a transformer that
  wires the backbone onto every resource carrying the extension.
- *JSON:API rendering:* the `links.<action>` renderer and the post-serialization
  transform that injects it (§5.1) — self-contained, stock deps.

### Conventions taken from established Ash extensions
Read from source; adopt rather than reinvent.

**Generate the Info module — do not hand-write it.** `ash_archival`'s entire
introspection module is `use Spark.InfoGenerator, extension: …, sections: […]`,
which generates options, entity and per-option config functions (with bang
variants). Our override-only section (R2) gets its reader for free this way.
`ash_paper_trail` shows the hand-written fallback for entity filtering —
`Spark.Dsl.Extension.get_entities/2` then `Enum.filter` on the entity struct —
which is the pattern to use where the generated functions do not suffice.

**Transformer discipline.** Affordances themselves are never materialised into
the DSL — they are computed at request time from what is already declared, and
R2's override-only DSL leaves nothing to auto-wire. Routes are the exception,
and three transformers ship:

| transformer | shape |
|---|---|
| `MarkPrimaryGet` | *edits* an entity — marks a sole `:get` route `primary?` |
| `DeriveActionRoutes` | *builds* entities — a route per action, and the `base` |
| `DeriveRelationshipRoutes` | *builds* entities — `related`/`relationship` per public relationship |

All four of `ash_archival`'s rules apply across the set: explicit
`after?/1`/`before?/1` ordering, bailing out on embedded resources via
`Transformer.get_persisted(dsl_state, :embedded?, false)` (they have no routes
and no identity, so there is no record to link to), threading `{:ok, dsl_state}`
so a failure short-circuits, and `Transformer.build_entity/4` for the two that
add entities. `replace_entity/4` is the counterpart for `MarkPrimaryGet`'s edit.

**Ordering is load-bearing between the two derivers.** `DeriveRelationshipRoutes`
declares itself `after?` `DeriveActionRoutes`, because the `related`/
`relationship` routes it builds carry `action: :read` — the read used to fetch
the source record. `DeriveActionRoutes` treats any route naming an action as
the author having claimed it, so running second it would read those as a
hand-routed primary read and suppress that resource's `get` and `index`
entirely. It also filters relationship route types out of its "already routed"
check, so the ordering is belt-and-braces rather than the only thing holding it
up. This was a real bug, caught by a relationship-link test rather than by any
route test.

**Type mapping needs an explicit table (from `ash_typescript`).** R5 requires a
typed `Field.type`. `ash_typescript` does not stringify Ash types ad hoc — it
keeps an explicit map from `Ash.Type.*` modules *and* their atom shorthands
(`:string`, `:utc_datetime`, …) to target-type names, with a single dispatch
function. Our renderer MUST do the same rather than calling `to_string/1` on a
type module: the atom and module forms both occur, and unmapped types need a
deliberate fallback, not `Elixir.Ash.Type.Foo` leaking into the wire format.

**State-machine introspection is a public API (`AshStateMachine.Info`).** The
state gate (§3) uses `state_machine_transitions/2` — the arity-2 form, because
it filters on `action == :* or action == name` and so accounts for a wildcard
transition — and `state_machine_state_attribute!/1`. No private access, no
reimplementation.

Two `:*` traps, handled asymmetrically upstream and both load-bearing: a
wildcard **action** is covered by the arity-2 lookup, while a wildcard **from**
state is expanded by a transformer at compile time but still re-checked
defensively by consuming code — so the gate checks `current in from or :* in
from` too.

**Precedent for a second rendering: `ash_graphql`.** It renders the same
resources and actions into an entirely different transport alongside
`ash_json_api`, without either knowing about the other — the model stays the
single source and each transport is an independent projection. That is exactly
the relationship between this package and any consumer of its profile (§5.2).

**Optional deps.** `ash_json_api` and `ash_state_machine` are both optional:
installing the package gives the core plus whichever renderings the host app's
deps support.

**What shipped:** the backbone and its gate chain, the JSON:API rendering
(post-serialization transform plus renderer), the Spark extension with its
override-only section, transformer and verifier, the state gate, and R9
navigation. The MCP adapter that was planned as step 5 was built, then removed —
§5.2 records why.

**Consuming it:** add the dep, then add the extension alongside `AshJsonApi.Resource`
on the resources that should expose affordances. Nothing else per resource
unless one needs an `exclude`/`override`.

Note `open_api_spex` is required in the host app's deps: `ash_json_api` reaches
for `AshJsonApi.OpenApi` when validating a write, and that module only exists
when it is present.

---

## 5. The adapters

Each adapter takes the backbone's affordance set (§3) and encodes it. They share
the backbone entirely — resources, routes, policies, state, the gate pipeline —
and diverge only at the final encoding. An adapter contains **no affordance
logic**: no policy checks, no state reasoning, no filtering of its own.

The JSON:API adapter is optional and independently installable (§4): an app with
`ash_json_api` gets it, and an app without still has the backbone.

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

**Route derivation.** The routes affordances are computed from are themselves
derived, so a resource declares a `type` and its actions and nothing else:

| declared | derived |
|---|---|
| `type "comment"` in domain `MyApp.Blog` | `base "/blog/comment"` |
| primary read | `get` at `/:id` (marked `primary?`) and `index` at `/` |
| primary create / update / destroy | `post /`, `patch /:id`, `delete /:id` |
| a non-primary **collection** read (`get?: false`) | `index` at `/<name>` |
| a non-primary **member** read (`get?: true`) | `get` at `/:id/<name>` |
| any other non-read action | its own name under `/:id/<name>` |
| a generic action | `route` entity at `/:id/<name>`, method assumed `POST` |
| a public relationship | `related` and `relationship` routes |

Three rules govern the whole set:

1. **A declared route wins.** Derivation fills gaps and never overrules; a
   partial `routes` block is a partial declaration, not an opt-out for the rest.
2. **`unrouted :action` suppresses entirely**, and is verified against the
   action list so a rename fails the build rather than silently republishing.
3. **Nothing is guessed.** The `base` reads two declared facts and does not
   pluralise (see R1 on ash#31). The one fact that cannot be read — a generic
   action's HTTP method — is assumed `POST` *and warned about*, correctable
   with `method :action, :get`.

A non-primary read is split by what it returns, because that decides whether it
even has a member URL. Ash's own `get?` flag is the signal — it "expresses that
this action innately only returns a single result". A `get?: false` read returns
a collection, so `/:id/<name>` is meaningless (there is no `:id` for a search),
and it derives an `:index` at `/<name>`: reachable without an identity, its
public arguments arriving as query params, and advertised as a collection
affordance. A `get?: true` read returns one record and keeps `/:id/<name>`. This
is what lets a resource carry several reads — `search`, `recent`, `by_region` —
and have each routed and advertised correctly without a hand-written route.
Several `index` routes therefore coexist: `AshHateoas.Navigation` names the
canonical collection as the index at the base path (the one whose route does not
end in its own action name), so the named sub-collections never shadow it and
the type stays reachable from the root document (R9).

Generic actions route through `ash_json_api`'s `:route` entity rather than a
verb entity. That is load-bearing: `get`/`index`/`post` require a generic action
to return the resource struct, because they serialize the result as a resource
object, while `:route` has its own controller and applies no return-type check.
So `action :tally, :boolean` is routable, and `returns` needs no inspection.

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
- It computes affordances for any **routed** resource. The backbone is usable
  without the extension, and R8's `enabled?` is what switches a resource off.

  Note that carrying the extension is no longer surface-neutral. It once only
  *supplied declarations* (`exclude`, `override`, `enabled?`) over routes the
  author had written; since R1's route derivation it also *creates* routes, so
  adding `AshHateoas.Resource` to a resource widens that resource's HTTP
  surface to every action it declares. That is the intended behaviour, but it
  makes the extension something to add deliberately rather than incidentally.
- Streaming/chunked responses, if used, MUST be considered — the transform needs
  the whole document, so it is incompatible with a streamed body.

If a future `ash_json_api` exposes a public per-record links/meta hook, the
renderer can switch to it as a **pure internal optimisation** — the backbone output
is identical, so the renderer stays a thin, swappable layer and no consumer sees
a change.

### 5.2 Other transports build against the profile, not against this package

The MCP adapter that used to live here has been removed, and the reasoning is
worth keeping.

An in-process adapter can reach `Ash.can?/3`, the record, and the actor — which
is genuinely more capable than anything working from the rendered document. But
it also means every transport is a module in this package, each coupled to
whichever client library that protocol happens to favour, and each a reason for
this package to carry another optional dependency.

The alternative is that a transport is a **client of the published documents**.
`documentation/profiles/affordances.md` describes them completely enough to
drive: the actions available now, their methods, their inputs with types,
constraints and descriptions, and the navigation between records. A consumer
that reads those needs no knowledge of Ash, of Spark, or of this package.

`hateoas_mcp` is the demonstration: an MCP server over HTTP that discovers a
service's types from its root document, turns affordances into tools, and drives
a state machine it was never told about — with no Ash dependency at all. It is
also the test of the claim. Anything a transport needs that the profile does not
publish is a gap in the profile, and belongs here rather than in the consumer.

What this package therefore owes a transport:

- **completeness** — a document must carry everything needed to act on it, since
  the consumer cannot ask a second question of the backbone
- **followability** — every URL in a document must resolve as given; a consumer
  told to follow links and construct nothing has no way to repair a wrong one
- **honesty about state** — an affordance is advertised only when it is
  available now, because a consumer will offer it and a client will act on it

### 5.3 An in-package adapter never layers on another's output

Within this package, no adapter may be implemented as a client of another's
rendered output: it would lose the backbone's structured set to a
serialize/re-parse round trip, and inherit the other transport's encoding
constraints to reach data it already has in process.

This does **not** forbid an out-of-package consumer from reading the documents
over HTTP — that is §5.2, and it is the intended way to add a transport. The
distinction is where the code lives. A module in this package has the backbone
in hand and should use it; a separate package does not, and pays a round trip
for independence from Ash. Both are coherent; mixing them is not.

Route declarations stay the single source for what exists and where it lives.
Where `ash_json_api` is absent, the candidate set falls back to the resource's
actions directly.

---

## 6. Resolved questions

Kept as findings, since each cost something to establish.

- **`Ash.can?/3` argument form.** `{record, action}` for record-level, which
  makes Ash inject `data: [record]` so record-dependent policies see it;
  `{resource, action}` for collection-level. Read actions additionally take
  `data:` — read policies produce filters, not a yes/no. Options are Ash's own
  defaults (`maybe_is: true`), so an undecidable authorization advertises;
  R6 accepts the consequence.
- **`AshJsonApi.Resource.Info.routes/2`.** Routes are declared at **both** domain
  and resource level; the arity-1 form returns only resource-level ones, so the
  domain must be threaded through or the candidate set is silently half-empty.
- **The record's own URL.** `ash_json_api` renders `self` from the `:get` route
  marked `primary?`, and the option defaults to false — so a plain `get :read`
  yields records carrying no link to themselves. A transformer marks a sole
  `:get` route primary; where several exist the verifier warns and leaves the
  choice to the author. Nothing in this package constructs the URL.
- **Prefixes.** The domain's json_api `prefix` is applied by `AshJsonApi.Router`
  when matching, so a declared route is served at exactly its declared path.
  Prepending the prefix again produced hrefs that 404'd while navigation links
  resolved — one document, two bases, one of them dead.
- **The response-step integration point.** `before_dispatch` captures the typed
  `%Route{}`, and `register_before_send/2` merges into the public document. No
  private function of `ash_json_api` is touched.
- **How record-scoped affordances reach MCP's `tools/list`.** They do not, and
  the question dissolved with the adapter (§5.2). A consumer built against the
  profile passes the record's URI as a tool argument, so `tools/list` needs no
  per-session position — which was the only reason server-held state had been
  considered.
- **Telling a delegated actor from a direct one (R10).** RFC 8693 already draws
  the distinction and has since 2020: `sub` is the party being acted for, `act`
  the party acting, chains nest `act` within `act`, and §1.1 separates
  *delegation* (the agent keeps its own identity) from *impersonation* (it does
  not). Do not invent a vocabulary. But do not hardcode one either:
  `draft-klrc-aiagent-auth` names the agent with `client_id` instead, and the
  two drafts disagree — which is the argument for `commits?/1` being a callback.
  For an autonomous actor with no principal behind it, `sub` is the actor itself.
- **Where the scoping lives, with `ash_authentication`.** On an **API key**, not
  on a second principal. The api_key strategy stamps
  `__metadata__[:using_api_key?]` and `__metadata__[:api_key]` — the key *record*
  — onto the actor, and ships an `AshAuthentication.Checks.UsingApiKey` policy
  check. The delegated actor therefore authenticates **as its principal**, with a
  credential that narrows: policies evaluate the principal's roles *and* the
  key's scopes, so "the delegate can never exceed its principal" holds by
  construction rather than by maintenance. Modelling the agent as its own
  authenticatable resource was rejected for the opposite reason — two principals
  make the subset property a claim to uphold, and lengthen every
  `relates_to_actor_via` path.

  `commits?/1` then matches on `__metadata__[:using_api_key?]` rather than on a
  struct. Note this means "holds a delegated credential", not "is an agent" — a
  human scripting with a key is refused too, which is correct and must be
  documented, because someone will otherwise file it as a bug.
- **Key expiry is the implementor's job, and the hook is the relationship.**
  `ApiKey.SignInPreparation` applies `api_key_relationship.filter` *before*
  looking the key up, so expiry belongs there — `filter expr(valid_until >
  fragment("now()") and is_nil(revoked_at))` — and not in a policy, which would
  authenticate first. An expired key then takes the `{:ok, nil}` branch, which
  performs a dummy `secure_compare` against random bytes: expired and
  nonexistent are indistinguishable in time. Nothing in the strategy checks
  expiry itself; its own security note says so.

  Two consequences worth stating. Delegated authority lapses without anyone
  revoking anything, which is the property the capability-token literature wants
  and costs one filter here. And under async approval, a credential that expires
  during the wait simply cannot act — the consumer needs no staleness check of
  its own. The gap to watch is a session JWT minted at key sign-in, which
  outlives the key by its own `token_lifetime`.

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
- `hateoas_mcp` — an MCP server built against the published profile, over HTTP,
  with no dependency on this package: https://github.com/jangrau13/hateoas_mcp
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
- RFC 8693 OAuth 2.0 Token Exchange — `act` / `may_act`, and delegation vs
  impersonation (§1.1): https://www.rfc-editor.org/rfc/rfc8693.html
- draft-klrc-aiagent-auth — names the agent with `client_id` instead of `act`;
  individual submission, no WG standing, and the reason R10 asks rather than
  assumes: https://datatracker.ietf.org/doc/draft-klrc-aiagent-auth/
- MCP, *Tool Annotations as Risk Vocabulary* — why `readOnlyHint` and friends
  are **not** an approval declaration ("clients MUST treat them as untrusted");
  the nearest prior art to R10's flag, and the reason it is enforced at the
  endpoint rather than merely advertised:
  https://blog.modelcontextprotocol.io/posts/2026-03-16-tool-annotations/
- AshAuthentication api_key strategy — `__metadata__[:api_key]`,
  `AshAuthentication.Checks.UsingApiKey`, and its note that generating,
  expiring and revoking keys are the implementor's:
  https://hexdocs.pm/ash_authentication/AshAuthentication.Strategy.ApiKey.html
