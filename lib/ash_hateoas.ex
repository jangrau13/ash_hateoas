defmodule AshHateoas do
  @moduledoc """
  Authorization- and state-aware HATEOAS affordances for Ash.

  One backbone computes *what may be done next* for a given record (or resource)
  and actor. Every transport is a rendering of that single result:

    * JSON:API — affordances become named `links.<action>` objects
    * MCP — affordances become the `tools/list` result

  Affordances are derived from what a resource already declares — its actions,
  its JSON:API routes, its policies, and its `AshStateMachine` transitions where
  present. A resource author writes no affordances; the optional `hateoas` DSL
  section carries deviations only.

  See `REQ.md` for the full requirement set.
  """
end
