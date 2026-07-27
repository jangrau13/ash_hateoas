defmodule AshHateoas.CommitAuthority.ApiKey do
  @moduledoc """
  An actor holding an API key does not commit.

      config :ash_hateoas, commit_authority: AshHateoas.CommitAuthority.ApiKey

  Reads the metadata `ash_authentication`'s api_key strategy already stamps on
  the actor it returns — `__metadata__[:using_api_key?]`, the same field its own
  `AshAuthentication.Checks.UsingApiKey` policy check reads. Nothing is
  invented and nothing is guessed.

  ## Why the key, and not a separate agent resource

  Modelling the delegate as its own authenticatable resource would make "the
  delegate may do no more than its principal" a claim to maintain. Here the
  delegate authenticates **as** its principal with a credential that narrows, so
  policies evaluate the principal's authority *and* the key's scope, and the
  subset property holds by construction.

  ## What this actually asks

  "Does this actor hold a delegated credential?" — **not** "is this an agent?".
  A person scripting against the API with their own key is refused too. That is
  correct, since a script is not a party exercising judgment, but it will be
  reported as a bug if it is not expected.

  A deployment wanting a narrower rule — some keys commit, others do not —
  implements `AshHateoas.CommitAuthority` itself and reads whatever it put on
  the key record, which this module leaves untouched under
  `__metadata__[:api_key]`.

  ## No compile-time dependency

  This matches a map key and references no module from `ash_authentication`, so
  it compiles whether or not that package is present. The dependency is
  documentation, not code.
  """

  @behaviour AshHateoas.CommitAuthority

  @impl AshHateoas.CommitAuthority
  def commits?(%{__metadata__: %{using_api_key?: true}}), do: false
  def commits?(_actor), do: true
end
