defmodule AshHateoas.Backbone do
  @moduledoc """
  The transport-agnostic engine (§3).

  Pipeline:

    1. **Candidate set** — actions reachable via declared routes, minus excludes
    2. **Gates** — an ordered chain; authorization, then state where present
    3. **Descriptors** — one `AshHateoas.Affordance` per survivor

  Output is the R5 envelope: a map of action name → affordance, or an empty map
  when nothing survives. Only the *set* is dynamic; everything below each key is
  fixed.

  Both entry points feed every adapter. An adapter contains no affordance logic
  of its own (§5).
  """

  alias AshHateoas.{Candidates, Descriptor}
  alias AshHateoas.Gate.{Chain, Context}

  @default_gates [AshHateoas.Gate.Authorization]

  @typedoc "Action name => affordance"
  @type envelope :: %{atom() => AshHateoas.Affordance.t()}

  @doc """
  Affordances for a specific record (§3, R9).

  The full chain applies, including the state gate where the resource has a
  state machine — an action must be authorized *and* legal from the record's
  current state.
  """
  @spec for_record(struct(), term(), keyword()) :: envelope()
  def for_record(record, actor, opts) when is_struct(record) do
    resource = record.__struct__

    compute(resource, record, actor, :record, opts)
  end

  @doc """
  Affordances for a resource with no record in hand (R9).

  This is the collection-level entry point: `create` and index-style reads. No
  state gate applies — there is no record to have a state — but authorization
  still does.

  It is also the cold-start case: a client that has just entered the system has
  no record, so this is the first thing it needs.
  """
  @spec for_resource(module(), term(), keyword()) :: envelope()
  def for_resource(resource, actor, opts) when is_atom(resource) do
    compute(resource, nil, actor, :collection, opts)
  end

  defp compute(resource, record, actor, kind, opts) do
    if enabled?(resource) do
      do_compute(resource, record, actor, kind, opts)
    else
      %{}
    end
  end

  # A resource may switch affordances off entirely (R8). Resources without the
  # extension are unaffected — they have no declaration to read, and callers can
  # still invoke the backbone directly.
  defp enabled?(resource) do
    if AshHateoas.Resource.Info.extension?(resource) do
      AshHateoas.Resource.Info.hateoas_enabled?(resource)
    else
      true
    end
  end

  defp declared_opts(resource) do
    if AshHateoas.Resource.Info.extension?(resource) do
      AshHateoas.Resource.Info.affordance_opts(resource)
    else
      []
    end
  end

  defp do_compute(resource, record, actor, kind, opts) do
    domain = domain!(resource, opts)

    context = %Context{
      resource: resource,
      record: record,
      actor: actor,
      domain: domain,
      tenant: opts[:tenant]
    }

    # The resource's own `hateoas` block supplies exclusions and overrides;
    # explicit opts win, so a caller can still override the declaration.
    declared = declared_opts(resource)

    excluded = MapSet.new(opts[:exclude] || declared[:exclude] || [])
    overrides = opts[:overrides] || declared[:overrides] || %{}
    gates = opts[:gates] || @default_gates

    candidates =
      resource
      |> Candidates.for_resource(domains(domain, opts), kind)
      |> Enum.reject(fn {action, _route} -> MapSet.member?(excluded, action.name) end)

    routes_by_action =
      Map.new(candidates, fn {action, route} -> {action.name, route} end)

    candidates
    |> Enum.map(fn {action, _route} -> action end)
    |> Chain.run(gates, context)
    |> Map.new(fn action ->
      affordance =
        Descriptor.build(
          action,
          Map.get(routes_by_action, action.name),
          resource,
          Map.get(overrides, action.name, [])
        )

      {action.name, affordance}
    end)
  end

  # Routes are declared at domain level, so the domain must be threaded through
  # — a resource-only lookup is insufficient (§3).
  defp domain!(resource, opts) do
    case opts[:domain] || Ash.Resource.Info.domain(resource) do
      nil ->
        raise ArgumentError, """
        ash_hateoas could not determine the domain for #{inspect(resource)}.

        Routes are declared at the domain level, so the domain must be known.
        Pass it explicitly:

            AshHateoas.affordances(record, actor, domain: MyApp.MyDomain)
        """

      domain ->
        domain
    end
  end

  defp domains(domain, opts) do
    opts
    |> Keyword.get(:domains, [domain])
    |> List.wrap()
  end
end
