# ODRL — mapping HTTP affordances to the Open Digital Rights Language

## What ODRL is

The Open Digital Rights Language (ODRL) is a W3C Recommendation (v2.2, February
2018) for expressing policy about what may be done to a resource.  It is
defined by two documents:

- **ODRL Information Model 2.2** — the concepts and entities
  (`https://www.w3.org/TR/odrl-model/`)
- **ODRL Vocabulary & Expression 2.2** — the RDF classes, predicates, and
  named entities used to encode those concepts
  (`https://www.w3.org/TR/odrl-vocab/`)

The namespace is `http://www.w3.org/ns/odrl/2/`, typically bound to the
prefix `odrl`.

## Core concepts (simplified)

| Term | Definition |
|---|---|
| **Policy** | A container that groups Rules (Permissions, Prohibitions, Duties) and binds them to an Asset. |
| **Asset** | The resource the Policy governs. |
| **Party** | An entity that acts in a Rule — **assigner** (issuer) or **assignee** (recipient). |
| **Permission** | The ability to perform an **Action** over an **Asset**. A Permission may carry a **Duty** that is a pre-condition. |
| **Prohibition** | The inability to perform an **Action** over an **Asset**. |
| **Duty** | An obligation to perform an **Action** — either a pre-condition on a Permission, an obligation on a Policy, a consequence of another Duty, or a remedy for violating a Prohibition. |
| **Action** | An operation on an Asset (e.g. `read`, `modify`, `delete`, `use`). |
| **Constraint** | A boolean expression that refines when a Rule is active (e.g. time, location, count). |

### Property hierarchy

```
Policy
 ├── permission  →  Permission
 │                    ├── action     →  Action
 │                    ├── target     →  Asset
 │                    ├── assigner   →  Party
 │                    ├── assignee   →  Party
 │                    ├── constraint →  Constraint
 │                    └── duty       →  Duty  (pre-condition)
 │                                      ├── action     →  Action
 │                                      ├── constraint →  Constraint
 │                                      └── consequence →  Duty
 ├── prohibition →  Prohibition
 │                    ├── action     →  Action
 │                    ├── target     →  Asset
 │                    ├── constraint →  Constraint
 │                    └── remedy     →  Duty  (must fulfil if violated)
 └── obligation  →  Duty  (must be fulfilled by assignee)
```

## ODRL Common Vocabulary — action terms used by ash_hateoas

| Action | IRI | Definition |
|---|---|---|
| `odrl:read` | `http://www.w3.org/ns/odrl/2/read` | To obtain data from the Asset |
| `odrl:modify` | `http://www.w3.org/ns/odrl/2/modify` | To change existing content of the Asset |
| `odrl:delete` | `http://www.w3.org/ns/odrl/2/delete` | To permanently remove all copies of the Asset |
| `odrl:use` | `http://www.w3.org/ns/odrl/2/use` | To use the Asset (the most generic action; all others are included by it) |
| `odrl:obtainConsent` | `http://www.w3.org/ns/odrl/2/obtainConsent` | To obtain verifiable consent to perform the action |

The `use` action is the super-type: `read`, `modify`, `delete`, and most other
actions are `includedIn` `use`.  An ODRL evaluator that grants `use` therefore
also implicitly grants every action `includedIn` it.

## How ash_hateoas maps affordances to ODRL

### Principle

An HTTP resource node that carries a `hydra:operation` array is the **effective
Policy** for that resource.  Each operation is an **Action** the caller may
perform on the **Asset** (the resource identified by the node's `@id`).

The ODRL mapping makes the permission explicit: each operation carries an
embedded `odrl:Permission` that declares the action term and the target asset.
There is no separate top-level `odrl:Policy` wrapper — the resource node *is*
the policy context.

### HTTP method → ODRL action term

| HTTP method | ODRL action | Rationale |
|---|---|---|
| `GET` | `odrl:read` | Obtain data from the Asset |
| `POST` | `odrl:use` | Create or generic — ODRL has no dedicated `create` |
| `PATCH` | `odrl:modify` | Change existing content |
| `PUT` | `odrl:modify` | Replace content |
| `DELETE` | `odrl:delete` | Permanently remove |

### What gets a Permission

Every affordance (every action that passes the authorization gate) generates a
Permission.  If the caller is not authorized for an action, the action is
**omitted entirely** — there is no `odrl:Prohibition`.  This is consistent with
the fail-closed design: denied actions are absent, and ODRL says nothing about
absent rules.

### Permissions are embedded in operations, not separate

Each `hydra:Operation` carries its own `odrl:permission` as a single
`odrl:Permission` object inside the operation:

```json
{
  "@id": "/inventory/activities/123",
  "@type": "https://ash-hateoas.org/vocab#Activity",
  "hydra:operation": [
    {
      "@type": "Operation",
      "hydra:method": "GET",
      "hydra:returns": {"@id": "https://ash-hateoas.org/vocab#Activity"},
      "odrl:permission": {
        "@type": "odrl:Permission",
        "odrl:action": {"@id": "odrl:read"},
        "odrl:target": {"@id": "/inventory/activities/123"}
      }
    },
    {
      "@type": "Operation",
      "hydra:method": "PATCH",
      "hydra:returns": {"@id": "https://ash-hateoas.org/vocab#Activity"},
      "odrl:permission": {
        "@type": "odrl:Permission",
        "odrl:action": {"@id": "odrl:modify"},
        "odrl:target": {"@id": "/inventory/activities/123"}
      }
    }
  ]
}
```

### Named sub-actions (link nodes)

A named sub-action (an action whose URL differs from the resource node's own
`@id`, e.g. `/inventory/activities/123/copy_to_database`) is rendered as a
separate link node with its own `@id`.  The `odrl:target` of the embedded
Permission is the **link node's own `@id`**, not the parent resource's:

```json
{
  "@id": "/inventory/activities/123/copy_to_database",
  "hydra:operation": [
    {
      "@type": "Operation",
      "hydra:method": "POST",
      "odrl:permission": {
        "@type": "odrl:Permission",
        "odrl:action": {"@id": "odrl:use"},
        "odrl:target": {"@id": "/inventory/activities/123/copy_to_database"}
      }
    }
  ]
}
```

### Collection endpoints

The collection endpoint (e.g. `GET /inventory/activities`) carries operations
that apply to the **collection as a whole** — creating a new resource, running
a search, etc.  These operations embed Permissions with no `odrl:target`
(because a collection is not a single asset), or with a target referencing the
collection URL.  Each member of the collection independently carries its own
operations and Permissions.

### The `odrl:assignee` is omitted

ODRL allows a Permission to name the `assignee` (the party receiving the
permission).  ash_hateoas omits it unless the authenticated actor has a stable,
dereferenceable IRI, because there is no honest value to put there for an
opaque bearer token.  The Permission states the action and the target, and the
assignee is implicit (the bearer of the request).

### The `odrl:assigner` is omitted for the same reason

The API itself is the de facto assigner, but unless the service has a stable
IRI, the property is omitted.

## Cross-reference: `hydra:Operation` ↔ `odrl:Permission`

| Operation property | Permission counterpart | Notes |
|---|---|---|
| `hydra:method` | `odrl:action` | Derived from the HTTP method (see table above) |
| the node's `@id` | `odrl:target` | The resource URL; for link nodes, the link's own `@id` |
| — | `odrl:duty` | Present only when the action is not delegable (see below) |

## `not_delegable` and ODRL

When a resource declares an action as `not_delegable`, the action requires the
**principal themselves** to perform it — an agent acting on their behalf cannot.
The semantic intention is: an AI agent reading this affordance understands that
it must ask its human owner to perform the action; the agent cannot discharge
it autonomously.

This is expressed by adding an `odrl:duty` to the Permission — a pre-condition
that the agent must fulfil before exercising the Permission.  The Duty's action
is `odrl:obtainConsent` ("To obtain verifiable consent to perform the requested
action in relation to the Asset").  The agent must obtain the owner's consent
before it may proceed; it cannot delegate the action to another agent.

```json
{
  "@id": "/documents/1/approve",
  "hydra:operation": [
    {
      "@type": "Operation",
      "hydra:method": "PATCH",
      "ah:notDelegable": true,
      "odrl:permission": {
        "@type": "odrl:Permission",
        "odrl:action": {"@id": "odrl:modify"},
        "odrl:duty": [
          {
            "@type": "odrl:Duty",
            "odrl:action": {"@id": "odrl:obtainConsent"}
          }
        ],
        "odrl:target": {"@id": "/documents/1/approve"}
      }
    }
  ]
}
```

The `ah:notDelegable` flag is **also** still emitted on the operation itself,
for a Hydra-only client that does not read ODRL.

## Relationship to the `@context`

In the JSON-LD `@context` emitted by ash_hateoas, the `odrl` prefix is bound
to the ODRL namespace:

```json
"@context": [
  "http://www.w3.org/ns/hydra/context.jsonld",
  {
    "ah": "https://ash-hateoas.org/vocab#",
    "odrl": "http://www.w3.org/ns/odrl/2/"
  }
]
```

All ODRL terms are emitted **prefixed** on the wire (`"odrl:read"`,
`"odrl:Permission"`), so the `@context` resolves them unambiguously.

## Departures from strict ODRL

| ODRL spec requirement | ash_hateoas behaviour | Reason |
|---|---|---|
| Policy must be typed (`Set`, `Offer`, or `Agreement`) | No Policy wrapper; the resource node is the context | Pragmatic — wrapping every response in a Policy container would add verbosity with no benefit for this use case |
| Permission and Prohibition are disjoint; a Prohibition is explicit | No Prohibition ever emitted | Fail-closed design: denied actions are absent, and emitting a Prohibition would leak "what you cannot do" |
| Permission must carry `assignee` and `assigner` | Omitted unless a stable IRI exists | The actor is identified by an opaque bearer token with no dereferenceable identity |
| Duty is a pre-condition to a Permission | Used only for `not_delegable` actions | The only duty concept this domain needs |

## Sources

- [ODRL Information Model 2.2](https://www.w3.org/TR/odrl-model/)
- [ODRL Vocabulary & Expression 2.2](https://www.w3.org/TR/odrl-vocab/)
- Namespace: `http://www.w3.org/ns/odrl/2/`
- JSON-LD Context: `https://www.w3.org/ns/odrl/2/ODRL22.json`