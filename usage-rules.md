# Rules for working with AshHateoas

## Understanding AshHateoas

AshHateoas computes **affordances** — the set of actions an actor may take on a
record (or on a resource type) right now — and renders that one result into each
transport's own idiom: JSON:API `links` today, described by a published profile
so that other transports can be built against the documents rather than against
this package.

The point is that affordances are **derived, never authored**. A resource
already declares its actions, its routes, its policies and (where present) its
state machine. AshHateoas reads those and answers "what may be done next?"
per request, from the requesting client's own actor and position.

Richardson Level 3 in one sentence: the client discovers every available state
transition from what the server embeds in the response, and never constructs a
URL or relies on out-of-band knowledge of your operations.

## Setup

Add the extension alongside your transport extension(s). There is nothing else
to configure per resource.

```elixir
defmodule MyApp.Document do
  use Ash.Resource,
    domain: MyApp.Docs,
    extensions: [AshJsonApi.Resource, AshHateoas.Resource]
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

There are **no per-action "enable" entries**. Everything routed is advertised;
the block carries deviations only.

```elixir
hateoas do
  enabled? true
  exclude :internal_reconcile
  override :approve, href: "/documents/:id/approve"
end
```

A compile-time verifier rejects an `exclude` or `override` naming an action that
does not exist — so a renamed action fails the build rather than silently
dropping an affordance.

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

**Collections never compute per-record affordances.** A collection response
carries collection-level affordances (`create`, index reads) in its top-level `links`;
the records inside carry navigation but no affordances. Cost is therefore
independent of page size — there is no `M × N` case and no flag to remember.

There is no cross-record caching. Caching per `(actor, action)` is only sound
when a policy's outcome is record-independent, and Ash exposes no way to
determine that — a wrong guess returns a wrong authorization answer.

## Common mistakes

- **Calling `AshJsonApi.Resource.Info.routes/1` without domains.** Routes are
  declared at *both* domain and resource level; the arity-1 form returns only
  resource-level routes, so the candidate set comes back half-empty. Always pass
  domains.
- **Expecting affordances on a resource with no routes.** Without
  `ash_json_api`, the candidate set falls back to the resource's actions and
  affordances have no `href`. That is intended — the backbone is usable without
  any transport installed.
- **Reading `:domain` as an `Ash.can?/3` option.** It is consumed before option
  validation by `can?/3`, but `Ash.can/3` rejects it outright. Do not thread it
  through.
- **Treating a read policy as a yes/no question.** Read policies produce
  *filters*: `expr(owner_id == ^actor(:id))` lets the query run for everyone and
  simply returns fewer rows. Pass `data: record` so the question becomes "may
  you read THIS record?" rather than "may you run this query?".
- **Assuming affordances are a security boundary.** They are a *hint*. Security
  is the policy the endpoint enforces on invocation.
