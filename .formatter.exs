spark_locals_without_parens = [
  enabled?: 1,
  exclude: 1,
  method: 2,
  not_delegable: 1,
  override: 1,
  override: 2,
  unrouted: 1,
  warn_on_missing_authorizers?: 1
]

# Used by "mix format"
[
  import_deps: [:ash, :ash_json_api, :ash_authentication, :ash_state_machine],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: spark_locals_without_parens,
  export: [
    locals_without_parens: spark_locals_without_parens
  ]
]
