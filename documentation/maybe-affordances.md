# Maybe-affordances — and the upstream Ash change they need

## The distinction that matters

When `ash_hateoas` decides whether to advertise an action, `false` is
overloaded. Two very different situations produce it:

1. **Genuinely forbidden** — the decision is `false` from facts already known at
   probe time: the actor's attributes (`actor.role != :admin`), the record
   (`owner_id != actor.id`), a constant (`forbid_if always()`). No argument the
   caller could pass would change it. → the action should be **hidden**.

2. **Argument-based** — the *only* reason it is `false` is that a policy
   references an action argument that was not supplied. `authorize_if
   expr(^arg(:tier) == "public")` with `tier` absent is not "you may not do
   this"; it is "you may, for the right `tier`". A future call *could* satisfy
   it. → the action should be shown as a **maybe-affordance**: advertised, but
   flagged as conditional, so an MCP agent discovers it, tries it, and the
   endpoint gives a definitive answer (R6 — affordances are advisory; the
   endpoint re-runs every policy).

Today these are indistinguishable, so `ash_hateoas` must either hide both
(losing discoverability of conditional actions) or show both (advertising
genuinely-forbidden actions). Neither is right.

## Why it cannot be fixed soundly in `ash_hateoas` alone

Measured, three ways, all unsound:

- **Guessing argument values** and re-probing: fails for any policy needing a
  value not in the guess set — `^arg(:code) == "xyzzy-9000"` is wrongly hidden.
- **`Ash.can/4` with `maybe_is: :maybe`**: still returns a definite `false` for
  `^arg(:tier) == nil`, not `:maybe`. The `:maybe` path is for record/filter
  undecidability, not a missing argument.
- **Walking `%Ash.Policy.Policy{}` conditions** for `arg(:_)` references: works,
  but couples `ash_hateoas` to Ash's private policy representation and breaks
  across Ash versions.

The information needed — "was this `false` caused by an *absent argument*?" — is
erased before `ash_hateoas` can see it.

## Where Ash erases it

`Ash.Expr.fill_template/…` resolving a `{:_arg, field}` template
(`deps/ash/lib/ash/expr/expr.ex`, ~line 236):

```elixir
{:_arg, field} ->
  args = opts[:args]

  case Map.fetch(args, field) do
    :error -> Map.get(args, to_string(field))   # absent -> nil
    {:ok, value} -> value
  end
```

An **absent** argument becomes `nil`, indistinguishable from an argument
explicitly set to `nil`. So `^arg(:tier) == "public"` evaluates `nil ==
"public"` → a definite `false`, and the policy strict-check reports `false`
rather than the `:unknown` it reports for genuinely undecidable checks.

Ash's policy engine **already has** the three-state machinery
(`:authorized` / `:forbidden` / `:unknown` → surfaced as `:maybe`). The gap is
only that a missing argument does not enter the `:unknown` branch.

## Proposed upstream change

Distinguish absent from nil during **policy strict-checks**, and propagate
`:unknown` for the absent case:

1. In template resolution, thread an "argument absent" signal (a sentinel, or a
   distinct clause) instead of collapsing an absent `{:_arg}` to `nil` — scoped
   to strict-check evaluation so runtime action behaviour is unchanged.
2. A filter/expression check that cannot decide because a referenced argument is
   absent returns `:unknown`, exactly as an undecidable record check does.
3. `Ash.can/4` then returns `{:ok, :maybe}` for such an action under an
   argument-less subject — while a known-fact denial stays `{:ok, false}`.

Blast radius: the change must NOT alter runtime action evaluation, where an
absent optional argument legitimately resolves to its default/`nil`. It applies
to the strict-check-without-arguments path the authorization probe uses. This is
the care point for the PR.

## What `ash_hateoas` does once Ash can say `:maybe`

`AshHateoas.Affordance` already carries advisory flags (`not_delegable?`,
`multi_step?`), so a `maybe?` field renders in the same shape across transports.
`AshHateoas.Gate.Authorization` then maps the probe result directly, with no
value-guessing and no policy-internals coupling:

| `Ash.can` result (argument-less probe) | affordance |
|---|---|
| `true` | advertised |
| `:maybe` (decision depends on an absent argument) | advertised, `maybe?: true` |
| `false` (denied by known facts) | hidden |

The crash-recovery already shipped (a preparation raising on the argument-less
probe is retried without preparations) is orthogonal and stays — it is about the
query being *malformed*, this is about the decision being *conditional*.
