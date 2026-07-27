defmodule AshHateoas.Test.HydraEndpoint do
  @moduledoc """
  The native Hydra endpoint: `AshHateoas.Hydra.Plug` serving the test domain as
  `application/ld+json`. No Phoenix — the plug does its own Ash reads/writes and
  JSON-LD serialization.
  """

  use Plug.Builder

  plug(AshHateoas.Hydra.Plug, domains: [AshHateoas.Test.Domain], doc_path: "/doc")
end
