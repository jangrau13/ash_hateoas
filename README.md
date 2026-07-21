# AshHateoas

Authorization- and state-aware **HATEOAS affordances** for [Ash](https://ash-hq.org),
rendered natively into JSON:API links.

JSON:API gives you navigation — `self`, `related`, pagination. It says nothing
about *affordances*: which actions a client may take next. This package closes
that gap: one engine answers "what may this actor do with this record, in its
current state?", and the renderer projects that answer into the transport's own
idiom.

| Backbone output | Rendered as |
|---|---|
| an action that may be taken next | a `links.<action>` object |
| the affordance set for a state | the record's `links` |
| field descriptor | link `meta.fields` |

The documents are described by a published
[profile](documentation/profiles/affordances.md), so a client needs no
knowledge of Ash — or of this package — to drive an API that uses it.
[`hateoas_mcp`](https://github.com/jangrau/hateoas_mcp) is one such client: an
MCP server that speaks to any service advertising the profile, over HTTP.

## Why Ash

Most backends cannot answer "may this actor run this action on this record right
now?" cheaply. Ash can — `Ash.can?/3` is exactly that question, and actions,
routes and state-machine transitions are all already declared and introspectable.
Affordances are therefore *derived*, never authored.

## Installation

```elixir
def deps do
  [
    {:ash_hateoas, "~> 0.1"},
    # `ash_json_api` reaches for `AshJsonApi.OpenApi` when validating a write,
    # and that module only exists when `open_api_spex` is present — without it
    # a PATCH or POST through the router raises.
    {:open_api_spex, "~> 3.18"}
  ]
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

## Adding a transport

Don't add one here. The documents this package produces are described by
[the affordances profile](documentation/profiles/affordances.md) — completely
enough that a consumer can discover an API's types, act on its records, and
follow its state machine knowing nothing about Ash.

Build against those documents instead, as a separate package. Anything a
transport needs that the profile does not publish is a gap in the profile, and
belongs here rather than in the consumer.

## Status

Under development. See `REQ.md` for the requirement set.

## License

MIT
