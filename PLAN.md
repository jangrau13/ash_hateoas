# ash_hateoas — implementation plan

## Context

`REQ.md` specifies a standalone Ash package that computes authorization- and
state-aware **affordances** ("what may be done next") once, in one backbone, and
renders that single result into multiple transports — JSON:API and MCP today,
others later. The gap it closes: JSON:API is strong on navigation and silent on
affordances, and Ash is unusually well-placed to fix that because actions,
routes, policies and state-machine transitions are all already declared and
introspectable.

The repo was empty apart from `REQ.md`. This plan covers building the package
from scratch, on its own local deps, with REQ §6's open items resolved against
real dependency source rather than assumed.

**Environment status (done):** `mix.exs` + `mix deps.get` completed in-repo.
Resolved exactly to REQ's pins — ash 3.29.3, ash_json_api 1.7.1, ash_ai 0.7.2,
spark 2.7.2, ash_state_machine 0.2.13, plug 1.20.3. Deps live in
`/Users/jan/Documents/fun/ash-hateoas/deps`.

---

## Verified findings (REQ §6 open items)

Read from local `deps/`. These correct two assumptions in REQ and drive the design.

### The authorization gate — plain `Ash.can?/3`

Use what Ash provides, with its own defaults. No option tuning, no wrapper:

```elixir
Ash.can?({record, action}, actor, domain: domain, tenant: tenant)
rescue
  e ->
    Logger.error("...context: resource, action, actor...")
    false
end
```

This matches `AshAi.exposed_tools/1` (`deps/ash_ai/lib/ash_ai.ex:713-746`), the
established precedent for filtering a candidate list by authorization.

Details that matter at the call site:

- The `{record, action}` form injects `data: [record]` automatically
  (`can.ex:371-377`).
- `{resource, :nonexistent}` **raises `ArgumentError`** rather than returning
  false (`can.ex:258`) — the R2 verifier and the candidate-set stage must
  guarantee the action exists before calling.

**This is fail-OPEN, and REQ must be amended to match.** `can?/3` defaults to
`maybe_is: true` (`deps/ash/lib/ash.ex:993`), so undecidable authorization
returns `true` and the affordance is advertised. Concretely: a record-dependent
policy (`relates_to_actor_via`, `exists(…)`) that Ash cannot resolve without a
query yields `:maybe` → `true`. A client sees `links.approve`, invokes it, and
receives a 403.

That is a coherent posture — affordances are advisory and the endpoint re-runs
every policy on invocation — but it is the **opposite** of what REQ R6 currently
mandates ("Fail closed… a proposed-but-forbidden one is a broken promise").

**Task (Phase 1): rewrite R6 in `REQ.md`** to state the advisory/fail-open
posture, so the spec and the implementation agree. Both the fail-closed rule and
R6's "Undecidable authorization → do not advertise" line go; the
"single source of truth" invariant stays (we still call real `Ash.can?/3`, never
a reimplemented policy). R7's exception logging also relaxes: `can?/3` raises on
`{:error, _}` (`can.ex:31-56`), so the rescue catches genuine bugs and
forbidden-errors in one clause — everything is logged, but the two classes are
not separable at the call site.

### Actor from a conn

```elixir
actor = Ash.PlugHelpers.get_actor(conn)
```

`deps/ash/lib/ash/plug_helpers.ex:80-87`. Note `get_actor/1`, **not** `actor/1`.
Reads `conn.private.ash.actor`, where an upstream auth plug put it via
`set_actor/2`. Also checks legacy `conn.assigns.actor`, with a deprecation
warning. Returns `nil` for an unauthenticated request — never raises, and `nil`
is a valid actor to pass to `can?/3`.

**Why this exact function:** ash_json_api imports it
(`deps/ash_json_api/lib/ash_json_api/request.ex:28`) and populates its own
`%Request{}` from it. Reading the same source means our affordances are computed
for the same actor the endpoint authorizes against — no silent
"affordance said yes, endpoint said no" drift.

Ruled out: there is no process-dictionary actor store in Ash 3.29 (the actor
travels explicitly on the conn), and `Ash.Context` is a deprecated shim —
`Ash.Scope` replaced it, and `can?/3` accepts a scope struct as its second
argument if an app already threads one.

### Plug, not Phoenix — verified

**The package depends on Plug only. Phoenix is never required.**

- `Ash.PlugHelpers` is guarded by `if Code.ensure_loaded?(Plug.Conn)` and
  aliases `Plug.Conn`; no Phoenix reference (`plug_helpers.ex:5-11`).
- `AshJsonApi.Router` is `use Plug.Router`. Its only Phoenix references are a
  doc line and an optional `Phoenix.VerifiedRoutes` behaviour behind
  `Code.ensure_loaded?(Phoenix.Router)` (`router.ex:67-69`) — it compiles away
  when Phoenix is absent. `phoenix` is an optional dep in its `mix.exs:154`.
  The docs say "your Phoenix router **or plug pipeline**" (`router.ex:23`).
- `AshAi.Mcp.Router` is `use Plug.Router` with **zero** Phoenix references.

Consequences for this package: `{:plug, "~> 1.16"}` is the only web dependency;
the transform is a plain Plug composable into any Plug pipeline (Phoenix,
Bandit/Cowboy directly, or a bare `Plug.Router`); and the test suite drives the
routers with `Plug.Test` rather than `Phoenix.ConnTest`. No Phoenix anywhere in
`mix.exs`, lib, or test.

### R8 cost — solved structurally: collections never compute per-record affordances

**Decision (confirmed with user).** A collection response carries **type-level
affordances only**, in its top-level `links` — `create` and index-style reads,
from R9's `affordances(resource, actor, …)` entry point. Records inside `data`
get navigation (`self`) but **no per-record affordances**.

This removes the M × N multiplication entirely rather than defaulting it off.
Cost for a collection is N `can?` calls (one pass for the type), independent of
page size. The expensive case REQ R8 was written to manage no longer exists.

It also serves R9's cold-start case directly: a client entering at `/documents`
is told it may `create`, which is "the *first* thing it needs" — previously that
arrived only if someone opted collections in.

Consequence: **`collection_enabled?` is dropped.** One toggle per resource,
`enabled?`. Collection behaviour is a fixed rule, not a configurable posture.
`route.type` (`:get` vs `:index`) still selects *which* backbone entry point
runs — record-level or type-level — but no longer gates whether affordances
appear at all.

### R8 caching — dropped from v1 (decision)

R8 asks for `can?` results cached per `(actor, action)` where a policy's outcome
is independent of the record. That requires classifying each action's policy set
as actor-scoped vs record-dependent — and **that classification cannot be made
exactly in Ash 3.29.**

**No `record_dependent?` / `actor_only?` callback or Info function exists.**
`@optional_callbacks` in `deps/ash/lib/ash/policy/check.ex:135-141` confirms the
absence. The available signals — `check_module.type()`
(`:simple | :filter | :manual`, `check.ex:19`, `:98`) and
`requires_original_data?/2` (`check.ex:89`) — are properties of the check
**module**, not of the check instance with its options. A `:simple` check may
still branch on subject internals, and a policy's `condition` is itself a check
ref, so a policy can be *conditionally* record-dependent. Any classifier is a
heuristic.

**Decision (confirmed with user): no cross-record caching in v1.** Every
`can?` call is evaluated per record.

The reasoning is that the optimization was never worth its risk. Caching a
record-dependent policy on `(actor, action)` returns a **wrong authorization
answer** — the same actor gets record 1's verdict applied to records 2..M. The
policies unsafe to cache are precisely the expensive ones (`relates_to_actor_via`,
`exists(…)`) that motivated caching in the first place; the ones safe to cache
(`actor.role == :admin`) are in-memory comparisons that cost nearly nothing.
So the heuristic would have carried a data-leak risk to speed up the cases that
were already fast.

Revisit only with profiling showing it matters, and prefer an explicit
author declaration over inference if so — the person writing the policy knows
its semantics; a static classifier cannot.

**R8's other half — the on/off posture — is fully implemented** (below).

---

### JSON:API: no per-record seam (REQ §5.1 confirmed), but a better mechanism exists

**Confirmed absent.** `serialize_one_record/3` is `defp`
(`deps/ash_json_api/lib/ash_json_api/serializer.ex:527-537`). Per-record `links`
is `%{}` or `%{"self" => url}` (`:539-553`); per-record `meta` receives only the
keyset (`:556-568`). All five public `serialize_*` functions terminate in
`Jason.encode!`, so no caller can intercept a structured document. The
post-serialization transform is the correct design, not a workaround.

**Two-stage mechanism (better than re-parsing blind).**

1. **Capture** — `before_dispatch`, a documented router hook
   (`deps/ash_json_api/lib/ash_json_api/router.ex:31-53`, invoked at
   `controllers/router.ex:164-184`), receives `%{domain, resource, route, params}`.
   Stash it on `conn.private`. This yields the typed `%Route{}` **before**
   serialization.
2. **Merge** — `Plug.Conn.register_before_send/2`. Verified viable:
   ash_json_api registers no `before_send` of its own (no ordering conflict);
   `send_resp` sets `state: :set` then calls `Plug.Conn.send_resp/1`
   (`controllers/response.ex:132-139`), which is exactly when callbacks fire;
   content-type is set before send, so the callback can gate on
   `application/vnd.api+json`.

**Responses are never streamed or chunked** — zero `chunk` hits in the library;
every render funnels through the single `send_resp/3`. REQ §5.1's streaming
caveat is satisfied by construction.

**This also solves R8's read-kind question.** `route.type` is `:get` (single) vs
`:index` (collection), both `action_type: :read`
(`resource.ex:100`, `:121`). Precise, and better than inferring from whether
`data` decodes to a list. There is no built-in conn assign carrying the route —
`before_dispatch` is what puts it there.

**Corrections to REQ:**

- **Routes are both domain- AND resource-level.** `routes/1` returns *only*
  resource-level routes; domain-level routes are only included when domains are
  passed: `AshJsonApi.Resource.Info.routes(resource, all_domains)`
  (`resource/info.ex:50-63`). REQ says "routes are domain-level" — it is both,
  and calling the arity-1 form yields a half-empty candidate set.
- **Profiles: ash_json_api has no support, so we do it ourselves.**

  A JSON:API 1.1 *profile* is how a server advertises a convention the base spec
  doesn't define — such as "affordances appear as named link objects carrying
  `meta.fields`". It is advertised as a media-type parameter:

  ```
  Content-Type: application/vnd.api+json; profile="https://…/affordances"
  ```

  REQ §5.1 requires this so our link semantics are a documented, shareable
  convention rather than private knowledge a client needs out-of-band.

  What ash_json_api actually does: it *whitelists* `ext`/`profile` on **incoming**
  Content-Type headers (`request.ex:355-374`) purely so such a request isn't
  rejected with a 415 — the values are never read or stored. And it **never
  emits** the parameter: `response.ex:134` calls
  `put_resp_content_type("application/vnd.api+json", nil)`, where `nil` is the
  params argument. There is no DSL to declare a profile.

  **So the before_send callback overwrites the content-type** to append our
  profile URI, alongside the body merge it is already doing. Two deliverables,
  not one: the header, and the **profile document itself** — a page defining
  `links.<action>`, `meta.method` and `meta.fields`, published at the URI we
  advertise. Both land in Phase 2.
- **Generic-action responses are not JSON:API documents**
  (`controllers/response.ex:24-42`) — skip any document lacking a `data` key.

**Other specifics for the renderer.** `%Route{}` has no per-field types
(`@type t :: %__MODULE__{}`) — read types off the DSL schema in
`resource/resource.ex:6-79`. `AshJsonApi.Resource.Info.type/1` is the join key
matching each resource object's `"type"`. Reverse-map JSON type → Ash module
with a prebuilt index over `Ash.Domain.Info.resources/1` filtered by
`AshJsonApi.Resource in Spark.extensions(resource)` (the idiom at
`controllers/router.ex:120`). Reuse the public
`AshJsonApi.Resource.route/3` (`resource.ex:797-804`) which applies
`route_visible?/2` — mirroring it avoids advertising hidden relationships.
Merge defensively: `Map.update(obj, "links", new, &Map.merge(&1, new))`.

### Resources with no authorizers bypass the gate entirely

`deps/ash/lib/ash/can.ex:667-673` — when `Ash.Resource.Info.authorizers/1`
returns `[]`, the answer is `true` **before anything is evaluated**; the
short-circuit precedes policy evaluation entirely.

This is not an `ash_ai` quirk (REQ §5.2 attributes it to `exposed_tools`) — it
is Ash's own behaviour, so **both** adapters inherit it. Consequence: a resource
that simply forgot its `policies` block advertises every routed action,
including `destroy`, to an anonymous actor. Correct Ash semantics; dangerous
default for a hypermedia affordance surface.

**Decision (confirmed with user):** warn, do not fail. No policies means no
restrictions is correct Ash semantics, and the extension must not override the
author's judgment — a resource may legitimately be fully public. The verifier
emits a compile-time **warning** when a resource carries the extension and has
zero authorizers, with an opt-out for deliberately-public resources. Covered by
an explicit test asserting the warning fires and that affordances are still
advertised.

### Confirmed present (R1/R9 introspection)

All at the arities REQ assumes — `deps/ash/lib/ash/resource/info.ex`:
`actions/1` (:670), `action/3` (:685), `action_inputs/2` (:727),
`public_relationships/1` (:407), `domain/1` (:13). And
`deps/ash/lib/ash/domain/info.ex`: `resources/1` (:16),
`resource_references/1` (:29), `related_domain/3` (:50).

`Ash.DataLayer.Ets` ships inside `ash` itself
(`deps/ash/lib/ash/data_layer/ets/ets.ex`) — the chosen ETS test suite needs no
extra dependency, no Postgres, no docker.

### Spark mechanics — generated vs hand-written

`Spark.InfoGenerator` (`deps/spark/lib/spark/info_generator.ex`) expands to three
macros. Naming = section path joined with `_`. Critical asymmetry
(`info_generator.ex:178-282`):

- **Predicate options (`name?`)** → ONE function `hateoas_opt?/1`, bare value, no
  bang variant.
- **Non-predicate options** → TWO functions: `hateoas_opt/1` returning
  `{:ok, v} | :error`, and `hateoas_opt!/1`. **With a default, the plain form
  never returns `:error`** (`:229-231`) and the bang form never raises.
- **Entities** → `hateoas/1` (path joined, no suffix), only for sections with
  entities or `patchable?` (`:96`).
- `hateoas_options/1` **rejects nils** (`:79`) — unusable for "was it set?".

All generated functions are `defoverridable` but are plain defs, so **`super/1`
is unavailable** — wrap, don't override. Precedent to imitate exactly:
`AshStateMachine.Info` (`deps/ash_state_machine/lib/info.ex:7-21`) — arity-1
generated, arity-2 hand-written on top, persisted values via `get_persisted`.

`Spark.Dsl.Extension.get_entities/2` and `get_opt/5`
(`deps/spark/lib/spark/dsl/extension.ex:258-353`) accept module, `%struct{}`
record, **or** dsl map — so the same Info calls work in transformers, verifiers
and at runtime.

Transformer/verifier shape from `deps/ash_state_machine`: `before?/1` and
`after?/1` **need a catch-all `(_), do: false`** clause or they raise
FunctionClauseError; `transform/1` returns `{:ok, dsl_state}`; `verify/1` returns
bare `:ok`; errors raise `Spark.Error.DslError` with a `path:` mirroring DSL
nesting. Entity targets must `defstruct` schema keys **plus `__identifier__` and
`__spark_metadata__`** — Spark enforces this (`entity.ex:436`).

### State machine: the wildcard trap

`AshStateMachine.Info` functions all exist as REQ states, accepting module or dsl
map. `%Transition{}` is `[:action, :from, :to, :__identifier__, :__spark_metadata__]`
(`ash_state_machine.ex:6-19`).

**Wildcards are asymmetric.** Action `:*` is checked at lookup time
(`info.ex:12-14`); state `:*` is expanded at compile time by a transformer, and
consuming code still defensively re-checks. `@type` says `from: [atom]` but the
schema allows a bare atom — **always `List.wrap/1`**.

The state gate should follow `possible_next_states/1`
(`ash_state_machine.ex:238-252`), which handles both: filters on
`current_state in from or :* in from`. `deprecated_states` are in `all_states`
but excluded from `:*` expansion.

### MCP: two REQ assumptions are wrong

**`notifications/tools/list_changed` is never emitted.** `server.ex:463`
hardcodes `%{"tools" => %{"listChanged" => false}}`; no push channel exists.
REQ §5.2's entire transition loop depends on it. Ratified in the *protocol*,
absent from *this implementation*.

**`resources/templates/list` is entirely unimplemented** — no `resourceTemplates`
key, no RFC 6570 support anywhere. REQ §5.2 makes URI templates the basis for
"enter anywhere". What exists: `resources/list` (`server.ex:256-274`),
`resources/read` (`:277-341`), and an `mcp_resources` DSL section mapping Ash
actions to MCP resources.

Also absent: `resources/subscribe`, `prompts/*`, pagination on `tools/list`.

**`exposed_tools/1` fails open, as REQ says** — `ash_ai.ex:713-746` passes
`maybe_is: true, run_queries?: false, pre_flight?: false`, and short-circuits to
`true` for resources with no authorizers. It *does* fail closed on exceptions.
`tool.action` is mutated from atom to full action struct by
`attach_tool_runtime_details/2` (`:668-672`) — a bug source if read from
`AshAi.Info.tools/1` instead.

`inputSchema` is built by `AshAi.Tool.Schema.for_action/6`
(`deps/ash_ai/lib/ash_ai/tool/schema.ex:38-134`). **Action inputs nest under a
single top-level `input` property**, not spliced at root (`:112-134`), and the
builder does a deliberate `Jason.encode!() |> Jason.decode!()` atom→string
round-trip — project onto this shape identically or post-processing silently
no-ops. Reuse `AshAi.OpenApi.resource_write_attribute_type/3` for type mapping.

---

## Decisions taken (confirmed with user)

| Question | Decision |
|---|---|
| Test data layer | **ETS only.** `Ash.DataLayer.Ets` ships in `ash`; no Postgres, no docker. |
| §6 open items | **Resolved up front** against local deps (above). |
| Scope | **All five REQ §4 phases** planned in full. |
| MCP authorization | **Backbone computes, MCP renders.** Not a posture difference — both fail open now — but §5's rule that an adapter contains no affordance logic. The backbone also applies the state gate, which `exposed_tools` does not. |
| No-authorizer resources | **Warn, don't fail.** No policies = no restrictions is correct Ash semantics. |
| `list_changed` | **Build our own push channel** (see Phase 5 risk note). |
| MCP navigation | **`resources/list` + `mcp_resources`**; no URI templates. |
| R8 collection cost | **Type-level affordances only on collections**; never per-record. Removes M × N structurally. |
| R8 caching | **None in v1.** Per-record always; classification can't be exact, and the cacheable cases are already cheap. |
| R8 on/off config | **DSL section**, single `enabled?` toggle, domain-level default inherited. |

---

## Module tree

```
lib/ash_hateoas.ex                       # public entry: affordances/3,4
lib/ash_hateoas/affordance.ex            # %Affordance{} struct (R5)
lib/ash_hateoas/field.ex                 # %Field{} struct (R5)
lib/ash_hateoas/backbone.ex              # §3 pipeline: candidates → gates → descriptors
lib/ash_hateoas/candidates.ex            # route introspection → candidate action set
lib/ash_hateoas/descriptor.ex            # action + route → %Affordance{} with fields
lib/ash_hateoas/type_mapper.ex           # explicit Ash.Type → wire-type table (§4)
lib/ash_hateoas/gate.ex                  # @behaviour: filter(candidates, ctx) :: candidates
lib/ash_hateoas/gate/chain.ex            # ordered chain, short-circuits on empty
lib/ash_hateoas/gate/authorization.ex    # plain Ash.can?/3 + rescue/log
lib/ash_hateoas/gate/state_machine.ex    # optional; compiled only if ash_state_machine
lib/ash_hateoas/posture.ex               # R8 on/off resolution (single vs collection)
lib/ash_hateoas/navigation.ex            # R9 structural links, transport-agnostic

lib/ash_hateoas/resource.ex              # Spark extension (override-only section)
lib/ash_hateoas/resource/info.ex         # use Spark.InfoGenerator + hand-written arity-2
lib/ash_hateoas/resource/override.ex     # %Override{} entity target
lib/ash_hateoas/resource/exclusion.ex    # %Exclusion{} entity target
lib/ash_hateoas/resource/verifiers/verify_actions_exist.ex   # R2 + no-authorizer warning
lib/ash_hateoas/resource/transformers/setup.ex               # bails on embedded?

lib/ash_hateoas/json_api/renderer.ex     # %Affordance{} → JSON:API link object
lib/ash_hateoas/json_api/capture.ex      # before_dispatch: stash route/domain/resource
lib/ash_hateoas/json_api/transform.ex    # register_before_send: merge links by type+id
lib/ash_hateoas/json_api/index.ex        # JSON type string → Ash resource module

lib/ash_hateoas/mcp/tools.ex             # %Affordance{} → MCP tool + inputSchema
lib/ash_hateoas/mcp/router.ex            # wraps AshAi.Mcp.Router; owns capabilities
lib/ash_hateoas/mcp/notifier.ex          # list_changed push on transition
lib/ash_hateoas/mcp/navigation.ex        # R9 via resources/list + mcp_resources
```

Optional modules are wrapped in `if Code.ensure_loaded?(Mod)` — the idiom
`AshAi.Mcp.Router` itself uses (`router.ex:5`).

## Public API

```elixir
# Record-level — state gate applies (R9)
@spec affordances(record :: struct, actor :: term, opts :: keyword) ::
        %{atom => Affordance.t()}

# Collection-level — no record, so NO state gate; Ash.can?/3 still applies (R9)
@spec affordances(resource :: module, actor :: term, opts :: keyword) ::
        %{atom => Affordance.t()}
```

`opts`: `:domain` (required — routes are domain-level), `:tenant`, `:gates`
(override the chain), `:cache` (per-request cache pid/ref).

## Structs (R5 — fixed shape, breaking to change)

```elixir
defmodule AshHateoas.Affordance do
  defstruct [:name, :href, :method, :description, :fields, :multi_step]
end

defmodule AshHateoas.Field do
  defstruct [:name, :type, :required, :description, :default, :constraints]
end
```

`default` is **omitted entirely** when the argument is `sensitive?` (R4) — the
field still appears so clients know to supply it. Only `public?` arguments become
fields. `constraints.enum` derives from `one_of`.

## DSL (R2 — override-only)

```elixir
hateoas do
  enabled? true                    # R8 posture; domain-level default inherited
  exclude :internal_reconcile
  override :approve, href: "/documents/:id/approve"
end
```

Two entities (`%Exclusion{}`, `%Override{}`), each needing `__identifier__` and
`__spark_metadata__` in its defstruct. Verifier rejects any `exclude`/`override`
naming a nonexistent action — this also protects the backbone, since
`Ash.can?/3` **raises `ArgumentError`** on an unknown action rather than
returning false (`can.ex:258`).

---

## Build phases

### Phase 0 — repo hygiene (do first, ~5 min)

The setup left the repo in a state that must not be built on:

1. **`git init`** — the repo is not under version control at all.
2. **`.gitignore`** — `/_build/`, `/deps/`, `*.dump`, `erl_crash.dump`,
   `/doc/`, `/cover/`, `*.ez`, `.elixir_ls/`.
3. **Delete `erl_crash.dump`** (453KB, from the loader crash during dep setup —
   it is a artifact of the macOS permissions problem, not of the project).
4. **`mix.exs` — small correction only.** I earlier claimed `optional: true` was
   wrong for our own deps. **That was incorrect.** `optional: true` still
   fetches and compiles the dep in the *defining* project; it only tells Hex not
   to force it on consumers. Proof both ways: our `deps/` contains
   `ash_json_api`, `ash_ai` and `ash_state_machine` despite all three being
   marked optional, and `ash_json_api` itself marks `open_api_spex` optional
   while testing against it (`deps/ash_json_api/mix.exs:157`). No duplicate keys
   and no `Mix.env()` conditional are needed.

   The one real change: **`plug` should not be optional.** Every rendering path
   we ship is a Plug — the JSON:API transform and the MCP router both require
   it, and `ash_json_api` itself declares `{:plug, "~> 1.11"}` unconditionally
   (`mix.exs:151`). Making it optional would let a consumer install a package
   whose entire delivery mechanism cannot load.

   ```elixir
   {:ash, "~> 3.29.3"},
   {:spark, "~> 2.6"},
   {:jason, "~> 1.4"},
   {:plug, "~> 1.16"},                                # required, not optional
   {:ash_json_api, "~> 1.7.1", optional: true},       # fetched here; optional for consumers
   {:ash_ai, "~> 0.7.2", optional: true},
   {:ash_state_machine, "~> 0.2", optional: true},
   {:ex_doc, "~> 0.34", only: [:dev], runtime: false}
   ```

   Add hex publishing metadata (`package/0`, `description`, `licenses`,
   `links`) at the same time. Verify with `mix deps.get && mix compile`.
5. **Initial commit** — `REQ.md`, `mix.exs`, `mix.lock`, `.gitignore`, and this
   plan as `PLAN.md`.

*Deliverable:* clean `git status`, `mix compile` succeeds, no stray artifacts.

### Phase 1 — backbone + tests

Core pipeline, transport-agnostic. Candidate set from
`AshJsonApi.Resource.Info.routes(resource, domains)` (**must pass domains**),
falling back to `Ash.Resource.Info.actions/1` where ash_json_api is absent
(§5.3). Authorization gate via plain `Ash.can?/3` with a logging rescue.
Descriptors via `action_inputs/2` + `TypeMapper`. **Also amend R6 in `REQ.md`**
to the advisory/fail-open posture (above).

*Deliverable:* `AshHateoas.affordances/3` returns a correct set for a test
resource. Tests assert: denied actions absent; undecidable → **present**
(fail-open, matching Ash's default — pin this explicitly so the posture is a
tested decision rather than an accident); a raising check is logged **and**
absent; sensitive defaults omitted; private arguments absent; unknown action in
DSL → compile error.

### Phase 2 — JSON:API rendering (R3 is v1 done, not follow-up)

`before_dispatch` capture + `register_before_send` merge, per verified findings.
Handles single, collection and `included`; skips documents with no `data` key
(generic actions); no-op for resources without the extension.

Also in this phase, since ash_json_api supports neither: set the `profile=`
content-type parameter in the same callback, and **write the profile document**
(`documentation/profiles/affordances.md`) defining `links.<action>`,
`meta.method` and `meta.fields`.

*Deliverable:* live endpoint returns `links.<action>` objects with
`href`/`rel`/`title`/`meta.fields`, and a `Content-Type` advertising the
profile. Tests assert merge correctness against a real serialized document,
that the content-type carries the profile parameter, and — critically — that a
**collection response carries type-level affordances in its top-level `links`
and none on individual records**, with the `can?` call count independent of
page size.

### Phase 3 — Spark extension, transformer, verifier

Extension, override-only section, generated Info, transformer that **bails on
embedded resources** via `Transformer.get_persisted(dsl_state, :embedded?, false)`,
`add_new_*` builders, explicit `after?/before?` with catch-alls.

*Deliverable:* adding `extensions: [AshHateoas.Resource]` is the only per-resource
config. Tests assert exclude/override applied, verifier rejects bad names, warns
on zero authorizers, embedded resources untouched.

### Phase 4 — state gate + R8 posture

State gate as a chain entry, compiled only when `ash_state_machine` is loaded,
following `possible_next_states/1` semantics with `List.wrap` and `:*` handling.

`Posture` resolves the single `enabled?` toggle (resource, falling back to
domain default). The `before_dispatch` capture supplies `route.type` (`:get` vs
`:index`), which selects **which backbone entry point runs** — record-level with
the state gate, or type-level without it.

**No caching** — every `can?` is per record (decision above).

*Deliverable:* both renderings gain both features at once. Tests assert a
transition is hidden from an illegal state and shown from a legal one; that a
`:*` wildcard transition is handled in both `from` and action position; and that
`enabled? false` on a resource or domain suppresses affordances entirely.

### Phase 5 — MCP adapter *(highest risk)*

Tools from the backbone's affordance set; `inputSchema` projected onto ash_ai's
nested-`input` shape with the atom→string round-trip. Navigation via
`resources/list` + `mcp_resources`.

**Our own router wrapping `AshAi.Mcp.Router`**, owning the capability
declaration (`listChanged: true`) and notification emission, delegating
everything else. *Risk:* ash_ai's session/transport handling is `defp`, so this
is the one place REQ's "public surface only" (§4) and R3's push loop conflict.
Last in build order deliberately — phases 1–4 ship regardless.

*Deliverable:* `tools/list` returns the state-gated set; a transition fires
`list_changed`; the next `tools/list` differs.

---

## Test support

`test/support/` — one ETS-backed domain with: a resource with policies
(attribute-check *and* relationship/expression checks, to exercise both
`PolicyClass` branches), a resource with an `AshStateMachine`, a resource with
**no** authorizers (warning path), an embedded resource (transformer bail-out),
and JSON:API routes covering `:get`, `:index`, `:post`, `:patch` and a generic
`:route`.

## Verification

```sh
cd /Users/jan/Documents/fun/ash-hateoas
mix test                    # all phases
mix test --only integration # live endpoint (phase 2), MCP loop (phase 5)
```

End-to-end is done **in-process with `Plug.Test`** — no HTTP server needed, and
none is currently a dependency (no `plug_cowboy`/`bandit`/`cowboy` in `deps/`;
`plug` pulls in none of them). `Plug.Test.conn/3`
(`deps/plug/lib/plug/test.ex:69`) builds a conn, which is sent straight through
`AshJsonApi.Router` — our transform is a Plug, so a real socket adds nothing:

```elixir
conn = Plug.Test.conn(:get, "/documents/#{id}")
       |> Ash.PlugHelpers.set_actor(alice)
       |> TestRouter.call(TestRouter.init([]))

%{"links" => links} = Jason.decode!(conn.resp_body)["data"]
```

Assert: the same URL as two different actors yields different `links`; a
collection URL is affordance-free unless opted in; the `Content-Type` carries
the profile parameter.

Only add `{:plug_cowboy, …, only: :test}` if a genuine over-the-wire check is
wanted later — nothing in the plan requires it.

## Open risks

1. **MCP push channel** (phase 5) — needs private-ish ash_ai surface. Wrapping
   the router is the mitigation; scope-cut to no-push if it proves unstable.
2. **~~Collection cost~~ — resolved.** Collections compute type-level
   affordances only, so cost is N regardless of page size and the M × N case
   cannot arise. This is why caching was safe to drop: the expensive scenario it
   existed to mitigate no longer exists.
3. **`ash_commanded` precedent unverified** — not a dependency, and adding one
   for a publishable package would be wrong. Gate chain designed on its own
   merits (§3's three stated requirements). Clone read-only to the scratchpad if
   confirmation is wanted.
4. **Repo hygiene and `mix.exs`** — moved to **Phase 0** above; no longer open.
