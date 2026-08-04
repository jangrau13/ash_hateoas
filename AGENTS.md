# AshHateoas — Agent instructions

An Elixir library that derives HATEOAS affordances from Ash resources and serves
them as a Hydra / JSON-LD API.

## Quick reference

```sh
# build / test (vanilla Elixir project)
mix deps.get
mix test

# single test file
mix test test/ash_hateoas/backbone_test.exs

# format (uses spark_locals_without_parens from .formatter.exs)
mix format

# codegen / install
mix ash_hateoas.gen.schema_org
mix igniter.install ash_hateoas
```

Tests are async by default. Fixtures live in `test/support/` and are compiled
only in `:test` env (see `elixirc_paths` in `mix.exs`). Records use
`System.unique_integer` for identity fields to avoid deadlocks under concurrent
test runs. Tests create records via `Ash.create!(authorize?: false)`.

## Non-obvious constraints

- **Ash is a patched local dep** — `{:ash, path: "../ash", override: true}`.
  The patch (`arg-gated-strict-check` branch) makes `Ash.can?/3` return
  `:unknown` rather than `false` for argument-gated filters when the argument
  is absent. Without this, affordance probing with no arguments would wrongly
  drop gated actions.

- **DSL is override-only** — no per-action opt-ins. `hateoas` block subtracts
  or corrects. Every action is routed by default unless declared `unrouted`.
  `unrouted` is how you keep an action off the HTTP surface — `exclude` only
  hides it from affordance advertisement while leaving it routed.

- **Compile-time verifier** rejects `exclude`/`override`/`unrouted`/`method`
  that name nonexistent actions — a renamed action fails the build rather than
  silently losing its deviation.

- **Routes are derived automatically** from the resource's `type` (inferred
  from module name if undeclared) and the domain's module-name-derived
  `short_name`. Type is **not** pluralised — declare `base` explicitly for the
  plural form.

- **Affordances are advisory, not authoritative** — the endpoint re-runs every
  policy on invocation. Affordances are a hint; security is the policy.

- **Two automatically-skipped action kinds**: Reactor compensations (single
  `changeset` argument, unconstructable by HTTP) and AshAuthentication-generated
  actions (served by Auth's own router). Both skips live in the Spark
  transformer `AshHateoas.Resource.Transformers.DeriveActionRoutes`, which
  derives routes at **compile time** — route changes require recompilation,
  and the transformer is where routing surprises should be debugged first.

## Architecture

| Layer | Module | Role |
|-------|--------|------|
| Public API | `AshHateoas` | `affordances/3` entry point |
| Engine | `AshHateoas.Backbone` | candidates → gates → descriptors |
| Candidates | `AshHateoas.Candidates` | actions + routes, minus excludes |
| Gates | `AshHateoas.Gate.*` | authorization (`Ash.can?/3`), state machine |
| Descriptor | `AshHateoas.Descriptor` | builds affordance structs from actions |
| DSL extension | `AshHateoas.Resource` | the `hateoas` / `agentic_hateoas` sections |
| Transport | `AshHateoas.Hydra.Plug` | serves JSON-LD via Plug |
| Navigation | `AshHateoas.Navigation` | structural links (entry point → collections) |
| Domain defaults | `AshHateoas.Domain` | optional domain-level `enabled?` defaults |

Key optional deps that affect code branches: `ash_state_machine` (state gate),
`ash_authentication` (skips auth-generated actions), `igniter` (install gen).

## Noteworthy patterns

- `AshHateoas.Posture.enabled?/2` resolves resource > domain > `true`. Default
  is **on** — affordances are a hypermedia contract, not an opt-in feature.
- `not_delegable` (in `agentic_hateoas` section) keeps an action advertised but
  refuses execution by delegated credentials. The default `CommitAuthority`
  commits for everyone — configure it to opt in.
- Hydra plug's `base_url` option affects rendered hrefs only (not route
  matching), for proxied deployments.
- Private arguments never appear in affordance fields; sensitive arguments
  appear but their `default` is replaced with `:error`.

## Verification order

`mix format` → `mix test` (no typecheck or lint — this project has none
configured beyond the Erlang compiler's own diagnostics).

## Reference docs

- `usage-rules.md` — consumer-facing usage rules, shipped with the hex package.
- `documentation/hydra-mapping.md` — how Ash concepts map onto Hydra terms.
