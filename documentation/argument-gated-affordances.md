# Argument-gated affordances — and the upstream Ash change they need

## The distinction that matters

When `ash_hateoas` decides whether to advertise an action, `false` is
overloaded. Two very different situations produce it:

1. **Genuinely forbidden** — the decision is `false` from facts already known at
   probe time: the actor's attributes (`actor.role != :admin`), the record
   (`owner_id != actor.id`), a constant (`forbid_if always()`). No argument the
   caller could pass would change it. → the action should be **hidden**.

2. **Argument-gated** — the *only* reason it is `false` is that a policy
   references an action argument that was not supplied. `authorize_if
   expr(^arg(:tier) == "public")` with `tier` absent is not "you may not do
   this"; it is "you may, for the right `tier`". → the action should be
   advertised as an **ordinary affordance**.

The second point is the whole design, and it needs stating precisely because an
earlier framing ("maybe-affordance") got it wrong. An argument-gated action is
**not** a special third kind of affordance. A client cannot act on a "maybe" any
differently than on a normal affordance — in both cases it supplies the fields
and makes the call, and the endpoint gives the real answer. The affordance model
is *already* advisory: every affordance is a proposal the endpoint
re-checks, and the affordance's `fields` already tell the agent it must supply
`tier`. So the correct output is an ordinary affordance — nothing flagged,
no new state. What was wrong was only that the action was **hidden** instead of
advertised.

So the requirement is single: **a missing argument must not drive the
authorization decision to a definite `false`.** Genuine denials (known facts)
stay `false` and hidden; an argument-gated decision becomes undecided, which Ash
resolves optimistically per R6, so the action is advertised like any other.

## Why it cannot be fixed in `ash_hateoas` alone

Measured, three ways, all unsound:

- **Guessing argument values** and re-probing: fails for any policy needing a
  value not in the guess set — `^arg(:code) == "xyzzy-9000"` is wrongly hidden.
- **`Ash.can/4` with `maybe_is`**: without the patch below, returns a definite
  `false` for `^arg(:tier) == nil`, not an undecided state.
- **Walking `%Ash.Policy.Policy{}` conditions** for `arg(:_)` references: works,
  but couples `ash_hateoas` to Ash's private policy representation and breaks
  across Ash versions.

The information needed — "was this `false` caused by an *absent argument*?" — is
erased inside Ash before `ash_hateoas` can see it.

## Where Ash erases it

`Ash.Expr.fill_template/…` resolving a `{:_arg, field}` template
(`deps/ash/lib/ash/expr/expr.ex`, ~line 236) turns an **absent** argument into
`nil`, indistinguishable from an argument explicitly set to `nil`. So `^arg(:tier)
== "public"` evaluates `nil == "public"` → a definite `false`, and the policy
strict-check reports `false` rather than the `:unknown` it reports for a
genuinely undecidable check.

Ash's policy engine **already has** the three-state machinery
(`:authorized` / `:forbidden` / `:unknown`). The gap is only that a missing
argument does not enter the `:unknown` branch.

## The prototype patch (proven locally)

In `Ash.Policy.FilterCheck`'s strict-check, **before** filling the template,
detect whether the check's filter references an argument absent from the
supplied `args`, and if so return `{:ok, :unknown}` instead of evaluating it to
`false`:

```elixir
# in try_strict_check/3, before fill_template:
if Ash.Policy.FilterCheck.references_absent_argument?(filter, args) do
  {:ok, :unknown}
else
  # ...existing fill_template + eval...
end

# new module helper, reusing the existing public traversal:
def references_absent_argument?(filter, args) do
  Ash.Expr.template_references?(filter, fn
    {:_arg, name} -> not (Map.has_key?(args, name) or Map.has_key?(args, to_string(name)))
    _ -> false
  end)
end
```

Verified end to end against the patched Ash (each action governed by exactly one
policy, so nothing masks the result):

| action | policy | argument-less probe | outcome |
|---|---|---|---|
| `:tiered` | `authorize_if expr(^arg(:tier) == "public")` | undecided → optimistic | **advertised** |
| `:never`  | `forbid_if always()` | definite `false` | **hidden** |
| `:open`   | `authorize_if always()` | `true` | **advertised** |

And the patch does NOT leak into normal execution: a real call supplying the
argument still decides correctly (`tier: "public"` → allowed, `tier: "secret"` →
denied), because the guard only fires when the argument is absent.

## Scope note for the PR

The change must apply only to the strict-check-without-arguments path the
authorization probe uses. It must NOT alter runtime action evaluation, where an
absent optional argument legitimately resolves to its default/`nil`. That is the
care point, and the guard above fires only when an argument is genuinely absent
(an argument present but set to `nil` counts as present).

## How the change reaches Ash — delivery

This is a change to Ash's own policy engine, so it lives in `ash-project/ash`,
not here. Concretely:

- **Upstream PR (the real home).** Merged and released, every consumer gets it
  via a normal `mix deps.update ash`. No wiring in consuming apps.
- **Not Igniter.** Igniter patches a *consuming project's* source (adds
  resources, installs deps, edits configs) via AST transforms. It does not patch
  dependency source under `deps/`, so it is not the tool for changing Ash's
  internals — it patches the users of Ash, not Ash.
- **Bridge while the PR is pending: a git fork with `override: true`.** This is
  what the `svc_lca` uses today. A fork carrying the single patch on
  a branch based off the pinned Ash tag exists at
  `github.com/jangrau13/ash` (branch `arg-gated-strict-check`, off `v3.29.3`).

  In the consuming app's `mix.exs`:
  ```elixir
  {:ash, github: "jangrau13/ash", branch: "arg-gated-strict-check", override: true}
  ```
  `override: true` is required: other Ash extensions depend on
  `{:ash, "~> 3.x}` and would otherwise pull the hex package. Then
  `mix deps.get`. This persists across fetches, unlike editing `deps/ash` in
  place (overwritten on the next `deps.get` — that is what a local prototype
  does, and why it is throwaway).

  **Keeping the fork current with upstream Ash.** The patch is one isolated
  commit touching only `lib/ash/policy/filter_check.ex`, so rebasing onto a
  newer Ash is low-conflict:
  ```sh
  git remote add upstream https://github.com/ash-project/ash.git   # once
  git fetch upstream
  git rebase upstream/main            # or onto a specific vX.Y.Z tag
  git push --force-with-lease origin arg-gated-strict-check
  ```

  **Reverting to stock Ash** — one step, fully reversible: delete the override
  line, restore `{:ash, "~> 3.29"}` (or the current constraint), `mix deps.get`.
  Do this the moment the change lands upstream.

## What `ash_hateoas` does once Ash stops collapsing absent args

Nothing new in the affordance shape — that is the point. With the patch,
`Ash.can?` under the argument-less probe already answers `true` for an
argument-gated action and `false` for a genuine denial, so the existing
`AshHateoas.Gate.Authorization` advertises the former and hides the latter with
no change. The affordance is ordinary; its `fields` carry the arguments the
caller must supply; R6 carries the rest.
