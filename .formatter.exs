spark_locals_without_parens = [
  base: 1,
  enabled?: 1,
  exclude: 1,
  method: 2,
  not_delegable: 1,
  override: 1,
  override: 2,
  semantic_property: 2,
  semantic_type: 1,
  type: 1,
  unrouted: 1,
  warn_on_missing_authorizers?: 1
]

# Used by "mix format"
[
  import_deps: [:ash, :ash_authentication, :ash_state_machine],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: spark_locals_without_parens,
  export: [
    locals_without_parens: spark_locals_without_parens
  ]
]
