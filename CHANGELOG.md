# Changelog

## Unreleased

Initial release: authorization- and state-aware HATEOAS affordances for Ash,
served natively as a Hydra / JSON-LD API.

### The transport

- `AshHateoas.Hydra.Plug` serves an Ash domain as `application/ld+json`. It
  reads and writes every routed resource itself and renders JSON-LD keyed to the
  Hydra Core Vocabulary (`http://www.w3.org/ns/hydra/core#`):
  - `GET /` — the `hydra:ApiDocumentation` entry point (reachable types + links);
  - `GET <doc_path>` — the full `ApiDocumentation` (`supportedClass` with
    `supportedProperty` and `supportedOperation`);
  - `GET` member/collection — the resource node with its actor- and state-gated
    `hydra:operation`s, or a `hydra:Collection` with `member`, `totalItems` and a
    `hydra:PartialCollectionView` for paginated reads;
  - `POST`/`PATCH`/`DELETE`/generic — decodes the JSON-LD body, runs the action,
    and renders the new state or a `hydra:Error`.
  - Every response advertises the API documentation via a `Link` header.

### Affordances

- Affordances are **derived, never authored** — from a resource's actions,
  routes, policies and (where present) `AshStateMachine` transitions. Each
  becomes a `hydra:Operation`; a write's inputs become `hydra:SupportedProperty`
  entries under `hydra:expects`, a query read's become a `hydra:IriTemplate`.
- The affordance set is resolved per request via `Ash.can?/3` — the same check
  the endpoint enforces on invocation — plus the state gate where a state machine
  is present.
- `AshHateoas.affordances/3` exposes the transport-neutral envelope directly.

### Routes

- Every action is routed by default; `unrouted :action` keeps one off the
  surface, verified against the action list so a rename fails the build.
- `base` is derived from the domain's short name and the resource's `type`, and
  `type` is inferred from the module name when undeclared. Neither is pluralised.
- Primaries take the REST verbs; everything else is addressed by name under
  `/:id/<action>`. A `get?: false` read derives a collection index at `/<name>`;
  a generic action's method is assumed `POST` and warned about, correctable with
  `method :action, :get`.
- Reactor compensation actions and AshAuthentication's own actions are skipped
  automatically.

### Well-known vocabularies (schema.org)

- `semantic_type "Person"` on a resource advertises a well-known type alongside
  its own class: each record node carries both (`"@type": ["…#Person",
  "https://schema.org/Person"]`) and the `hydra:Class` declares an
  `owl:equivalentClass`. A bare token resolves against schema.org; an absolute
  IRI is used verbatim.
- `semantic_property :additional_name, "additionalName"` maps an attribute to a
  well-known property IRI — the node `@context` binds the flat key to it and the
  `ApiDocumentation` advertises the property by that IRI. A verifier fails the
  build when it names a missing attribute.
- **`mix ash_hateoas.gen.schema_org Person --domain MyApp.People`** generates a
  resource from a schema.org type fetched live: one attribute + `semantic_property`
  per property. A property whose range is another type is generated as:
  - a real **`belongs_to`** when the domain already serves that type (or it is a
    self-reference) — an internal, in-process relationship; or
  - an **`AshHateoas.Type.ResourceLink`** attribute otherwise — an external,
    followable URL.

  The generator scans the domain to decide, prompts only on genuine ambiguity
  (`--yes` defaults ambiguous to external), and `--internal Organization,Place`
  forces named types internal.
- A `AshHateoas.Type.ResourceLink` value renders as a JSON-LD reference node
  (`{"@id": url}`); internal vs external is the `@id`'s host, not a separate flag.

### DSL

- A `hateoas` section carrying `type`, `base`, `semantic_type`, and the
  override-only entries `exclude`, `override`, `unrouted`, `method`,
  `semantic_property`, plus `enabled?`.
- An `agentic_hateoas` section with `not_delegable :action` — an action that
  stays advertised (flagged `ah:notDelegable`) but is executed only by a
  credential a configured `commit_authority` deems committing. A refusal is a
  `403` `hydra:Error` carrying, under `ah:projection`, what the action would have
  done — read from the transitions and gate chain, never executed.
