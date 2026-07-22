defmodule AshHateoas do
  @moduledoc """
  Authorization- and state-aware HATEOAS affordances for Ash.

  One backbone computes *what may be done next* for a given record (or resource)
  and actor. This package renders that result as JSON:API — affordances become
  named `links.<action>` objects, published under a documented profile so that
  clients which have never seen this code can act on them.

  Affordances are derived from what a resource already declares — its actions,
  its JSON:API routes, its policies, and its `AshStateMachine` transitions where
  present. A resource author writes no affordances; the optional `hateoas` DSL
  section carries deviations only.

  See `REQ.md` for the full requirement set.
  """

  alias AshHateoas.Backbone

  @doc """
  Affordances available to `actor` right now.

  Accepts either a **record** — "what can I do with this?", with the state gate
  applied — or a **resource module** — "what can I do with this type?", the
  collection-level and cold-start case, where no state gate applies (R9).

  Returns a map of action name to `AshHateoas.Affordance`, empty when nothing
  survives the gates.

  ## Options

    * `:domain` — the Ash domain. Required unless the resource declares one;
      routes are domain-level, so a resource-only lookup is insufficient.
    * `:domains` — additional domains to read routes from. Defaults to `[domain]`.
    * `:tenant` — passed through to `Ash.can?/3`.
    * `:exclude` — action names to drop (R2).
    * `:overrides` — `%{action_name => [href: "..."]}` (R2).
    * `:gates` — override the gate chain. Defaults to authorization only;
      the state gate is added by the resource extension where applicable.

  ## Examples

      iex> AshHateoas.affordances(document, actor, domain: MyApp.Docs)
      %{approve: %AshHateoas.Affordance{method: :post, ...}}

      iex> AshHateoas.affordances(MyApp.Document, actor, domain: MyApp.Docs)
      %{create: %AshHateoas.Affordance{method: :post, ...}}
  """
  @spec affordances(struct() | module(), term(), keyword()) :: Backbone.envelope()
  def affordances(record_or_resource, actor, opts \\ [])

  def affordances(record, actor, opts) when is_struct(record) do
    Backbone.for_record(record, actor, opts)
  end

  def affordances(resource, actor, opts) when is_atom(resource) do
    Backbone.for_resource(resource, actor, opts)
  end
end
