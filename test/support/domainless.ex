defmodule AshHateoas.Test.Domainless do
  @moduledoc """
  A resource that declares no domain, to exercise the backbone's error path.

  Routes are declared at domain level, so the backbone must fail with a clear
  message rather than proceeding with an unusable candidate set.
  """

  use Ash.Resource,
    domain: nil,
    validate_domain_inclusion?: false,
    data_layer: Ash.DataLayer.Ets

  ets do
    private?(true)
  end

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
  end
end
