# The JSON:API rendering of AshHateoas.Error.NotDelegable (R10).
#
# In its own file and behind a compile-time guard because `defimpl` cannot be
# guarded at runtime and `ash_json_api` is an optional dependency. The error
# itself carries no JSON:API knowledge — `to_meta/1` lives on the struct so a
# transport built against the profile (§5.2) can reuse it.
if Code.ensure_loaded?(AshJsonApi.ToJsonApiError) do
  defimpl AshJsonApi.ToJsonApiError, for: AshHateoas.Error.NotDelegable do
    def to_json_api_error(error) do
      %AshJsonApi.Error{
        id: Ash.UUID.generate(),
        status_code: 403,
        code: "not_delegable",
        title: "NotDelegable",
        detail: "This action requires a credential that commits.",
        meta: AshHateoas.Error.NotDelegable.to_meta(error)
      }
    end
  end
end
