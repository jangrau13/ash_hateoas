defmodule AshHateoas.Hydra.ErrorTest do
  @moduledoc "The hydra:Error / RFC 7807 renderings, including the R10 projection."

  use ExUnit.Case, async: true

  alias AshHateoas.Hydra.Error, as: HydraError

  test "render/1 builds a hydra:Error with status, title and detail" do
    error = HydraError.render(status: 403, title: "Forbidden", detail: "nope")

    assert error["@type"] == "Error"
    assert error["hydra:statusCode"] == 403
    assert error["hydra:title"] == "Forbidden"
    assert error["hydra:description"] == "nope"
    assert error["@context"]
  end

  test "not_delegable/1 carries the projection under ah: keys" do
    error = %AshHateoas.Error.NotDelegable{
      resource: SomeResource,
      action: :publish,
      actor: nil,
      deltas: [%{to: :published, gained: %{unpublish: :x}, lost: [:publish]}]
    }

    rendered = HydraError.not_delegable(error)

    assert rendered["@type"] == "Error"
    assert rendered["hydra:statusCode"] == 403
    # to_meta/1 output is merged under ah: keys
    assert rendered["ah:action"] == "publish"
    assert [%{"to" => "published", "gained" => ["unpublish"], "lost" => ["publish"]}] =
             rendered["ah:projection"]

    assert {:ok, _} = Jason.encode(rendered)
  end

  test "problem_json/1 emits RFC 7807 members" do
    problem = HydraError.problem_json(status: 400, title: "Bad", detail: "why", instance: "/x")

    assert problem["type"] == "about:blank"
    assert problem["status"] == 400
    assert problem["title"] == "Bad"
    assert problem["detail"] == "why"
    assert problem["instance"] == "/x"
  end
end
