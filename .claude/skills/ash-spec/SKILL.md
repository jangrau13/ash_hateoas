---
name: ash-spec
description: Author and review Ash Framework (Elixir) code — resources, domains, actions, relationships, calculations, aggregates, policies, validations, changes, embedded types, and code interfaces. Use whenever adding, editing, or reviewing any .ex file under ash-spec/lib. Encodes the official Ash usage rules plus this repo's house conventions (one module per file, domain-prefixed tables, English identifiers, UUID foreign keys, domain-meaning link resources). Load before writing the first line of Ash DSL.
---

# Working with Ash in `ash-spec/`

**Follow the official Ash usage rules first.** They are the source of truth and
are copied verbatim into `rules/`, one file per topic — read the relevant one
before writing DSL you're unsure about:

- `rules/ash/` — core Ash, one file per topic: `actions.md`, `relationships.md`,
  `calculations.md`, `aggregates.md`, `code_interfaces.md`, `code_structure.md`,
  `authorization.md`, `data_layers.md`, `querying_data.md`, `query_filter.md`,
  `exist_expressions.md`, `generating_code.md`, `migrations.md`, `testing.md`
  (+ `_overview.md`). Validations & changes live in `actions.md`.
- `rules/ash_postgres/` — AshPostgres, one file per topic: `configuration.md`,
  `foreign_keys.md`, `check_constraints.md`, `best_practices.md`,
  `custom_indexes.md`, `custom_sql_statements.md`, `migrations.md`,
  `multitenancy.md`, `advanced_features.md` (+ `_overview.md`).
- `rules/ash_json_api/usage-rules.md` — AshJsonApi: domain/resource extensions,
  `json_api` blocks, `type`, route types (get/index/post/patch/delete/related/
  relationship), filtering/sorting/pagination/includes.
- `rules/ash_authentication/usage-rules.md` — AshAuthentication: strategies
  (password, magic_link, api_key, OAuth2), tokens, Secrets, add-ons
  (confirmation, log-out-everywhere), policies, custom auth actions.
- `rules/ash_ai/usage-rules.md` — AshAI: vectorization/embeddings, AI tools,
  prompt-backed actions (structured outputs), MCP server.
- `rules/ash_phoenix/` — AshPhoenix. **The top-level `usage-rules.md` is only an
  index; the actual rules are the six files in `usage-rules/`** —
  `form_integration.md` (the `AshPhoenix.Form` life cycle: `validate/3` →
  `submit/2`, `form_to_*` code interfaces), `nested_forms.md`,
  `union_forms.md`, `error_handling.md`, `debugging_form_submissions.md`,
  `best_practices.md`. Read the topic file, not the index — the index says
  nothing on its own.
- `rules/usage_rules/` — the `usage_rules` dev tool that MANAGES all of the
  above (`usage-rules.md`) plus curated general `elixir.md` and `otp.md` rules.
  Consult `elixir.md`/`otp.md` before writing non-Ash Elixir; use
  `mix usage_rules.docs <Module>` / `mix usage_rules.search_docs <query>` to
  look up dependency docs instead of guessing.
- `rules/reactor/usage-rules.md` — Reactor (the saga orchestrator `Ash.Reactor`
  builds on): steps, `map`/`switch`/`compose`/`guard`/`recurse`, halt/resume,
  `compensate`/`undo`. Read before touching `lib/aiscribo/content/workflows/`.
- `rules/book/` — the full *Ash Framework* book (Le & Daniel, PragProg P1.0)
  as per-chapter markdown with an `index.md`. **Not** a usage-rules file (don't
  `usage_rules.sync` it). Use it for the *narrative* "how/why" when a usage rule
  is too terse — worked examples of resources, actions, calculations, policies,
  APIs, auth, testing, nested forms, PubSub. It teaches via a demo app (*Tunez*),
  so translate its idioms to this repo's model; when it and a `usage-rules.md`
  disagree, the usage rule wins (it tracks the pinned version).

**These rule files are generated, not hand-maintained.** `usage_rules` is baked
into `mix.exs` (`usage_rules/1` config + `{:usage_rules, …}` / `{:igniter, …}`
dev deps). Regenerate the whole `rules/` tree from the pinned package versions
with:
```bash
cd ash-spec && mix usage_rules.sync
```
Don't hand-edit files under `rules/` — bump the dep and re-sync.

**Planned extensions (rules bundled; not yet wired into `lib/`).** When
implementing, follow the two rule files above:
- *AshAuthentication* on `Identity.User` — password (email + hashed_password),
  magic link, API key (for the internal/service callers the published-doc
  policies reference), and OAuth2 (Google + GitHub). Adds `Identity.Token`,
  `Identity.ApiKey`, `Identity.UserIdentity`, and a `Secrets` module; mark all
  credentials `sensitive?: true`; never hardcode secrets.
- *AshJsonApi* on the public read surface (Article, Agenda, Author, Region) —
  domain `json_api` routes + per-resource `type`; keep the authoring/draft side
  internal.
- *AshAI* where the content system needs LLM surfaces — prompt-backed actions
  for generation/extraction, vectorized search over published Articles/Agendas.

### Per-org / per-task LLM assignment (implemented)

The "which LLM for which org/task" routing lives entirely in Ash:
- **Task axis** = `Aiscribo.Ai.ChatRole` (`:thinking`/`:fast`/`:agentic`/`:vision`).
- **Config** = `Identity.TierModelConfig` (per tier+role) and
  `Identity.OrganizationModelConfig` (per org+role) — provider/model/thinking_budget.
- **Resolution** = `Aiscribo.Ai.ModelResolver.resolve!/2` — layered
  `default ← tier ← org`, per-role, fail-soft, returns a `ModelSpec`.
- **Invocation** = a prompt-backed action whose model is a REMOTE function ref
  that reads the actor's org and resolves it:
  ```elixir
  action :suggest_lead, :string do
    argument :text, :string, allow_nil?: false
    run prompt(&Aiscribo.Ai.resolve_req_llm/2, tools: false, prompt: {"…system…", "…<%= @input.arguments.text %>…"})
  end
  ```
  ash_ai's model arg must be `&Mod.fun/2` (an inline closure can't be escaped into
  the DSL). ash_ai 0.7 uses **ReqLLM** — the model spec is a `"provider:model"`
  string (`ModelSpec.to_req_llm/1`), not a LangChain chat model.
- **Production note:** ash_ai calls ReqLLM directly and does NOT provide the
  `@aiscribo/llm` guarantees (PII tokenisation, ß→ss normalisation, OpenRouter
  fallback, OTel). Bridge to `@aiscribo/llm` (custom ReqLLM provider or a generic
  action) if those are required; the persistence-side SwissGerman validation
  still guards against a leaked ß reaching the DB.

### Observability — OpentelemetryAsh (wired)

Tracing is Ash-native: `config :ash, :tracer, [OpentelemetryAsh]` in
`config/config.exs` turns every action / flow / custom span Ash runs into an
OpenTelemetry span. This is the same collector the rest of the monorepo ships
to; the prompt-backed `suggest_lead` action and its model resolution are traced
like any other action.

- Dep is `{:opentelemetry_ash, "~> 0.1"}` plus its runtime companions
  `opentelemetry_api` + `opentelemetry_process_propagator`. In prod the host app
  supplies the OTel SDK + exporter (dev/test-scoped in the library itself).
- Span set is trimmed to the library's recommended
  `trace_types: [:custom, :action, :flow]` (`config :opentelemetry_ash`) — see
  `Ash.Tracer` for the full list.
- `opentelemetry_ash` ships **no** `usage-rules.md`, so it is deliberately NOT in
  the `usage_rules` skills list in `mix.exs` (`mix usage_rules.sync` would 404 on
  it). It's a config-only integration — nothing to regenerate.

When a house convention below and a general habit conflict, the house convention
wins. When the Ash usage rules and anything here conflict, **stop and ask** —
don't silently diverge from the official rules. Read documentation *before*
using a feature; do not assume prior knowledge of the framework.

---

## House rules (enforced across the whole `lib/` tree)

1. **One module per file.** Never two `defmodule`s in one `.ex`. Group related
   value/behaviour modules in a **subfolder** (`changes/`, `calculations/`,
   `validations/`, `embedded/`), one file each.

2. **File name = module name.** `article_type.ex` ⇒ `Aiscribo.Taxonomy.ArticleType`.
   Subfolders are organizational only and do **not** add a namespace segment
   (`content/embedded/content_check.ex` ⇒ `Aiscribo.Content.ContentCheck`).

3. **Table names are domain-prefixed and match the file:**
   `table "<domain>_<file_basename>"` — `content_article`, `identity_membership`,
   `taxonomy_topic`, `geography_region`, `publishing_ad_type`. Every AshPostgres
   resource needs `postgres do table … repo Aiscribo.Repo end` (both required).

4. **English only.** Modules, files, tables, attributes — all English. No German
   identifiers in code (`ArtikelTyp`→`ArticleType`, `Thema`→`Topic`,
   `autor`→`author`, `ort_names`→`place_names`). Any legacy name goes in the
   moduledoc as a `(← Supabase \`X\`)` lineage note and in `MAPPING.md`, never in
   an identifier.

5. **UUID primary keys + UUID foreign keys.** `uuid_primary_key :id`; let
   `belongs_to` generate the `<name>_id` UUID FK. **Never** thread business
   strings (`uuid`, `slug`, `slot_key`) through `source_attribute` /
   `destination_attribute`. Public identifiers (`uuid`, `slug`) are `identity`
   lookups, never relationship keys. Join resources use two
   `belongs_to … primary_key?: true` (composite PK) — the join-resource idiom.

6. **Domain-meaning names for link resources.** A join is a real domain concept:
   `RoleAssignment`, `Membership`, `Entitlement`, `Placement`, `AdTargeting`,
   `SectionEntry`, `QuestionSlot`, `PlaceInRegion` — never mechanical `AB`
   concatenations (`UserRole`, `RubrikThema`).

7. **`many_to_many` keeps its `through` join resource** — the required Ash idiom
   for N:N, not a hack. Model genuine 1:N as `has_many`/`belongs_to`.

8. **Use the right layer, prefer built-ins over custom modules.**
   - Data-shape rules ⇒ **validations** (built-in `present`/`one_of`/`compare`/
     `match`, or a custom `Ash.Resource.Validation`), not policies. Custom
     validation modules **implement `atomic/3`** when the rule can be a DB
     expression (usage rule: "Make validations atomic when possible").
   - "Who may act" ⇒ **policies** with built-in checks (`actor_attribute_equals`,
     `relates_to_actor_via`, `expr(...)`), preferably role-based. Avoid custom
     `SimpleCheck` modules when a built-in expresses it.
   - Reusable transforms ⇒ **changes**; conditional query shaping ⇒ **preparations**.

9. **Prefer domain code interfaces and named actions.** Every resource is
   registered in its `lib/aiscribo/<domain>.ex` `resources` block with
   `define :name, action: :x, get_by: […]`. Prefer specific named actions over
   generic CRUD; put business logic inside actions, not external modules.

10. **Swiss German copy rule** on user-facing German prose attributes
    (`title`/`lead`/`text`/`description`): validate with
    `Aiscribo.Content.Validations.SwissGerman` — `ss` never `ß`; umlauts ä/ö/ü stay.

11. **Content drafts extend the `Content.Draft` base resource**, not
    `Ash.Resource` directly. `use Aiscribo.Content.Draft, published:, required_fields:,
    publish_change:, signing:, republish_rule:, revise_change: (optional)` — the
    official Ash base-resource pattern (registered in
    `config :aiscribo, base_resources: […]`). It derives the whole publish
    lifecycle from a SINGLE `required_fields` list (kills the old 3× repeat) and
    the sign/re-publish invariants. The parts that differ per type are MODULES,
    not settings:
    - **Signing** — a `Content.Signing.Strategy` (`hash_fields/0` + `checks/0`);
      the `sign` action stamps `signed_content_hash`/`signed_at`/`signed_checks`
      via `Changes.SignDraft`; `signed?` + `changed_since_sign?` calcs detect a
      stale signature (shared `Signing.ContentHash` used by both the stamp and
      the check — never two hand-synced hash lists, the monorepo's fragile spot).
    - **Re-publish** — a `Content.Republish.Rule` (`republishable?/2`), consulted
      by the `publish` gate (`Validations.ReadyToPublish`) only when a published
      copy already exists.
    Adding a new content type = new draft `use`ing the base + a Signing strategy
    + a Republish rule + the publish/revise change modules. Don't re-hand-roll the
    publishable?/blockers/sign/publish cluster.

12. **Bot creation flows are `Ash.Reactor` pipelines** in
    `lib/aiscribo/content/workflows/` (see `WORKFLOWS.md`), each a generic
    `create_via_workflow` action on its draft resource. Human-in-the-loop = a
    step returning `{:halt, …}`; the ADAPTIVE interview loops via the RESUME
    CYCLE, not `recurse` (a halt inside `recurse` errors — recurse is for
    compute-convergence loops). RT-Direkt/Studio = `where`-guarded parallel
    generate steps on a tier-resolved mode. Read `rules/reactor/usage-rules.md`
    before editing these.

---

## The five domains

`Content`, `Identity`, `Taxonomy`, `Geography`, `Publishing`. Each lives in
`lib/aiscribo/<domain>.ex` with a `resources do … end` block registering every
resource and its code interfaces. New cross-boundary entity ⇒ add the resource,
register it, define a code interface, add a `MAPPING.md` row.

---

## Workflow when you touch this tree

0. **Read the usage rule IN FULL before writing DSL — never from memory.** The
   single biggest failure mode here is inventing a DSL option/entity that "feels
   right" (`filter` inside a `calculate` block, a made-up flag) and only finding
   out at compile time. Before writing an unfamiliar DSL construct: read the
   whole `rules/*.md` section, and if it doesn't show the exact option you're
   about to use, confirm it exists in the entity schema
   (`deps/ash/lib/ash/resource/**/<thing>.ex` → the `@schema` keyword list, or
   `mix usage_rules.docs <Module>`) — do NOT guess. If the rule doesn't mention a
   capability, that usually means the concern belongs elsewhere (e.g. filtering a
   calculation is a QUERY-TIME concern, not a resource-block one). Reaching for
   code before the rule is the anti-pattern to avoid.
1. Read the relevant `rules/*.md` section for the DSL you're writing.
2. Write the resource following the house rules above.
3. Register it in its domain module with a code interface.
4. **Compile — this is the real check.** DSL errors, unloaded aggregates in
   policies, calculation-vs-attribute mistakes, and reciprocal-FK mismatches only
   surface at compile time:
   ```bash
   export PATH="/Users/jan/.elixir-install/installs/elixir/1.18.0-otp-27/bin:/Users/jan/.elixir-install/installs/otp/27.1.2/bin:$PATH"
   cd ash-spec && mix compile
   ```
5. Update `MAPPING.md` if you added an entity.

## Compile-time traps (don't repeat)

- **`attribute_equals(:calc, …)` is wrong for a calculation** — it reads a
  changeset attribute, gets `nil`, and always errors. Validate the underlying
  attributes (`present([:title, :text])`) or use a custom validation.
- **`actor_attribute_equals(:agg, …)` on an aggregate** — aggregates aren't
  loaded on the actor; the check silently fails. Use
  `authorize_if expr(exists(^actor(:roles), name == "Internal"))`.
- **`actor/1` / `arg/1` are not imported inside inline `validate` built-ins** —
  put actor-comparing logic in a custom `Ash.Resource.Validation` module.
- **`where` takes a list, not repeated clauses** — `where [present(:a), present(:b)]`.
- **`has_one`/`many_to_many` reciprocity needs a real FK on one side** — set
  `destination_attribute` explicitly when Ash can't infer it.
- **`Ash.Policy.Authorizer` needs a SAT solver dep** — `{:simple_sat, "~> 0.1"}`.
- **Enum-ish string attributes** (`status`, `tier`, `ad_type`) — add
  `constraints one_of: […]` and a Postgres `check_constraint` to enforce the
  invariant at the DB, per the AshPostgres best-practices rule.
- **A `calculate` block has NO `filter` entity** — `filter expr(...)` inside
  `calculate … do … end` is a compile error. The valid `calculate` options are
  exactly: `name, type, async?, constraints, calculation, description, public?,
  sensitive?, load, allow_nil?, filterable?, sortable?, field?, multitenancy` (+
  nested `argument`). Bounding an expensive (Elixir-side module) calculation is a
  QUERY-TIME concern: the caller filters on a cheap `expr(...)` calc first, then
  loads the module calc on the narrowed set. Prefer an expression calc (pushed to
  SQL) over a module calc whenever the logic can be an expression.