# The Affordances Profile

**Profile URI:** `https://ash-hateoas.org/profiles/affordances`

A [JSON:API 1.1 profile](https://jsonapi.org/extensions/#profiles) describing how
a server advertises **affordances** — the actions a client may take next on a
resource, given who is asking and what state the resource is in.

A response conforming to this profile declares it in its content type:

```
Content-Type: application/vnd.api+json; profile="https://ash-hateoas.org/profiles/affordances"
```

## Rationale

JSON:API is strong on navigation (`self`, `related`, pagination) and silent on
affordances. A client can discover *where things are* but not *what it may do*,
so it falls back to out-of-band knowledge of the API — the thing hypermedia
exists to eliminate.

This profile closes that gap using the mechanism JSON:API already provides.
Link names are not restricted by the specification — "a link's relation type
should be inferred from the name of the link" — and a link object may carry
`href`, `rel`, `title`, `type`, `hreflang` and `meta`. Affordances *are* links,
so `links` is the correct slot. Serializing them into `attributes` is not.

## Link objects

Each affordance is a member of a `links` object, keyed by the action name:

```json
{
  "data": {
    "type": "document",
    "id": "123",
    "attributes": { "title": "Q3 Report" },
    "links": {
      "self": "/api/documents/123",
      "approve": {
        "href": "/api/documents/123/approve",
        "rel": "https://ash-hateoas.org/rels/approve",
        "title": "Approve this document so it can be published.",
        "meta": {
          "method": "PATCH",
          "fields": [
            {
              "name": "notify",
              "type": "boolean",
              "required": false,
              "description": "Email the owner.",
              "default": false
            },
            {
              "name": "visibility",
              "type": "string",
              "required": false,
              "constraints": { "enum": ["public", "private"] }
            }
          ]
        }
      }
    }
  }
}
```

### Members

| Member | Required | Meaning |
|---|---|---|
| `href` | yes | Where to send the request. May be `null` where the transport has no URL for the action. |
| `rel` | yes | The relation type, `https://ash-hateoas.org/rels/<action>`. |
| `title` | no | Human-readable description of the action. |
| `meta.method` | yes | Uppercase HTTP method (`GET`, `POST`, `PATCH`, `DELETE`). |
| `meta.fields` | yes | Inputs the client may supply. May be empty. |
| `meta.multiStep` | no | `true` when the action is a compound operation. |

### Field objects

| Member | Required | Meaning |
|---|---|---|
| `name` | yes | The input's name. |
| `type` | yes | One of `string`, `integer`, `number`, `boolean`, `date`, `time`, `datetime`, `duration`, `map`, `array`, `union`, `link`. |
| `required` | yes | Whether the input must be supplied. |
| `description` | no | Human-readable description. |
| `default` | no | The value used when the input is omitted. **Absent** for sensitive inputs. |
| `constraints` | no | Validation the client may apply up front — e.g. `enum`, `min`, `max`, `min_length`, `max_length`, `pattern`. |

## The `link` type

A field or attribute of type `link` carries the URL of another hypermedia
resource — including one served by a **different** API, which no relationship
link can express, since those are rendered against the requesting host.

```json
"attributes": {
  "title": "Q3 Report",
  "order": "https://another-backend.example/orders/xyz"
}
```

The type is what makes the value followable. A client MUST NOT infer
followability from a value merely parsing as a URL: a `homepage` or `source_url`
is a URL and is not a resource to dereference.

**A client MUST check the host before following.** The value is application
data, so a server may emit any URL. A client that dereferences it — especially
one attaching credentials — MUST validate the host against its own allowlist,
and MUST NOT send a credential belonging to one host to another.

## Rules a conforming server MUST follow

1. **Only advertise what the actor may invoke.** The affordance set is resolved
   per request from the requesting client's own context. Two clients requesting
   the same resource may legitimately receive different affordances.

2. **Never emit a sensitive input's `default`.** The field itself still appears
   — the client must know to supply it — but the value must not reach the wire.

3. **Never expose a private input.** If the server does not accept an input from
   clients, it must not appear as a field.

4. **Collections carry collection-level affordances only.** A collection document's
   *top-level* `links` carries the affordances that apply to the type (such as
   `create`); resource objects inside `data` carry navigation but no
   affordances. This bounds the cost of a collection response to be independent
   of its page size.

5. **Affordances are advisory.** The server re-runs its authorization,
   validation and state checks on invocation. A client MUST be prepared for an
   advertised affordance to fail — a stale proposal degrades to a clean error,
   never an invalid write.

## Rules for a client

- **Follow links; do not construct URLs.** An affordance's `href` is the only
  supported way to invoke it.
- **Treat a missing affordance as "not available now"**, not as "does not
  exist". It may reappear when the resource's state or the actor's permissions
  change.
- **Use `meta.fields` to validate up front.** Anything the constraints cannot
  express surfaces as a `422` on invocation.
- **Do not cache an affordance set across actors.** It is specific to the actor
  who requested it.

## What a client cannot learn from these documents

A document says what may be done **now**, to **this** record, by **this** actor.
It does not describe what could be done under other circumstances, and that is
deliberate: publishing the full set of actions and the conditions on each would
make these documents an API description, inviting a client to reason about the
server's state machine and plan against it — the opposite of reading what is
offered and choosing from it.

Two consequences worth stating plainly, because they surprise consumers that try
to build a catalogue:

- **The set of actions a *type* affords cannot be enumerated.** Each record
  reveals only the actions legal from its own state, so an action reachable only
  from a state that no current record occupies is invisible. A service with no
  confirmed orders has no way to reveal that shipping exists. Sampling more
  records does not fix this — the information is not in the data.
- **Absence carries no information about the future.** A missing affordance
  means "not now", and nothing about whether it will appear later.

A consumer that drives the loop — read a representation, act on one of its
affordances, read what came back — never needs either. Each action becomes
visible exactly when it becomes possible. A consumer that plans up front from an
enumerated list of capabilities is asking these documents for something they do
not offer.

## Relation types

Each affordance carries `rel` of the form
`https://ash-hateoas.org/rels/<action-name>`. These are *not* IANA-registered
relation types; they are server-defined extension relation types as permitted by
[RFC 8288](https://www.rfc-editor.org/rfc/rfc8288). A client keys off the link
*name* within the `links` object; `rel` exists so the relation is dereferenceable
and unambiguous when links are lifted out of context.

Structural navigation (`self`, `related`, `next`, `prev`, `first`, `last`,
`collection`) continues to use registered IANA relation types, so navigation and
affordances arrive together in one `links` object without collision.

## Prior art

The vocabulary aligns deliberately with existing affordance formats:

- **`spring-hateoas-jsonapi`** renders affordances as link `meta` with `name`,
  `httpMethod` and `inputProperties[{name,type,required}]`.
- **HAL-FORMS** `_templates` carry `method` and `properties[{name,required}]`.
- **Siren** `actions` carry `name`, `method`, `href` and `fields[{name,type}]`.
