defmodule AshHateoas.Resource.Info do
  @moduledoc """
  Introspection for the `hateoas` section.

  The arity-1 readers are **generated** by `Spark.InfoGenerator`:

    * `hateoas/1` — every entity in the section (exclusions and overrides)
    * `hateoas_enabled?/1` — the predicate option, returning a bare boolean
    * `hateoas_warn_on_missing_authorizers?/1`
    * `agentic_hateoas/1` — every entity in the not-delegable section

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

  alias AshHateoas.Resource.{
    Exclusion,
    Method,
    NotDelegable,
    Observable,
    Override,
    SemanticAction,
    SemanticProperty,
    Unrouted
  }

  @persisted_routes_key :ash_hateoas_routes
  @persisted_observables_key :ash_hateoas_observables

  @doc """
  The resource's declared or inferred type.

  Reads the `hateoas` `type` option; when it is not declared, infers it from the
  module name — the last segment, underscored (`MyApp.Blog.Comment` →
  `"comment"`), mirroring `Ash.Domain.default_short_name/0`. Deliberately not
  pluralised.

  Works both post-compile (given a module) and at transform time (given the DSL
  state), since the module is persisted under `:module` and inference reads it
  either way. Returns `nil` only when no module can be resolved.
  """
  @spec type(Ash.Resource.t() | map()) :: String.t() | nil
  def type(resource_or_dsl) do
    case hateoas_type(resource_or_dsl) do
      {:ok, declared} when is_binary(declared) -> declared
      _ -> infer_type(resource_or_dsl)
    end
  end

  defp infer_type(resource) when is_atom(resource) and not is_nil(resource) do
    module_type(resource)
  end

  # DSL-state form (a map, at transform time): the module is persisted under
  # `:module`, so inference works before the module has finished compiling.
  defp infer_type(dsl_map) do
    case Spark.Dsl.Extension.get_persisted(dsl_map, :module) do
      module when is_atom(module) and not is_nil(module) -> module_type(module)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  A resource's type inferred from its **module name alone**
  (`MyApp.Blog.Comment` → `"comment"`).

  Public because a transformer sometimes needs another resource's type while
  that resource may still be compiling, and `type/1` cannot serve there: it
  reads the DSL first, which forces the module and can deadlock the compiler if
  the two point at each other. Measured — declaring an owner that also holds a
  `has_many` back is enough.

  So this is the safe reading, and its cost is stated: a resource that
  **declares** a `type` different from its module name is not honoured here. It
  is the same trade `DeriveActionRoutes.domain_short_name/1` makes for exactly
  the same reason.
  """
  @spec module_type(module()) :: String.t() | nil
  def module_type(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  rescue
    _ -> nil
  end

  @doc """
  The resource's declared base path, or `nil` when it is left to be derived.
  """
  @spec base(Ash.Resource.t() | map()) :: String.t() | nil
  def base(resource_or_dsl) do
    case hateoas_base(resource_or_dsl) do
      {:ok, base} -> base
      _ -> nil
    end
  end

  @doc """
  A well-known type IRI to advertise alongside the resource's own class, or
  `nil` when none is declared.

  A bare token is resolved against the configured semantic vocabulary — schema.org
  by default (`"Person"` → `"https://schema.org/Person"`); an absolute IRI
  (anything containing `"://"`) is returned verbatim. See
  `AshHateoas.SemanticVocab`.
  """
  @spec semantic_type(Ash.Resource.t() | map()) :: String.t() | nil
  def semantic_type(resource_or_dsl) do
    case hateoas_semantic_type(resource_or_dsl) do
      {:ok, declared} when is_binary(declared) -> resolve_semantic_type(declared)
      _ -> nil
    end
  end

  defp resolve_semantic_type(value), do: resolve_iri(value)

  # A bare token resolves against the configured semantic vocabulary (schema.org
  # by default); an absolute IRI is used verbatim. See `AshHateoas.SemanticVocab`.
  defp resolve_iri(value), do: AshHateoas.SemanticVocab.resolve(value)

  @doc """
  A map of `attribute => well-known property IRI` from the resource's
  `semantic_property` declarations, ready for a renderer to substitute for the
  API-local property IRI.

  Bare tokens are resolved against the configured semantic vocabulary (schema.org
  by default); absolute IRIs are used verbatim.
  """
  @spec semantic_properties(Ash.Resource.t() | map()) :: %{atom() => String.t()}
  def semantic_properties(resource_or_dsl) do
    resource_or_dsl
    |> hateoas()
    |> Enum.filter(&match?(%SemanticProperty{}, &1))
    |> Map.new(fn %SemanticProperty{} = mapping ->
      {mapping.attribute, resolve_iri(mapping.iri)}
    end)
  end

  @doc """
  A map of `action => well-known Action-type IRI` from the resource's
  `semantic_action` declarations — the declared role for an operation's
  `schema:potentialAction` type.

  An action absent from this map emits no `potentialAction` at all: a subtype
  inferred from the HTTP method would restate `hydra:method` on the same node.
  Bare tokens are resolved against the configured
  semantic vocabulary (schema.org by default);
  absolute IRIs are used verbatim.
  """
  @spec semantic_actions(Ash.Resource.t() | map()) :: %{atom() => String.t()}
  def semantic_actions(resource_or_dsl) do
    resource_or_dsl
    |> hateoas()
    |> Enum.filter(&match?(%SemanticAction{}, &1))
    |> Map.new(fn %SemanticAction{} = mapping ->
      {mapping.action, resolve_iri(mapping.iri)}
    end)
  end

  @doc """
  The package-owned routes derived for this resource.

  Route derivation persists `AshHateoas.Route` structs under an
  `ash_hateoas`-owned key, so the backbone and navigation read them and the
  Hydra plug can serve them.
  """
  @spec routes(Ash.Resource.t() | map()) :: [AshHateoas.Route.t()]
  def routes(resource_or_dsl) do
    Spark.Dsl.Extension.get_persisted(resource_or_dsl, @persisted_routes_key, [])
  rescue
    _ -> []
  end

  @doc """
  The declared `observable` subjects: `:resource`, `:collection`, or attribute
  names — the raw declarations, before derivation.
  """
  @spec observable_subjects(Ash.Resource.t() | map()) :: [atom()]
  def observable_subjects(resource_or_dsl) do
    resource_or_dsl
    |> hateoas()
    |> Enum.filter(&match?(%Observable{}, &1))
    |> Enum.map(& &1.subject)
  end

  @doc """
  The observability specs derived for this resource.

  Derivation persists `AshHateoas.Observable` structs under an
  `ash_hateoas`-owned key, so a publishing transport (e.g. `ash_websub`) can
  read them and the Hydra plug can serve property topics. This package never
  publishes them itself — with no transport installed they are inert.
  """
  @spec observables(Ash.Resource.t() | map()) :: [AshHateoas.Observable.t()]
  def observables(resource_or_dsl) do
    Spark.Dsl.Extension.get_persisted(resource_or_dsl, @persisted_observables_key, [])
  rescue
    _ -> []
  end

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
  Action names this resource excludes from advertisement.
  """
  @spec exclusions(Ash.Resource.t() | map()) :: [atom()]
  def exclusions(resource_or_dsl) do
    resource_or_dsl
    |> hateoas()
    |> Enum.filter(&match?(%Exclusion{}, &1))
    |> Enum.map(& &1.action)
  end

  @doc """
  Per-action overrides as `%{action_name => [href: ...]}`.

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
  Action names only a committing credential may execute.

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
  Whether `action` may only be executed by a committing credential.
  """
  @spec not_delegable?(Ash.Resource.t() | map(), atom()) :: boolean()
  def not_delegable?(resource_or_dsl, action) do
    action in not_delegable(resource_or_dsl)
  end

  @doc """
  Whether `resource` carries this extension at all.

  The Hydra plug ignores resources that do not, so this is the check that keeps
  affordances opt-in per resource.
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
