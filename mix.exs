defmodule AshHateoas.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/jangrau13/ash_hateoas"
  @description """
  Authorization- and state-aware HATEOAS affordances for Ash, rendered natively
  into JSON:API links, described by a published profile.
  """

  def project do
    [
      app: :ash_hateoas,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      description: @description,
      package: package(),
      docs: docs(),
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      name: :ash_hateoas,
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib documentation .formatter.exs mix.exs README.md LICENSE REQ.md usage-rules.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      extras: [
        "README.md",
        "usage-rules.md",
        "documentation/profiles/affordances.md"
      ]
    ]
  end

  defp deps do
    [
      {:ash, "~> 3.29"},
      {:spark, "~> 2.6"},
      {:jason, "~> 1.4"},
      # Required: every rendering path this package ships is a Plug.
      {:plug, "~> 1.16"},
      # Optional renderings. `optional: true` still fetches/compiles them here,
      # it only tells Hex not to force them on consumers.
      {:ash_json_api, "~> 1.7", optional: true},
      {:ash_state_machine, "~> 0.2", optional: true},
      # Igniter powers `mix igniter.install ash_hateoas`; optional so consumers
      # who install by hand are not forced to take it.
      {:igniter, "~> 0.8", optional: true},
      # Ash.Policy.Authorizer needs a SAT solver to reason about policy
      # combinations. Consumers supply their own; the test suite needs one.
      {:simple_sat, "~> 0.1", only: [:dev, :test]},
      # `ash_json_api` reaches for `AshJsonApi.OpenApi` when validating a write,
      # and that module only compiles when `open_api_spex` is present — so a
      # PATCH or POST through the router raises without it. It was previously
      # pulled in transitively by `ash_ai`; the test suite needs it directly
      # now, and a consumer needs it in their own deps.
      {:open_api_spex, "~> 3.18", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: [:dev], runtime: false}
    ]
  end
end
