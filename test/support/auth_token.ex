defmodule AshHateoas.Test.AuthToken do
  @moduledoc """
  The token resource `AshHateoas.Test.AuthUser` stores its JWTs in.

  Required by `AshAuthentication.TokenResource` when tokens are enabled. It
  exists to make the user fixture valid; nothing here is under test directly,
  though every action on it is AshAuthentication's and so none should be routed.
  """

  use Ash.Resource,
    domain: AshHateoas.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication.TokenResource]

  ets do
    private? true
  end

  token do
    domain AshHateoas.Test.Domain
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end
  end
end
