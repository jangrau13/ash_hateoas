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

## Choosing the vocabulary — not only schema.org

schema.org is the **default**, not a hard-wiring. `semantic_type`,
`semantic_property` and `semantic_action` each accept either form:

- an **absolute IRI** (anything containing `"://"`) — used **verbatim**, so **any
  ontology works with no configuration at all**:

  ```elixir
  hateoas do
    semantic_type "http://www.ease-crc.org/ont/SOMA.owl#Grasping"
    semantic_property :force, "http://www.ease-crc.org/ont/SOMA.owl#hasForceValue"
    semantic_action  :pick,  "http://www.ease-crc.org/ont/SOMA.owl#Picking"
  end
  ```

- a **bare token** — a convenience expanded against the *configured* semantic
  vocabulary. That vocabulary defaults to schema.org, but a customer whose
  resources are typed by a different ontology can make theirs the default:

  ```elixir
  config :ash_hateoas,
    semantic_vocab: [
      base: "http://www.ease-crc.org/ont/SOMA.owl#",
      prefix: "soma"
    ]
  ```

  Now a bare `semantic_type "Grasping"` resolves to
  `http://www.ease-crc.org/ont/SOMA.owl#Grasping`, and the emitted `@context`
  declares `"soma"` as its prefix so those IRIs compact. The built-in `schema`
  prefix is **always** kept, so a resource can still write absolute schema.org
  IRIs even when its default vocabulary is something else — vocabularies mix
  freely per attribute/action.

Only what a **bare** token means changes; absolute IRIs are never touched. See
`AshHateoas.SemanticVocab`. (An un-annotated action's class gets **no**
superclass at all — a subtype derived from the HTTP method would restate
`hydra:method`. Name its role with an explicit `semantic_action`, in schema.org's
vocabulary or your own.)

## The layers

| Layer | Native term (kept) | Standard annotation (added) | Vocabulary |
|---|---|---|---|
| an operation's HTTP verb | `hydra:method: "PATCH"` | — (already an IANA method) | IANA HTTP Methods |
| an operation's *identity* | a minted class, `<Class>/<action>Action`, in the operation's `@type` | — (the class **is** the IRI) | this API's own vocabulary |
| an operation's *declared role* | the minted class | `rdfs:subClassOf` an explicit `semantic_action` (`CheckAction`, `ConfirmAction`, …), declared in the ontology; absent where none was given | schema.org Actions |
| the named-sub-action relation | the operation's class (its URL as `ah:href`) | (identifier stays; CRUD writes *are* the IANA `edit` rel) | IANA Link Relations |
| an actor's granted operation | node `hydra:operation` (present-if-allowed) | `odrl:Permission` with an `odrl:action` | ODRL 2.2 |
| `not_delegable?` | — | `odrl:Duty` / `odrl:Constraint` | ODRL 2.2 |
| a to-many relationship | a navigation route | `hydra:Link` property on the node | Hydra Core |
| an operation's outcomes | (none today) | `hydra:possibleStatus` → `hydra:Status` | Hydra Core |

## Layer 1 — the operation's class, and what it is a subclass of

Each affordance renders as a `hydra:Operation` whose `@type` names a class
minted for the action. Where the domain **declared** a role, that class is a
subclass of the published term, so the chain runs from the operation up
schema.org's own hierarchy:

```
vocab#Order/confirmAction  ⊑  schema:ConfirmAction  ⊑  schema:Action
```

The axiom lives in the `ApiDocumentation`'s `@included`, which is fetched once
and cached — a superclass holds in every state and for every actor, so
repeating it on each response would state a stable fact in the document whose
job is the unstable one.

This replaces `schema:potentialAction`, which said the operation *has* an
action. The class says it **is** one, which is the accurate reading for a node
that is the offer to act — and `potentialAction` is defined with domain `Thing`
and range `Action`, making an `Operation` an awkward subject for it. What the
declaration used to look like:

```json
"schema:potentialAction": {"@type": "https://schema.org/ConfirmAction"}
```

and what it looks like now, split between the two documents:

```json
// on the node — the operation states its own class
{ "@type": ["Operation", "vocab#Order/confirmAction"], "hydra:method": "PATCH" }

// in the ApiDocumentation's @included — what that class is
{ "@id": "vocab#Order/confirmAction", "@type": "owl:Class",
  "rdfs:label": "confirm",
  "rdfs:subClassOf": { "@id": "https://schema.org/ConfirmAction" } }
```

Both answer one question — *what is this operation for?* — and it is the one
question Hydra has no term for. The second form also answers *which operation is
this?*, which the first left to a bare string.

### Why the role needs saying, and nothing else does

An operation already states where, how, what in and what out:

| question | stated by |
|---|---|
| **which operation** | the minted class in `@type` |
| **where** | `ah:href` |
| **how** | `hydra:method` |
| **what you send** | `hydra:expects` |
| **what comes back** | `hydra:returns` |
| **what it is *for*** | — nothing in Hydra |

The gap is real. `hydra:Operation` describes a method, an input and an output,
but never the operation's purpose, so a client asking *"which of these is the
save?"* has only the action's **name** to match on — and a name belongs to the
domain, which may rename `validate` to `check` or `prüfen` tomorrow. A
schema.org Action subtype states the role in a published vocabulary instead, so
the contract is the API's rather than a convention two parties happen to share.

**A role the method already implies states nothing**, so a superclass is
declared only where a `semantic_action` supplied one. Measured on the fixture
domain when the role was still a key, inferring from the method made **139 of
146** `potentialAction` nodes a mechanical restatement of `hydra:method` on the
same node. The 7 survivors are the ones carrying information: `CheckAction`,
`ConfirmAction`, `ShipAction`, and this library's own `ah:SaveAction` /
`ah:RunAction` for roles no published vocabulary has a term for.

An action with no declared role therefore has **no** superclass. There is
deliberately no `owl:Thing` default either: every OWL class is trivially a
subclass of it, so the triple entails nothing.

### There is no `schema:target`

It would carry a `urlTemplate`, an `httpMethod` and a `contentType` — all three
already stated, per the table above, and the content type belonging to the API
rather than to one operation. **Hydra core mints no target-URL term, so this
package mints `ah:href`** — carried by every operation, since a client cannot
invoke anything without a URL. What `schema:target` would add on top of that is
a whole second model of an invocation: it ranges over `schema:EntryPoint`, which
drags `EntryPointDescription`, `actionApplication` and `httpMethod` with it, for
the sake of one URL `ah:href` already states.

It would also be ill-typed. schema.org defines `urlTemplate` as *"an url
template (RFC6570) that will be used to construct the target of the execution of
the action"*, and a **Plug** route is not one. RFC 6570 gives `:` no meaning, so
an expander handed `/orders/:id/confirm` finds **zero** variables and returns
the string unchanged — a client following it would request a literal `:id`.
Verified against a real expander rather than assumed.

Teaching a redundant statement to spell itself correctly is not worth doing, so
the statement is not emitted at all.

### URL templates: only where a URL must be *constructed*

`hydra:IriTemplate` remains, for GETs taking query arguments — 7 in the fixture
domain:

```json
{"@type": "IriTemplate",
 "hydra:template": "/domain/eager_prepare/search{?query}",
 "hydra:variableRepresentation": "BasicRepresentation",
 "hydra:mapping": [
   {"@type": "IriTemplateMapping", "hydra:variable": "query",
    "hydra:property": {"@id": "…#eager_prepare/query"}, "hydra:required": false}]}
```

A query string is the one thing a client cannot discover by following a link:
nothing else says `?query=` exists or that it is optional.

**Path variables are a different matter.** A member URL, a sub-action URL and a
relationship URL are all *given* — a collection lists its members with full
`@id`s, a record's operations carry concrete `ah:href` URLs, a relationship is a
`hydra:Link` you follow. A client never holds ids without a URL, so a template
describing `/entry/{id}` would restate an address the document already provides.
Templates are for constructing URLs, and these need no construction.

A path variable does still appear in `hydra:template` when the route has one,
because the string must be a complete URL to expand at all. It is described in
`hydra:mapping` only when it is not already one of the operation's own
arguments — a route whose path segment shares a name with an argument
(`/multi_read/{id}/by_id{?id}`) would otherwise be described twice, once
required and once not.

### Declaring a role

**Only an explicit `semantic_action`.** A subtype is never guessed from an
action's name, which would risk emitting a schema.org type that does not exist,
and no longer falls back to one derived from the HTTP method.
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

- The node carries an **`odrl:permission` list** — the ODRL way to attach
  permissions to a policy — with one `odrl:Permission` per granted affordance.
  Each has an `odrl:action` (`odrl:read` for GET, `odrl:modify` for a write,
  `odrl:delete` for a destroy, `odrl:use` for create/generic — all defined in the
  ODRL Common Vocabulary) and an `odrl:target` referencing the node.
- **Permission-only. No `odrl:Prohibition`.** A denied action is not in the
  envelope at all, so we have nothing to base a prohibition on — and emitting one
  would leak "what you cannot do," which the present-if-allowed design
  deliberately withholds. The honest ODRL projection of a fail-closed surface is
  a permission list, not a permission/prohibition pair. Two actors reading the
  same record therefore receive *different* permission lists.
- `not_delegable?` → the permission carries an **`odrl:duty`** whose action is
  `odrl:obtainConsent`: the permission is discharged only by a credential that
  commits.
- **`odrl:assignee` is omitted unless the actor has a stable IRI.** The plug
  resolves an opaque actor; when it exposes no dereferenceable identity there is
  nothing honest to put there, so the permission states the action and target and
  leaves the assignee implicit (the bearer of the request).

```json
"odrl:permission": [
  {
    "@type": "odrl:Permission",
    "odrl:target": { "@id": "/orders/1" },
    "odrl:action": { "@id": "odrl:modify" }
  },
  {
    "@type": "odrl:Permission",
    "odrl:target": { "@id": "/orders/1" },
    "odrl:action": { "@id": "odrl:use" },
    "odrl:duty": [ { "@type": "odrl:Duty", "odrl:action": { "@id": "odrl:obtainConsent" } } ]
  }
]
```

## Layer 3 — fuller Hydra (links and status)

Uses more of the vocabulary already grounded, no new namespace:

- **`hydra:Link` for relationships.** A public to-many relationship already
  derives a `:related` route (`/base/:id/<name>`). On a record node it is surfaced
  as a property keyed by the relationship name whose value references the related
  collection (`{"@id": …/:id/<name>, "@type": "Collection"}`), and in the
  `ApiDocumentation` the class declares that property with `hydra:property`
  typed **`hydra:Link`** — so a client knows the key is a followable link, not a
  literal, and can walk the graph as first-class links rather than only via
  navigation.
- **`hydra:possibleStatus`.** Each operation in the `ApiDocumentation` advertises
  the statuses it may return, as `hydra:Status` nodes (`hydra:statusCode` +
  `hydra:title`) derived from the gate chain: `403` when the resource has
  authorizers, `422` for a write (validation may fail), `404` for a
  member-targeted operation. Actor-independent — the catalogue counterpart to the
  node's live gating, consistent with `expects`/`returns`.

## Sources (verified)

- **ODRL 2.2 vocabulary (W3C Recommendation):**
  `https://www.w3.org/ns/odrl/2/ODRL22.json` and `https://www.w3.org/TR/odrl-vocab/`.
  Namespace `http://www.w3.org/ns/odrl/2/`. Confirmed classes `Permission`,
  `Prohibition`, `Duty`, `Constraint`; properties `permission` (attaches a
  Permission to a Policy), `action`, `target`, `assignee`, `assigner`,
  `constraint`, `duty`. Action terms confirmed present: `use` (Core), and from
  the Common Vocabulary `read` ("obtain data from the Asset"), `modify` ("change
  existing content"), `delete` ("permanently remove all copies") — so the CRUD
  mapping needs no invented terms.
- **schema.org Actions:** `https://schema.org/docs/actions.html`,
  `https://schema.org/potentialAction`.
  Confirmed `potentialAction` (domain `Thing`, range `Action`); `Action` →
  `target` with `urlTemplate` / `httpMethod` / `contentType`;
  CRUD subtypes `ReadAction` / `CreateAction` / `UpdateAction` / `DeleteAction`
  and domain verbs (`ConfirmAction`, `CancelAction`, `ShipAction`, …).
  Of these, **only the declared domain verbs are used**, and as *superclasses*
  rather than as a `potentialAction` value: that property's domain is `Thing`
  and its range `Action`, so it says an operation *has* an action where what is
  true is that the operation **is** one. `target` restates facts the operation
  already carries — and where it would *not* (a sub-action's own URL) it drags
  an `EntryPoint`/`EntryPointDescription` reading along that does not apply, so
  `ah:href` carries that URL instead. A CRUD subtype restates `hydra:method`.
  `urlTemplate`'s own definition names RFC 6570 — worth recording, since the
  value emitted was a Plug route for as long as the term was present.
- **IANA Link Relations:** the registered `edit` relation (RFC 5023) for a
  resource's update/delete affordance; no registered relation for domain verbs
  (`approve`, `confirm`), which is why each gets a class of its own under this
  API's vocabulary.
- **IANA HTTP Method Registry:** the `hydra:method` token values.
- **Hydra Core Vocabulary:** `hydra:Link`, `hydra:possibleStatus`,
  `hydra:Status` — as verified in `hydra-conformance-notes.md`.

## A minted property IRI is the fallback, not the default

An attribute with no `semantic_property` gets an IRI minted under the API's own
vocabulary. That satisfies the letter of "everything is an IRI", and **nothing
outside the API knows the term** — which is most of the point of having one.

So look for a published term first. `schema:creativeWorkStatus`, for instance,
fits a lifecycle-status attribute exactly: domain `CreativeWork`, range
`DefinedTerm` or `Text`, defined as *"the status of a creative work in terms of
its stage in a lifecycle"*, and explicitly allowing an organisation's own
vocabulary of stages. A minted `vocab#course/status` says the same thing to
nobody.

The mechanism is already there and is the same one used for a resource and an
action:

| what | declaration |
|---|---|
| a resource | `semantic_type "Course"` |
| an attribute | `semantic_property :status, "creativeWorkStatus"` |
| an action | `semantic_action :confirm, "ConfirmAction"` |

Mint one when no published term fits, which is often. Mint one **because you did
not look**, and the document is readable only by something written against this
API — which is the state the whole layer exists to get out of.

## Design principle

Same rule as the noun layer, applied throughout: **the native/`ah:` term stays
the stable identifier; a standard vocabulary is added alongside so a client that
speaks the standard understands the affordance without understanding
`ash_hateoas`.** Nothing here is authored per resource beyond the optional
`semantic_action` override — every annotation is derived from what the action,
its type, its policies, and its state machine already declare.
