defmodule AshHateoas.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/jangrau13/ash_hateoas"
  @description """
  Authorization- and state-aware HATEOAS affordances for Ash, served natively
  as a Hydra / JSON-LD API.
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
      files: ~w(lib documentation .formatter.exs mix.exs README.md LICENSE usage-rules.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      extras: [
        "README.md",
        "CHANGELOG.md",
        "usage-rules.md",
        "documentation/hydra-mapping.md"
      ]
    ]
  end

  defp deps do
    [
      {:ash, "~> 3.29"},
      {:spark, "~> 2.6"},
      {:jason, "~> 1.4"},
      # Required: the Hydra transport ships a Plug.
      {:plug, "~> 1.16"},
      # Optional capabilities the backbone reads when present.
      {:ash_state_machine, "~> 0.2", optional: true},
      # Route derivation skips the actions AshAuthentication generates — they
      # are served by its own router, and the subject resolver is guarded by a
      # bypass no HTTP caller can satisfy. Optional: a consumer without
      # authentication never loads it, and the check degrades to a no-op.
      {:ash_authentication, "~> 4.0", optional: true},
      # Igniter powers `mix igniter.install ash_hateoas`; optional so consumers
      # who install by hand are not forced to take it.
      {:igniter, "~> 0.8", optional: true},
      # Ash.Policy.Authorizer needs a SAT solver to reason about policy
      # combinations. Consumers supply their own; the test suite needs one.
      {:simple_sat, "~> 0.1", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: [:dev], runtime: false}
    ]
  end
end
