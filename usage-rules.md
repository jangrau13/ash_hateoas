# Rules for working with AshHateoas

## Understanding AshHateoas

AshHateoas computes **affordances** — the set of actions an actor may take on a
record (or on a resource type) right now — and serves them as a **Hydra /
JSON-LD** API: each affordance becomes a `hydra:Operation` on the resource node,
served as `application/ld+json` by `AshHateoas.Hydra.Plug`.

The point is that affordances are **derived, never authored**. A resource
already declares its actions, its policies and (where present) its state
machine. AshHateoas reads those and answers "what may be done next?" per
request, from the requesting client's own actor and position.

The **routes are derived too**: every action is routed unless declared
`unrouted`, and the `base` comes from the domain's short name plus the `type`
(which is itself inferred from the module name when undeclared). A resource
needs no `routes` block at all. Note what that means when adding the extension
to an existing resource — it widens that resource's HTTP surface to every action
it declares, so audit the action list first.

Richardson Level 3 in one sentence: the client discovers every available state
transition from the links and operations the response carries, and never
constructs a URL or relies on out-of-band knowledge of your operations.

## Setup

Add the extension to the resource. There is nothing else to configure per
resource.

```elixir
defmodule MyApp.Document do
  use Ash.Resource,
    domain: MyApp.Docs,
    extensions: [AshHateoas.Resource]
end
```

Then mount the Hydra plug to serve the domain as `application/ld+json`:

```elixir
defmodule MyApp.HydraRouter do
  use Plug.Builder
  plug AshHateoas.Hydra.Plug, domains: [MyApp.Docs], prefix: "/api", doc_path: "/doc"
end
```

Every routed action the actor is authorized to invoke — and that is legal from
the record's current state — is advertised automatically.

## Reading affordances directly

```elixir
# Record-level: "what can I do with this?" The state gate applies.
AshHateoas.affordances(document, actor)
#=> %{approve: %AshHateoas.Affordance{method: :patch, href: "/documents/:id/approve", ...}}

# Type-level: "what can I do with this type?" No record, so no state gate.
# This is the cold-start case — a client that has just entered the system.
AshHateoas.affordances(MyApp.Document, actor, domain: MyApp.Docs)
#=> %{create: %AshHateoas.Affordance{method: :post, ...}}
```

### Options

- `:domain` — required only when the resource does not declare one. **Routes are
  declared at domain level**, so the domain must be resolvable.
- `:domains` — additional domains to read routes from. Defaults to `[domain]`.
- `:tenant` — forwarded to `Ash.can?/3`.
- `:exclude` — action names to drop.
- `:overrides` — `%{action_name => [href: "/custom/path"]}`.
- `:gates` — replace the gate chain (see below).

## The DSL is override-only

There are **no per-action "enable" entries**. Saying nothing yields the full
surface; the block subtracts from it or corrects it.

```elixir
hateoas do
  enabled? true
  exclude :internal_reconcile
  override :approve, href: "/documents/:id/approve"
  unrouted :sync_from_stripe
  method :tally, :get
end
```

| entry | effect |
|---|---|
| `exclude` | routed and callable, but not advertised |
| `override` | replaces the derived `href` |
| `unrouted` | no route at all — not reachable over HTTP |
| `method` | the verb for a generic action, whose type declares none |

`unrouted` is the one to reach for when an action must not be public. Since
every action is routed by default, this is how you say otherwise — and a
compile-time verifier rejects any entry naming an action that does not exist,
so a renamed action fails the build rather than silently becoming routed again.

Two kinds of action are skipped without any declaration, because the fact is
already in the code: **Reactor compensations** (Ash requires a single
`changeset` argument, which no HTTP caller can construct) and **everything
AshAuthentication generates** (served by its own router; the subject resolver is
guarded by a bypass that only matches in-process calls).

## Authorization

**Never reimplement a policy to decide what to advertise.** AshHateoas calls
`Ash.can?/3` — the same function the endpoint calls on invocation. That single
source of truth is what stops affordances and endpoints from diverging.

Two consequences worth internalising:

- **Record-dependent policies are resolved, not guessed.** Passing the record as
  the subject lets Ash evaluate `expr(owner_id == ^actor(:id))` against real
  data. The owner is offered the action; a stranger is not.
- **A resource with no authorizers advertises everything.** `Ash.can?/3`
  short-circuits to `true` before evaluating anything when
  `Ash.Resource.Info.authorizers/1` is empty. That is correct Ash semantics — no
  policies means no restrictions — but on a hypermedia surface it means a
  forgotten `policies` block exposes `destroy` to anonymous clients. The
  verifier warns at compile time; add policies or opt out deliberately.

Affordances are **advisory**. The endpoint re-runs every policy, validation and
state check on invocation, so a stale or optimistic proposal degrades to a clean
error, never an invalid write.

## Actions a delegated credential may not execute

An actor may be *authorized* to run an action and still be the wrong party to run
it **alone** — an agent holding a key derived from a person's authority, a
service account, a sandbox session. `Ash.can?/3` is a boolean and cannot say
this, so it is declared:

```elixir
agentic_hateoas do
  not_delegable :publish
end
```

Then name, once for the whole application, which credentials commit:

```elixir
config :ash_hateoas, commit_authority: AshHateoas.CommitAuthority.ApiKey
```

`ApiKey` answers **false** for any actor carrying
`__metadata__[:using_api_key?]` — the field `ash_authentication`'s api_key
strategy already stamps. Unconfigured, every credential commits and the
declaration is documentation only, so adding this to a live deployment changes
nothing until you opt in.

**The action stays advertised.** This is the whole point, and it is the opposite
of `exclude` and `unrouted`:

| | in the affordance set | executes |
|---|---|---|
| `unrouted` | no — no route at all | — |
| `exclude` | no — routed but unadvertised | yes |
| `not_delegable` | **yes**, flagged `odrl:duty` / `odrl:obtainConsent` | only a committing credential |

Withholding it would leave the caller unable to tell "this does not exist" from
"you may propose this but not perform it", and so unable to ask anyone for it.

A non-committing credential invoking it gets **403**, a `hydra:Error` carrying
under `ah:projection` what the action would have done — for a state machine,
which state it would move to and which affordances that gains and loses. Nothing
is executed to produce that: it is read from the transitions and the gate chain,
so no change module runs and no side effect fires.

Three things to know before declaring it:

- **It means "holds a delegated credential", not "is an agent".** A person
  scripting with their own API key is refused too. Write your own
  `AshHateoas.CommitAuthority` if you need a narrower rule.
- **Enforcement is inside Ash, not in the transport.** A consumer calling
  `Ash.update/2` directly is refused identically to one going through the Hydra
  plug.
  If you write your own change on such an action, build it on
  `AshHateoas.Resource.Changes.InvocationChange` — it implements `change/3` so
  that `Ash.can?/3`'s pre-flight changesets never reach your code. A change that
  rejects one refuses a *hypothetical*, which drops the affordance from the set;
  a change that computes from the backbone re-enters `Ash.can?/3` and loops,
  hanging rather than crashing.
- **The action can no longer run atomically.** An atomic update never calls
  `change/3`, so the refusal would be skipped; the installed change declines
  atomicity rather than let that happen.

## Links

Resources are connected by **links**, never by one resource's representation
sitting inside another's. You write ordinary Ash relationships; every public one
becomes a `hydra:Link` property on the node, and the whole link surface —
routes, `@context` terms, ontology declarations, write handling — derives from
them. There is no link DSL to learn.

A link takes one of two forms, and both state the same thing:

```json
"author":   {"@id": "/people/7"}                                  // node reference
"comments": {"@id": "/articles/3/comments", "@type": "Collection",
              "hydra:member": [{"@id": "/comments/1"}], "hydra:totalItems": 1}
```

```json
"author": {"@id": "/people/7", "@type": "Person", "name": "Ada"}   // expanded node
```

A **node reference** is the identity alone. An **expanded node** is the same
link with the target's own properties stated alongside it, still carrying its
`@id`. In RDF both are the same graph — expansion adds facts, it never changes
what the property points at.

**Which one you get is decided by what the action loads.** Nothing else:

```elixir
read :with_author do
  prepare build(load: [:author])   # `author` now arrives expanded
end
```

An unloaded to-one is referenced from its foreign key without reading the
target, so it costs nothing; a loaded one is rendered in place, recursively,
with cycles degrading to a plain reference. The target's own terms travel with
it as a scoped `@context`, so a record expands to the same triples however it
was reached.

### A to-many is a collection

A to-many link is a `hydra:Collection` — **not a bare array**. `hydra:member` is
a real predicate: with it, the property points at *one collection* which *has* N
members. Without it the property points at N unrelated things and the
collection, the subject `hydra:totalItems` and any paging describe, does not
exist at all.

Its `@id` is the relationship's own route (`/articles/7/comments`), which
resolves to exactly this collection, so it has a real identity a triple can
name.

**What varies is whether the members are expanded, not whether they are there.**

```json
// unloaded — members as references, plus the true total and a page view
"comments": {"@id": "/articles/7/comments", "@type": "Collection",
             "hydra:totalItems": 214,
             "hydra:member": [{"@id": "/comments/1"}, {"@id": "/comments/2"}],
             "hydra:view": {"@type": "PartialCollectionView",
                            "hydra:next": "/articles/7/comments?offset=10"}}
```

```json
// loaded — the same collection, members stated in place
"comments": {"@id": "/articles/7/comments", "@type": "Collection",
             "hydra:totalItems": 214,
             "hydra:member": [{"@id": "/comments/1", "body": "…", "author": {…}}]}
```

That is the same rule a to-one follows: a reference by default, the node itself
when the action loads it. A client always learns *which* records are related and
can follow any of them; loading decides only whether it also gets their data.

The reference list is bounded (10) so the cost does not multiply across a
collection page, and `hydra:totalItems` says how much is being left out —
truncation is stated, never silent. `hydra:view` gives the client somewhere to
go for the rest.

### Asking for the members in place

Two ways, and they produce the same document:

```elixir
read :with_comments do
  prepare build(load: [:comments])   # the server decides
end
```

```
GET /articles/7?load=comments        # the client asks
```

The `?load` parameter is advertised as a `hydra:IriTemplate` on the node, so a
client discovers it rather than knowing it out of band. It accepts any public
to-many the class declares; an unknown or private name is **ignored**, never
refused — the parameter narrows a response and must never widen what may be
read.

### A recursive to-many travels flat

A self-referencing to-many — a tree — is emitted as **one flat collection**,
every node naming its `parent` and an ordering attribute, rather than nested
collections inside members inside collections:

```json
"value": {"@type": "Collection", "hydra:totalItems": 3,
  "hydra:member": [
    {"@id": "/value/1", "operator": "*", "position": 0},
    {"@id": "/value/2", "position": 0, "parent": {"@id": "/value/1"}},
    {"@id": "/value/3", "position": 1, "parent": {"@id": "/value/1"}}]}
```

The structure is recoverable from the edges: group by `parent`, sort by
position. Recursion on the wire forces a depth cap, and a depth cap **truncates
silently** — the flat form has no depth to cap, and `hydra:totalItems` makes
completeness checkable rather than assumed. The payload is linear in the node
count rather than multiplicative.

### Writing links

A client names the target; it never sends a foreign key. Two ways, both
advertised in the ApiDocumentation (`sh:nodeKind: sh:IRI` on the link property):

```json
{"author": {"@id": "/people/7"}}          // by node reference — what a read emits
{"author": {"name": "Ada"}}               // by declared identity
{"author": null}                          // clears an optional link
```

The identity form works for any resource with an `identity` — published as
`ah:identity` on its class, so a client reads the key from the contract rather
than guessing which property names a record. An identity object whose keys are
not a declared identity is refused rather than matched approximately.

Rules the write path enforces:

- **A required link cannot be cleared.** `null` on a `belongs_to` whose foreign
  key is `allow_nil?: false` is a 422 — the same fact `hydra:required`
  advertises on the property.
- **A reference must resolve to the right class.** An IRI naming some other
  resource is a 422, not a silently-ignored key.
- **A reference must exist.** A dangling target is refused. The check runs as
  the actor, so a target they may not see answers exactly as a missing one
  does — a write never reports whether a hidden record exists.
- **Only this API's URLs.** An absolute IRI under another origin is refused: it
  names a resource in some other API, which no local relationship can hold.
  Cross-API links are `AshHateoas.Type.ResourceLink` attributes, where the
  open-world assumption applies and a target may legitimately vanish.

## Field descriptors

Fields derive from an action's **public** arguments, carrying `description`,
`default` and `constraints` straight from the DSL.

Two rules that are easy to get wrong:

- **Private arguments never appear.** `public?: false` means the client never
  learns the argument exists.
- **A sensitive argument's default is never emitted.** The field still appears —
  the client must know to supply it — but `default` is `:error`. Note the
  `{:ok, value} | :error` shape: `nil` is itself a legitimate default, so a
  bare `nil` could not distinguish "no default" from "defaults to nil".

```elixir
argument :signing_key, :string do
  public? true
  sensitive? true
  default "sk-do-not-leak"   # never reaches the wire
end
```

## Custom gates

The pipeline is an ordered chain of filters, not hardcoded branches. Add your
own — a tenancy rule, a feature flag — without forking:

```elixir
defmodule MyApp.FeatureFlagGate do
  @behaviour AshHateoas.Gate

  @impl true
  def filter(candidates, %AshHateoas.Gate.Context{} = ctx) do
    Enum.reject(candidates, &MyApp.Flags.hidden?(&1.name, ctx.actor))
  end
end
```

Rules for a gate:

- It MUST return a subset of what it was given. Never add candidates.
- It MUST NOT raise for an expected outcome — filtering *is* the mechanism for
  "not available".
- `ctx.record` is `nil` for collection-level affordances. A gate that reasons about
  record state must treat `nil` as "not applicable" and pass candidates through.

The chain short-circuits as soon as the set empties, so order gates
cheapest-first.

## Cost

The whole cost is `Ash.can?/3`; every other stage is in-memory DSL reading.
Attribute checks are negligible; relationship and expression checks
(`relates_to_actor_via`, `exists(…)`) can each emit a query.

**Collections never compute per-record affordances.** A `hydra:Collection`
carries collection-level operations (`create`, index reads) at the top level;
the member nodes inside carry no operations. Cost is therefore independent of
page size — there is no `M × N` case and no flag to remember.

There is no cross-record caching. Caching per `(actor, action)` is only sound
when a policy's outcome is record-independent, and Ash exposes no way to
determine that — a wrong guess returns a wrong authorization answer.

## Common mistakes

- **Expecting relationship links on a resource that declares none.** Every
  public relationship becomes a link on the node; a private one is left off the
  surface. A to-many derives a `related` route (`/articles/:id/comments`) — the
  identity its inline collection carries and the URL `hydra:view` pages against.
  A to-one derives none: it is referenced from the local foreign key. **No route
  nests a member under another record**, so `/articles/7/comments/3` does not
  exist — a record that already has an address never gets a second.
- **Expecting affordances on a resource with no routes.** A resource with no
  routes falls back to its actions directly and affordances have no `href`. That
  is intended — the backbone is usable before route derivation has run.
- **Reading `:domain` as an `Ash.can?/3` option.** It is consumed before option
  validation by `can?/3`, but `Ash.can/3` rejects it outright. Do not thread it
  through.
- **Treating a read policy as a yes/no question.** Read policies produce
  *filters*: `expr(owner_id == ^actor(:id))` lets the query run for everyone and
  simply returns fewer rows. Pass `data: record` so the question becomes "may
  you read THIS record?" rather than "may you run this query?".
- **Assuming affordances are a security boundary.** They are a *hint*. Security
  is the policy the endpoint enforces on invocation.
- **Reaching for `not_delegable` to hide an action.** It does the opposite: the
  action stays routed and stays advertised, and only its execution is gated. Use
  `unrouted` to keep it off the surface, or a policy to make it unauthorized.
- **Reading the ODRL Duty as "you will be refused".** The duty is a declared
  property of the *action*, identical for every actor — a person sees it too. It
  says the action needs a committing credential, not that the reader lacks one.
- **Expecting `not_delegable` to enforce anything with no commit authority
  configured.** The default commits for everyone, so the flag is advertised and
  nothing is refused. The verifier warns at compile time.
