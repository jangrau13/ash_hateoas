defmodule AshHateoas.Resource.Info do
  @moduledoc """
  Introspection for the `hateoas` section.

  The arity-1 readers are **generated** by `Spark.InfoGenerator`:

    * `hateoas/1` — every entity in the section (exclusions and overrides)
    * `hateoas_enabled?/1` — the predicate option, returning a bare boolean
    * `hateoas_warn_on_missing_authorizers?/1`
    * `agentic_hateoas/1` — every entity in the R10 section

  Note the InfoGenerator asymmetry: predicate options (ending in `?`) get one
  bare-value function and no bang variant, while non-predicate options get both
  a `{:ok, v} | :error` reader and a `!` variant. Both of ours are predicates.

  Everything below is hand-written on top, following the `AshStateMachine.Info`
  precedent — the generated functions cover arity 1, and anything that filters
  or takes an argument is written out.

  Every function accepts a resource module, a record, or a DSL map, because
  `Spark.Dsl.Extension.get_entities/2` and `get_opt/5` do.
  """

  use Spark.InfoGenerator,
    extension: AshHateoas.Resource,
    sections: [:hateoas, :agentic_hateoas]

  alias AshHateoas.Resource.{Exclusion, Method, NotDelegable, Override, Unrouted}

  @doc """
  The HTTP method declared for a generic action, or `nil` if none is.

  `nil` means the route deriver assumes POST — see
  `AshHateoas.Resource.Transformers.DeriveActionRoutes`.
  """
  @spec method(Ash.Resource.t() | map(), atom()) :: atom() | nil
  def method(resource_or_dsl, action) do
    resource_or_dsl
    |> hateoas()
    |> Enum.find_value(fn
      %Method{action: ^action, method: method} -> method
      _ -> nil
    end)
  end

  @doc """
  Action names this resource keeps off the HTTP surface entirely.

  Distinct from `exclusions/1`: an exclusion is routed but unadvertised, an
  unrouted action has no route at all.
  """
  @spec unrouted(Ash.Resource.t() | map()) :: [atom()]
  def unrouted(resource_or_dsl) do
    resource_or_dsl
    |> hateoas()
    |> Enum.filter(&match?(%Unrouted{}, &1))
    |> Enum.map(& &1.action)
  end

  @doc """
  Action names this resource excludes from advertisement (R2).
  """
  @spec exclusions(Ash.Resource.t() | map()) :: [atom()]
  def exclusions(resource_or_dsl) do
    resource_or_dsl
    |> hateoas()
    |> Enum.filter(&match?(%Exclusion{}, &1))
    |> Enum.map(& &1.action)
  end

  @doc """
  Per-action overrides as `%{action_name => [href: ...]}` (R2).

  Shaped for `AshHateoas.affordances/3`'s `:overrides` option.
  """
  @spec overrides(Ash.Resource.t() | map()) :: %{atom() => keyword()}
  def overrides(resource_or_dsl) do
    resource_or_dsl
    |> hateoas()
    |> Enum.filter(&match?(%Override{}, &1))
    |> Map.new(fn %Override{} = override ->
      {override.action, Enum.reject([href: override.href], fn {_k, v} -> is_nil(v) end)}
    end)
  end

  @doc """
  Action names only a committing credential may execute (R10).

  Unlike `unrouted/1` and `exclusions/1`, this subtracts nothing: the actions
  stay routed and stay advertised. It is read twice — by the descriptor, to flag
  the affordance, and at invocation, to decide whether to refuse.
  """
  @spec not_delegable(Ash.Resource.t() | map()) :: [atom()]
  def not_delegable(resource_or_dsl) do
    resource_or_dsl
    |> agentic_hateoas()
    |> Enum.filter(&match?(%NotDelegable{}, &1))
    |> Enum.map(& &1.action)
  end

  @doc """
  Whether `action` may only be executed by a committing credential (R10).
  """
  @spec not_delegable?(Ash.Resource.t() | map(), atom()) :: boolean()
  def not_delegable?(resource_or_dsl, action) do
    action in not_delegable(resource_or_dsl)
  end

  @doc """
  Whether `resource` carries this extension at all.

  The JSON:API transform is a no-op for resources that do not, so this is the
  check that keeps affordances opt-in per resource.
  """
  @spec extension?(Ash.Resource.t()) :: boolean()
  def extension?(resource) when is_atom(resource) do
    AshHateoas.Resource in Spark.extensions(resource)
  rescue
    _ -> false
  end

  def extension?(_resource), do: false

  @doc """
  The options `AshHateoas.affordances/3` should be called with for this
  resource — its exclusions and overrides, ready to merge with caller options.
  """
  @spec affordance_opts(Ash.Resource.t() | map()) :: keyword()
  def affordance_opts(resource_or_dsl) do
    [
      exclude: exclusions(resource_or_dsl),
      overrides: overrides(resource_or_dsl)
    ]
  end
end
