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
      # Patched Ash (jangrau13/ash @ arg-gated-strict-check): policy strict-check
      # returns `:unknown` rather than `false` for an argument-gated filter when
      # the argument is absent. The affordance layer probes `Ash.can?/3` with no
      # arguments to decide what to advertise, so without this an action gated on
      # an argument (`authorize_if expr(^arg(:tier) == "public")`) is wrongly
      # dropped from the advertised surface. `override: true` because transitive
      # deps still ask for hex `~> 3.x`.
      {:ash, path: "../ash", override: true},
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
      # Lua's scanner and parser, for `AshHateoas.Type.Lua`. **Only the parser
      # is used** — `luerl_scan` and `luerl_parse` yield an AST and nothing ever
      # runs it, so a stored script is analysed the way a compiler analyses
      # source, and there is no sandbox question to answer.
      #
      # `ash_lua` was read and rejected for the same reason: it generates an
      # `:eval` action so a client POSTs a script and it *executes* against your
      # Ash actions. That is the opposite direction — a script here is stored,
      # analysed and edited, never run.
      {:luerl, "~> 1.5"},
      # Igniter powers `mix igniter.install ash_hateoas` and the
      # `mix ash_hateoas.gen.schema_org` generator; optional so consumers who
      # install by hand are not forced to take it.
      {:igniter, "~> 0.8", optional: true},
      # Req fetches the schema.org vocabulary for the schema_org generator.
      # Optional and generator-only — the runtime library never calls it.
      {:req, "~> 0.5", optional: true},
      # Ash.Policy.Authorizer needs a SAT solver to reason about policy
      # combinations. Consumers supply their own; the test suite needs one.
      {:simple_sat, "~> 0.1", only: [:dev, :test]},
      # A real JSON-LD processor, for the tests only.
      #
      # This package's whole claim is that a client can read meaning off the
      # wire, and meaning is what a *processor* extracts — not what the JSON
      # looks like. Two defects proved the difference and both were invisible to
      # assertions on raw JSON: four malformed `@context` term definitions that
      # made every emitted document fail to expand, and record nodes whose keys
      # were bound to nothing at all, so relationship links produced no triples
      # and `title` expanded to `hydra:title`.
      #
      # Hand-rolling term resolution in the test would only encode the same
      # assumptions the emitter makes, and agree with itself. Expanding with an
      # independent implementation is what makes these tests evidence.
      {:json_ld, "~> 1.0", only: :test},
      {:ex_doc, "~> 0.34", only: [:dev], runtime: false}
    ]
  end
end
