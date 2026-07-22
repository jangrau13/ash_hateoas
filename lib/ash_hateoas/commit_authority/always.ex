defmodule AshHateoas.CommitAuthority.Always do
  @moduledoc """
  Every actor commits — the default when none is configured (R10).

  With this in place `not_delegable` changes no endpoint behaviour: the flag is
  still declared, still rendered, and still readable by a consumer that wants to
  route the action to a person, but nothing is refused.

  That is a defensible state to ship in, and it is why adding the extension to
  an existing deployment cannot break it. `AshHateoas.Resource`'s verifier warns
  when a resource declares `not_delegable` and no authority is configured, so
  the state is reached deliberately rather than by accident.
  """

  @behaviour AshHateoas.CommitAuthority

  @impl AshHateoas.CommitAuthority
  def commits?(_actor), do: true
end
