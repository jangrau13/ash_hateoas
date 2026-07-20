import Config

if config_env() == :test do
  config :ash_hateoas,
    ash_domains: [AshHateoas.Test.Domain, AshHateoas.Test.SilentDomain]

  config :ash, :validate_domain_config_inclusion?, false
  config :ash, :disable_async?, true

  # Ash logs every create at :debug, which drowns test output. R7 requires our
  # own :error logs to be visible, so raise the floor rather than silencing.
  config :logger, level: :warning
end
