# AshHateoas

Authorization- and state-aware **HATEOAS affordances** for [Ash](https://ash-hq.org),
rendered natively into JSON:API links and MCP tools from a single backbone.

JSON:API gives you navigation — `self`, `related`, pagination. It says nothing
about *affordances*: which actions a client may take next. This package closes
that gap, and closes it once: one engine answers "what may this actor do with
this record, in its current state?", and each transport renders that answer in
its own idiom.

| Backbone output | JSON:API | MCP |
|---|---|---|
| an action that may be taken next | a `links.<action>` object | a tool in `tools/list` |
| the affordance set for a state | the record's `links` | the `tools/list` result |
| field descriptor | link `meta.fields` | the tool's `inputSchema` |

## Why Ash

Most backends cannot answer "may this actor run this action on this record right
now?" cheaply. Ash can — `Ash.can?/3` is exactly that question, and actions,
routes and state-machine transitions are all already declared and introspectable.
Affordances are therefore *derived*, never authored.

## Installation

```elixir
def deps do
  [{:ash_hateoas, "~> 0.1"}]
end
```

Or with [Igniter](https://hexdocs.pm/igniter):

```sh
mix igniter.install ash_hateoas
```

Then add the extension alongside your transport extension(s):

```elixir
defmodule MyApp.Document do
  use Ash.Resource,
    extensions: [AshJsonApi.Resource, AshHateoas.Resource]
end
```

That is the whole per-resource setup. Every adapter renders from the same
declaration.

## Overrides

The DSL is override-only — it carries deviations, never per-action opt-ins:

```elixir
hateoas do
  enabled? true
  exclude :internal_reconcile
  override :approve, href: "/documents/:id/approve"
end
```

A compile-time verifier rejects an `exclude` or `override` naming an action that
does not exist.

## Status

Under development. See `REQ.md` for the requirement set and `PLAN.md` for the
build order.

## License

MIT
