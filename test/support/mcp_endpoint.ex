defmodule AshHateoas.Test.McpEndpoint do
  @moduledoc """
  Mounts the MCP router for the test domain.
  """

  use Plug.Builder

  plug(AshHateoas.Mcp.Router,
    domain: AshHateoas.Test.Domain,
    resources: [AshHateoas.Test.Order],
    otp_app: :ash_hateoas
  )
end
