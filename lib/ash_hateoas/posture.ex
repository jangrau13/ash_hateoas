defmodule AshHateoas.Posture do
  @moduledoc """
  Resolves whether affordances are computed for a resource.

  Affordances are a hypermedia contract: a client must not have to remember a
  flag to get a navigable response, and a client that forgets one must not
  silently receive a non-hypermedia response. So the default is **on**, and it
  is switched off — not on — when not wanted.

  ## Precedence

      resource `enabled?`  >  domain `enabled?`  >  true

  A resource's own declaration always wins, so a domain-wide switch-off can
  still be overridden for one resource that needs to stay navigable.

  ## Why `nil` means "undeclared"

  Spark materialises schema defaults into the DSL state, so `get_opt/5` returns
  the schema default — not the caller's fallback — for an option that was never
  written. A `default: true` would therefore make every resource look like it
  had explicitly opted in, and no resource could ever inherit `false` from its
  domain.

  Both sections declare `default: nil` instead, so `nil` genuinely means "said
  nothing" and this module supplies the precedence.
  """

  @doc """
  Whether affordances should be computed for `resource`.

  `domain` is consulted only when the resource itself says nothing.
  """
  @spec enabled?(module(), module() | nil) :: boolean()
  def enabled?(resource, domain \\ nil) do
    case declared(resource) do
      nil -> domain_default(domain)
      value -> value
    end
  end

  defp domain_default(nil), do: true

  defp domain_default(domain) do
    case declared(domain) do
      nil -> true
      value -> value
    end
  end

  defp declared(module) do
    Spark.Dsl.Extension.get_opt(module, [:hateoas], :enabled?, nil, false)
  rescue
    _ -> nil
  end
end
