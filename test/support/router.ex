defmodule AshHateoas.Test.JsonApiRouter do
  @moduledoc """
  The AshJsonApi router for the test domain, wired to capture route context.

  `before_dispatch` is what hands the transform the typed `%Route{}` before
  serialization — without it the merge stage cannot tell a single-record read
  from a collection read.
  """

  use AshJsonApi.Router,
    domains: [AshHateoas.Test.Domain],
    before_dispatch: {AshHateoas.JsonApi.Transform, :before_dispatch, []}
end

defmodule AshHateoas.Test.Endpoint do
  @moduledoc """
  A bare Plug pipeline: the transform wrapping the JSON:API router.

  No Phoenix — `AshJsonApi.Router` is `use Plug.Router`, so this is all that is
  needed to exercise the real request path in-process with `Plug.Test`.
  """

  use Plug.Builder

  # `domains:` lets the transform serve the R9 root entry document at "/",
  # which ash_json_api itself has no route for.
  plug(AshHateoas.JsonApi.Transform, domains: [AshHateoas.Test.Domain])
  plug(AshHateoas.Test.JsonApiRouter)
end

defmodule AshHateoas.Test.HydraEndpoint do
  @moduledoc """
  The native Hydra endpoint: `AshHateoas.Hydra.Plug` serving the test domain as
  `application/ld+json`. No AshJsonApi, no Phoenix — the plug does its own Ash
  reads/writes and JSON-LD serialization.
  """

  use Plug.Builder

  plug(AshHateoas.Hydra.Plug, domains: [AshHateoas.Test.Domain], doc_path: "/doc")
end
