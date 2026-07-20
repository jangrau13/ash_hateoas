defmodule AshHateoas.Domain.Info do
  @moduledoc """
  Introspection for the domain-level `hateoas` section.
  """

  use Spark.InfoGenerator,
    extension: AshHateoas.Domain,
    sections: [:hateoas]

  @doc "Whether `domain` carries this extension."
  @spec extension?(Ash.Domain.t()) :: boolean()
  def extension?(domain) when is_atom(domain) do
    AshHateoas.Domain in Spark.extensions(domain)
  rescue
    _ -> false
  end

  def extension?(_domain), do: false
end
