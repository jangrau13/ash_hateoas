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
transition from what the server embeds in the response, and never constructs a
URL or relies on out-of-band knowledge of your operations.

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
| `not_delegable` | **yes**, flagged `ah:notDelegable` | only a committing credential |

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

- **Expecting relationship links on a resource that declares none.** Public
  to-many relationships derive `related`/`relationship` routes automatically;
  a private relationship is left off the surface. To-one relationships are
  skipped — served better as an inline node reference than as a collection route.
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
- **Reading `ah:notDelegable` as "you will be refused".** The flag is a declared
  property of the *action*, identical for every actor — a person sees it too. It
  says the action needs a committing credential, not that the reader lacks one.
- **Expecting `not_delegable` to enforce anything with no commit authority
  configured.** The default commits for everyone, so the flag is advertised and
  nothing is refused. The verifier warns at compile time.
