defmodule AshHateoas.Test.SilentResource do
  @moduledoc """
  Declares nothing itself, so it inherits its domain's `enabled? false`.
  """

  use Ash.Resource,
    domain: AshHateoas.Test.SilentDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshHateoas.Resource]

  ets do
    private? true
  end

  hateoas do
    warn_on_missing_authorizers?(false)
  end

  attributes do
    uuid_primary_key :id
    attribute :label, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: [:label]]
  end
end

defmodule AshHateoas.Test.LoudResource do
  @moduledoc """
  Overrides its domain's `enabled? false` with its own `enabled? true`, proving
  a resource declaration beats the domain default.
  """

  use Ash.Resource,
    domain: AshHateoas.Test.SilentDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshHateoas.Resource]

  ets do
    private? true
  end

  hateoas do
    enabled? true
    warn_on_missing_authorizers?(false)
  end

  attributes do
    uuid_primary_key :id
    attribute :label, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: [:label]]
  end
end

defmodule AshHateoas.Test.SilentDomain do
  @moduledoc """
  A domain that switches affordances off for everything it contains.
  """

  use Ash.Domain, extensions: [AshHateoas.Domain], validate_config_inclusion?: false

  hateoas do
    enabled? false
  end

  resources do
    resource AshHateoas.Test.SilentResource
    resource AshHateoas.Test.LoudResource
  end
end
