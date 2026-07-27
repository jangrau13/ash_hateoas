defmodule AshHateoas.Hydra.Error do
  @moduledoc """
  Renders an error as a `hydra:Error` node (a subclass of `hydra:Status`),
  complementing the HTTP status code with a machine-readable reason.

  The R10 `AshHateoas.Error.NotDelegable` refusal carries a projection of what
  the action would have done; `to_meta/1` on that struct is reused here so the
  projection is expressed identically to how any transport built on the profile
  would.
  """

  alias AshHateoas.Hydra.Context

  @doc """
  Build a `hydra:Error` node.

  ## Options

    * `:status` — the HTTP status code (`hydra:statusCode`).
    * `:title` — a short label.
    * `:detail` — a human-readable description.
    * `:meta` — extra machine-readable members merged under `ah:` keys.
  """
  @spec render(keyword()) :: map()
  def render(opts \\ []) do
    %{
      "@context" => Context.context(),
      "@type" => "Error"
    }
    |> put_unless_nil("hydra:statusCode", Keyword.get(opts, :status))
    |> put_unless_nil("hydra:title", Keyword.get(opts, :title))
    |> put_unless_nil("hydra:description", Keyword.get(opts, :detail))
    |> merge_meta(Keyword.get(opts, :meta, %{}))
  end

  @doc """
  Render the R10 refusal as a `hydra:Error` with its projection.
  """
  @spec not_delegable(AshHateoas.Error.NotDelegable.t()) :: map()
  def not_delegable(%AshHateoas.Error.NotDelegable{} = error) do
    render(
      status: 403,
      title: "NotDelegable",
      detail: "This action requires a credential that commits.",
      meta: AshHateoas.Error.NotDelegable.to_meta(error)
    )
  end

  @doc """
  Render an error as RFC 7807 `application/problem+json`.

  The Hydra spec recommends RFC 7807 as the interoperable error form; this is
  offered for a client that negotiates `application/problem+json`.
  """
  @spec problem_json(keyword()) :: map()
  def problem_json(opts \\ []) do
    %{}
    |> put_unless_nil("type", Keyword.get(opts, :type, "about:blank"))
    |> put_unless_nil("title", Keyword.get(opts, :title))
    |> put_unless_nil("status", Keyword.get(opts, :status))
    |> put_unless_nil("detail", Keyword.get(opts, :detail))
    |> put_unless_nil("instance", Keyword.get(opts, :instance))
  end

  defp merge_meta(error, meta) when map_size(meta) == 0, do: error

  defp merge_meta(error, meta) do
    Map.merge(error, Map.new(meta, fn {key, value} -> {"ah:#{key}", value} end))
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
