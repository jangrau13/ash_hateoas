# Semantic affordances — annotating operations, permissions, and links

`ash_hateoas` already annotates **nouns**: `semantic_type` maps a resource to a
well-known class (schema.org), `semantic_property` maps an attribute to a
well-known property. Those ride *alongside* the native Hydra terms
(`owl:equivalentClass` on the class, a `@context` binding on the property) — the
Hydra term stays the identifier, the well-known vocabulary is additive.

This document extends the same **"annotate, don't replace"** pattern from nouns
to the things `ash_hateoas` uniquely produces — **operations, authorization, and
links** — using standard vocabularies instead of minting private `ah:` terms for
concepts a standard already covers.

Every vocabulary below was verified against its live/normative source (listed
under Sources), not from memory.

## The layers

| Layer | Native term (kept) | Standard annotation (added) | Vocabulary |
|---|---|---|---|
| an operation's HTTP verb | `hydra:method: "PATCH"` | — (already an IANA method) | IANA HTTP Methods |
| an operation's *action semantics* | `hydra:operation` | `schema:potentialAction` typed `ReadAction`/`CreateAction`/`UpdateAction`/`DeleteAction`/… | schema.org Actions |
| the named-sub-action relation | `ah:<action>` key | (identifier stays; CRUD writes *are* the IANA `edit` rel) | IANA Link Relations |
| an actor's granted operation | node `hydra:operation` (present-if-allowed) | `odrl:Permission` with an `odrl:action` | ODRL 2.2 |
| `not_delegable?` | `ah:notDelegable` | `odrl:Duty` / `odrl:Constraint` | ODRL 2.2 |
| a to-many relationship | a navigation route | `hydra:Link` property on the node | Hydra Core |
| an operation's outcomes | (none today) | `hydra:possibleStatus` → `hydra:Status` | Hydra Core |

## Layer 1 — schema.org `potentialAction` (the operation as a verb)

Each affordance already renders as a `hydra:Operation`. Additionally it carries a
`schema:potentialAction` — the schema.org description of the *action*, which
search engines and assistants understand where they do not speak Hydra:

```json
"schema:potentialAction": {
  "@type": "UpdateAction",
  "target": {
    "@type": "EntryPoint",
    "urlTemplate": "/orders/{id}/confirm",
    "httpMethod": "PATCH",
    "contentType": "application/ld+json"
  }
}
```

Note: schema.org's `EntryPoint` is an *action's HTTP endpoint descriptor* — a
**different** concept from this package's `ah:EntryPoint` (the API root node). We
keep both; they never collide because one is a `target` value and the other is a
document `@type`.

**Action-subtype mapping — CRUD auto, with an optional override.** The subtype is
inferred from the Ash action's *type* (never guessed from its name, which would
risk emitting a schema.org type that does not exist):

| Ash action type | schema.org Action subtype |
|---|---|
| `:read` | `ReadAction` |
| `:create` | `CreateAction` |
| `:update` | `UpdateAction` |
| `:destroy` | `DeleteAction` |
| `:action` (generic) | `Action` |

A domain verb whose meaning is finer than its CRUD type — a state transition like
`confirm`/`ship`/`cancel` (all `:update`) — defaults to `UpdateAction` and is
sharpened by an explicit declaration:

```elixir
hateoas do
  semantic_action :confirm, "ConfirmAction"   # schema.org has ConfirmAction, ShipAction, CancelAction…
  semantic_action :ship,    "ShipAction"
end
```

A bare token resolves against schema.org (`"ConfirmAction"` →
`https://schema.org/ConfirmAction`); an absolute IRI is used verbatim — exactly
as `semantic_type` already behaves.

## Layer 2 — ODRL (the granted operation as a permission)

`ash_hateoas` uniquely resolves, per actor and per record state, **what may be
done** — and expresses "may not" by *omitting* the affordance (fail-closed). That
posture dictates the ODRL mapping:

- A node's granted `hydra:operation`s become an `odrl:Permission` set — each a
  permission whose `odrl:action` is the operation's action term
  (`odrl:read`/`odrl:use` for a read, `odrl:modify` for a write, `odrl:delete`
  for a destroy).
- **Permission-only. No `odrl:Prohibition`.** A denied action is not in the
  envelope at all, so we have nothing to base a prohibition on — and emitting one
  would leak "what you cannot do," which the present-if-allowed design
  deliberately withholds. The honest ODRL projection of a fail-closed surface is
  a permission list, not a permission/prohibition pair.
- `not_delegable?` → an `odrl:Duty` (a duty the permission is subject to: the
  action commits, so only a committing credential discharges it) — replacing the
  private `ah:notDelegable` flag with the W3C term for exactly this.

```json
"odrl:permission": [
  {
    "@type": "odrl:Permission",
    "odrl:target": { "@id": "/orders/1" },
    "odrl:action": { "@id": "odrl:modify" },
    "odrl:assignee": { "@id": "<actor iri, when known>" }
  }
]
```

## Layer 3 — fuller Hydra (links and status)

Uses more of the vocabulary already grounded, no new namespace:

- **`hydra:Link` for relationships.** A public to-many relationship already
  derives a route; surface it as a `hydra:Link`-typed property on the node whose
  value references the related collection, so the relationship is followable as a
  first-class link rather than only via navigation.
- **`hydra:possibleStatus`.** Each operation can advertise the statuses it may
  return, as `hydra:Status` nodes derived from the gate chain — a `403` where a
  policy gates the action, a `422` where validations apply. Actor-independent
  shape (the catalogue side), consistent with `expects`/`returns`.

## Sources (verified)

- **ODRL 2.2 vocabulary (W3C Recommendation):**
  `https://www.w3.org/ns/odrl/2/ODRL22.json`. Namespace
  `http://www.w3.org/ns/odrl/2/`. Confirmed classes `Permission`, `Prohibition`,
  `Duty`, `Constraint`; properties `assigner`, `assignee`, `constraint`, `duty`,
  `action`, `target`; action terms include `use`, `read`, `modify`, `transfer`,
  `distribute` (delete-like via `uninstall`).
- **schema.org Actions:** `https://schema.org/docs/actions.html`,
  `https://schema.org/potentialAction`, `https://schema.org/EntryPoint`.
  Confirmed `potentialAction` (domain `Thing`, range `Action`); `Action` →
  `target` → `EntryPoint` with `urlTemplate` / `httpMethod` / `contentType`;
  CRUD subtypes `ReadAction` / `CreateAction` / `UpdateAction` / `DeleteAction`
  and domain verbs (`ConfirmAction`, `CancelAction`, `ShipAction`, …).
- **IANA Link Relations:** the registered `edit` relation (RFC 5023) for a
  resource's update/delete affordance; no registered relation for domain verbs
  (`approve`, `confirm`), which is why `ah:<action>` remains their identifier.
- **IANA HTTP Method Registry:** the `hydra:method` token values.
- **Hydra Core Vocabulary:** `hydra:Link`, `hydra:possibleStatus`,
  `hydra:Status` — as verified in `hydra-conformance-notes.md`.

## Design principle

Same rule as the noun layer, applied throughout: **the native/`ah:` term stays
the stable identifier; a standard vocabulary is added alongside so a client that
speaks the standard understands the affordance without understanding
`ash_hateoas`.** Nothing here is authored per resource beyond the optional
`semantic_action` override — every annotation is derived from what the action,
its type, its policies, and its state machine already declare.
