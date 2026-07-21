defmodule AshHateoas.Resource.Transformers.MarkPrimaryGet do
  @moduledoc """
  Marks a resource's sole `:get` route `primary?`, so records carry a `self`.

  `ash_json_api` renders a record's `self` link from the `:get` route marked
  `primary?` — "the route that should be linked to by default when rendering
  links to this type of route" — and `primary?` defaults to `false`. A resource
  declaring a plain `get :read` therefore serializes records with no link to
  themselves, leaving them addressable by URL but unnameable by a client that
  follows links and constructs nothing (R9).

  Where there is exactly **one** `:get` route, "which is canonical" has only one
  answer, so this fills it in — R1: derive what is unambiguous rather than make
  the author restate it.

  Where there are several and none is marked, the choice is genuinely the
  author's and this does nothing;
  `AshHateoas.Resource.Verifiers.VerifyActions` warns instead.

  Runs before `ash_json_api`'s own transformers so the route entity is already
  corrected by the time they read it.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def after?(_), do: false

  @impl true
  def before?(_), do: true

  @impl true
  def transform(dsl_state) do
    routes = Transformer.get_entities(dsl_state, [:json_api, :routes])

    case Enum.filter(routes, &(&1.type == :get)) do
      [%{primary?: false} = only] ->
        {:ok,
         Transformer.replace_entity(
           dsl_state,
           [:json_api, :routes],
           %{only | primary?: true},
           &(&1.type == :get)
         )}

      _several_or_none_or_already_marked ->
        {:ok, dsl_state}
    end
  rescue
    # A resource without the ash_json_api extension has no such DSL path.
    _ -> {:ok, dsl_state}
  end
end
