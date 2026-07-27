defmodule AshHateoas.Error.NotDelegable do
  @moduledoc """
  Raised when a credential that does not commit invokes a `not_delegable`
  action.

  `class: :forbidden` maps to **403** on the wire. Not 2xx: the request was
  "publish this", that did not happen, and every HTTP client branches on
  `status < 300` before anything reads the body. Not 202, which promises the
  action is queued when nothing is.

  403 is the same code an unauthorized actor already receives, and that is the
  point — the projection is **additive**. A client reading only status codes
  treats this as the refusal it is; a client reading the body learns what the
  action would have done.

  ## Why the payload is structured

  `deltas` carries the projection as data, never prose. A consumer
  pattern-matching on an English sentence breaks when the sentence is edited,
  and the sentence is the part most likely to be edited.
  """

  use Splode.Error,
    fields: [:resource, :action, :actor, deltas: []],
    class: :forbidden

  def message(%{resource: resource, action: action}) do
    """
    #{inspect(action)} on #{inspect(resource)} requires a credential that commits.

    The action is advertised to this actor and it is authorized to propose it,
    but executing it is reserved to a committing credential.
    """
  end

  @doc """
  The error's projection, shaped for a wire format.

  Kept here rather than in the Hydra plug so any transport can reuse it.
  """
  @spec to_meta(%__MODULE__{}) :: map()
  def to_meta(%__MODULE__{} = error) do
    %{
      "action" => to_string(error.action),
      "projection" => Enum.map(error.deltas, &delta/1)
    }
  end

  # Several entries where a transition declares several `to` states. They are
  # presented as alternatives rather than one being chosen, so this is a list
  # even when it has one element.
  defp delta(%{to: to, gained: gained, lost: lost}) do
    %{
      "to" => to_string(to),
      "gained" => gained |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort(),
      "lost" => Enum.map(lost, &to_string/1)
    }
  end
end
