# Changelog

## Unreleased

### Breaking

**Every action is now routed by default.** Adding `AshHateoas.Resource` to a
resource widens that resource's HTTP surface to every action it declares.
Previously the extension only *read* routes an author had written; it now
derives them.

Before, an action reached the API only once someone wrote a route for it.
Forgetting yielded a 404. Now, forgetting yields a live endpoint — and there is
no diff to show for it, because the omission is in a file nobody edited. Audit
each resource's actions before upgrading, and declare `unrouted` for any that
must not be reachable:

```elixir
hateoas do
  unrouted :sync_from_stripe
end
```

`unrouted` is verified against the action list, so a renamed action fails the
build rather than silently becoming routed again. Policies remain the actual
gate on what any actor may invoke — routed is not the same as permitted.

**`base` is derived when not declared**, from the domain's short name and the
json_api `type`: `MyApp.Blog.Comment` with `type "comment"` becomes
`/blog/comment`. Resources that declared a `base` are unaffected; resources that
did not will see their URLs change. The type is used verbatim and is **not**
pluralised — see the note under *Added* for why.

### Added

- `not_delegable :action`, in a new `agentic_hateoas` block — an action that
  stays advertised but is executed only by a credential that commits:

  ```elixir
  agentic_hateoas do
    not_delegable :publish
  end
  ```

  ```elixir
  config :ash_hateoas, commit_authority: AshHateoas.CommitAuthority.ApiKey
  ```

  Note the inversion against every other entry in the DSL: `exclude` and
  `unrouted` *subtract*, this one subtracts nothing. The action keeps its route,
  keeps its affordance, and gains a `notDelegable` flag in the rendered link
  meta. Withholding it instead would leave a delegated caller unable to tell
  "this does not exist" from "you may propose this but not perform it", and so
  unable to ask anyone for it.

  A non-committing credential invoking it receives **403** carrying a projection
  of what the action would have done, in `errors[].meta`. Nothing is executed to
  produce it — the transitions and the gate chain are read, so no change module
  runs and no side effect fires.

  Inert until configured: with no `commit_authority` set every credential
  commits, so this changes nothing for an existing deployment. The shipped
  `ApiKey` authority reads `__metadata__[:using_api_key?]`, which
  `ash_authentication`'s api_key strategy already stamps; a deployment needing
  a different rule implements `AshHateoas.CommitAuthority` itself.

  Two constraints worth knowing. It means "holds a delegated credential", not
  "is an agent" — a person scripting with their own key is refused too. And a
  `not_delegable` action can no longer run atomically, since an atomic update
  never calls `change/3` and would skip the refusal.
- `AshHateoas.Projection` — the affordance set as it would be at another state,
  derived from `AshStateMachine` transitions and the existing gate chain. Useful
  on its own for "what would this action unlock?"; used by the refusal above.
- Routes derived per action: primaries take the REST verbs, everything else is
  addressed by name under `/:id/<action>`.
- `unrouted :action` — keep an action off the HTTP surface entirely. Distinct
  from `exclude`, which leaves it routed but unadvertised.
- `method :action, :get` — the verb for a generic action. `action :tally,
  :boolean` declares no HTTP semantics, so POST is assumed (it understates
  nothing) and a warning says so. Declaring the method either way silences it.
- Reactor compensation actions are skipped automatically. Ash requires an
  `undo_action` to take a single `changeset` argument, so no HTTP caller can
  construct a request for one; a derived route would raise when followed.
- AshAuthentication's own actions are skipped automatically. Sign-in and
  registration are served by its own router; `:get_by_subject` is guarded by a
  bypass that only matches in-process calls, so a route would always 403. Read
  from AshAuthentication's introspection, not from action names.
- Compile-time warning when several `get` routes are marked `primary?`. Ash
  rejects two *actions* of a type marked primary, but two *routes* compile
  silently and `ash_json_api` then picks the record's `self` link arbitrarily.
- Compile-time warning when a resource declares several `index` routes.
  `AshHateoas.Navigation` resolves a type's collection URL — and whether the
  type appears in the root document at all — from its `index` route, taking the
  first. A second one makes both answers depend on route ordering.

The `base` is not pluralised deliberately. ash#31 removed exactly this guess
across the framework in one decision — ash_postgres stopped guessing table names
and ash_json_api stopped guessing base routes — because pluralisation is where
the guessing lives: `person` → `/persons`, `status` → `/statuss`. A wrong base
makes every URL for that resource wrong, and URLs are public API. Declare `base`
for the conventional plural.

### Fixed

- `.formatter.exs` listed only three of this package's DSL entries, so
  `mix format` rewrote the rest into calls — `method :tally, :post` became
  `method(:tally, :post)`. The exported `locals_without_parens` now covers every
  entry, which also fixes the same churn in consuming applications.
- Non-primary reads are now routed by what they RETURN, not lumped together. A
  read that returns a collection (`get?: false` — a search, a filtered list)
  derives an `:index` at `/<name>`, so it is reachable without an `:id` and
  advertises as a collection affordance. A read that returns a single record
  (`get?: true`) stays a member `:get` at `/:id/<name>`. Previously every
  non-primary read went to `/:id/<name>`, which left a collection read
  unreachable — there is no `:id` to supply — and was the reason a semantic
  search action could not be exposed without a hand-written route. This
  supersedes the earlier fix that routed all non-primary reads as `get`;
  `AshHateoas.Navigation` now resolves the canonical collection by path (the
  base index, not a named `/<name>` one), so several indexes coexist without the
  type dropping out of the root document.
- `Ash.Domain.Info.short_name/1` deadlocked the compiler when deriving `base`.
  It forces the domain module to finish compiling while the domain is itself
  waiting on its resources. The name now comes from the module, which needs
  nothing compiled.
- `DeriveRelationshipRoutes` now runs after `DeriveActionRoutes`. Its routes
  carry `action: :read`, which the action deriver would otherwise read as the
  author having hand-routed the primary read, suppressing that resource's `get`
  and `index`.
