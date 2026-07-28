# Requirement — emit canonical `hydra:Collection` references (not `{href, rel}`)

**To:** the agent maintaining the Hydra / JSON-LD transport (`lib/ash_hateoas/hydra/`, `lib/ash_hateoas/navigation.ex`).
**From:** the hydrash demo work (two schema.org services navigated by a generic Hydra client).
**Priority:** medium — the API is navigable today; this is a spec-conformance fix that makes it correct for strict Hydra clients.

## Problem

The root node and per-record navigation emit collection links in a **HAL / JSON:API shape** (`{"href": …, "rel": "collection"}`), not canonical Hydra. `rel` is a web-linking term, not a Hydra Core term, and the value is a plain object rather than a typed node reference.

Observed now — `GET /` on a service:

```json
{
  "hydra:collection": {
    "person":       { "href": "/people/person",       "rel": "collection" },
    "organization": { "href": "/people/organization",  "rel": "collection" }
  }
}
```

And on a record node (`Navigation.record_links/3` → `merge_navigation/2`):

```json
"hydra:collection": { "href": "/people/person", "rel": "collection" },
"hydra:view":       { "href": "/",              "rel": "up" }
```

A strict Hydra consumer expects the value of a `hydra:collection` link to be a **node reference** carrying an `@id` (and, ideally, `@type: "hydra:Collection"`), so it can recognise the target as a collection without out-of-band knowledge of a `rel` token. `rel`/`href` force the client to special-case this API's own convention — the opposite of what Hydra is for.

## Desired shape

Entry point:

```json
{
  "hydra:collection": {
    "person":       { "@id": "/people/person",       "@type": "hydra:Collection" },
    "organization": { "@id": "/people/organization",  "@type": "hydra:Collection" }
  }
}
```

Record navigation:

```json
"hydra:collection": { "@id": "/people/person", "@type": "hydra:Collection" },
"hydra:view":       { "@id": "/",              "@type": "hydra:Resource" }
```

(`hydra:view` → the parent/up resource; `hydra:Resource` is the honest minimal type. If a better term exists for "up", use it — the key point is `@id` + a `@type`, not `href`/`rel`.)

## Where

- `lib/ash_hateoas/navigation.ex` — `root/3` (returns `%{type => %{"href", "rel"}}`) and `record_links/3` (`put_collection/4`, `put_domain/4`).
- `lib/ash_hateoas/hydra/plug.ex` — the `GET /` dispatch builds `hydra:collection` from `Navigation.root/3`; `merge_navigation/2` maps `collection`/`up` onto `hydra:collection`/`hydra:view`. These currently read `%{"href" => …}`.

Note `Navigation` is shared with the (now-removed?) JSON:API transport originally; if any non-Hydra caller still relies on `{href, rel}`, keep that mapping at the JSON:API boundary and convert to the typed form **inside the Hydra plug** rather than changing `Navigation`'s contract for everyone. Simplest is probably: have the Hydra plug translate `Navigation`'s output into typed node refs when it renders, leaving `Navigation` as the transport-neutral source of `{url, kind}`.

## Downstream consumers to update in lockstep

Both read the current `href`/`@id` shape and must accept the new one:

1. **`hateoas_mcp`** (`lib/hateoas_mcp/server.ex` `types/2`, `lib/hateoas_mcp/hydra_document.ex` `navigation/3`, `url_of/1`) — its discovery reads the entry point's collection links and a node's `hydra:collection`/`hydra:view`. It already handles `%{"@id" => …}` and `%{"href" => …}`; confirm the typed form still resolves.
2. **The hydrash notebook** (`notebook/build_notebook.py`, the `Doc.links` method) — reads `@id`/`href` off `hydra:collection` entries. Straightforward to update.

## Acceptance

- `GET /` and any record node emit `hydra:collection` / `hydra:view` values as `{"@id": …, "@type": "hydra:Collection" | "hydra:Resource"}` with **no** `href`/`rel` keys.
- `AshHateoas.Hydra.PlugTest` updated: the entry-point and navigation assertions check `@id` + `@type` instead of `href`/`rel`.
- `hateoas_mcp` integration suite still green against the new shape.
- Relative-vs-absolute `@id` behaviour is unchanged (still relative unless `base_url` is set).