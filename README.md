# AshHateoas

> ⚠️ **Purely experimental.** A research prototype, not a library to depend on.
> It exists to find out how much of a domain a Hydra API can publish before a
> client needs to be told anything out of band.

Authorization- and state-aware **HATEOAS affordances** for [Ash](https://ash-hq.org),
served natively as a **[Hydra](https://www.hydra-cg.com/) / JSON-LD** API.

A resource's actions, routes and state-machine transitions are already declared
and introspectable. This package derives from them the one thing a REST client
otherwise has to be told out-of-band: *which actions may this actor take next,
on this record, in its current state?* — and publishes that answer as Hydra
operations a generic client can discover and drive at runtime.

| Backbone output | Rendered as |
|---|---|
| an action that may be taken next | a `hydra:Operation` (`hydra:method`, `hydra:expects`) |
| a named sub-action with its own URL | a link node (`ah:<action>` → `{ @id, hydra:operation }`) |
| a field descriptor | a `hydra:SupportedProperty` (or `hydra:IriTemplateMapping`) |
| the type's catalogue | `hydra:ApiDocumentation` → `supportedClass` |
| a collection | a `hydra:Collection` (`member`, `totalItems`, `PartialCollectionView`) |

Documents are plain JSON-LD keyed to the Hydra Core Vocabulary
(`http://www.w3.org/ns/hydra/core#`), so a client that has never seen this code
— or Ash — can enter at one URL and reach every type, act on every record, and
follow the state machine from the affordances it is offered.

## Why Ash

Most backends cannot answer "may this actor run this action on this record right
now?" cheaply. Ash can — `Ash.can?/3` is exactly that question, and actions,
routes and state-machine transitions are all already declared and introspectable.
Affordances are therefore *derived*, never authored.

## Installation

```elixir
def deps do
  [
    {:ash_hateoas, "~> 0.1"}
  ]
end
```

Or with [Igniter](https://hexdocs.pm/igniter):

```sh
mix igniter.install ash_hateoas
```

Then add the extension to the resources that should expose affordances:

```elixir
defmodule MyApp.Document do
  use Ash.Resource,
    domain: MyApp.Docs,
    extensions: [AshHateoas.Resource]
end
```

That is the whole per-resource setup. Every action is routed and advertised
automatically; a resource declares a `hateoas` `type` (or lets one be inferred
from its module name) and nothing else.

## Serving

Mount the Hydra plug to serve a domain as `application/ld+json`:

```elixir
defmodule MyApp.HydraRouter do
  use Plug.Builder

  plug AshHateoas.Hydra.Plug,
    domains: [MyApp.Docs],
    prefix: "/api",
    doc_path: "/doc"
end
```

It serves the `ApiDocumentation` entry point at `/`, the full documentation at
`doc_path`, and reads/writes every routed resource — attaching each record's
actor- and state-gated affordances as `hydra:operation`, and advertising the
API documentation via a `Link` header on every response.

## Overrides

The DSL is override-only — it carries deviations, never per-action opt-ins:

```elixir
hateoas do
  type "document"          # optional; inferred from the module name otherwise
  base "/documents"        # optional; derived from domain + type otherwise
  exclude :internal_reconcile
  override :approve, href: "/documents/:id/approve"
end
```

A compile-time verifier rejects an `exclude`, `override` or `unrouted` naming an
action that does not exist.

## Status

Under development.

## License

MIT
