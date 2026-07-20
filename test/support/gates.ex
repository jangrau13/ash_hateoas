defmodule AshHateoas.Test.DenyAllGate do
  @moduledoc "Removes every candidate — used to test short-circuiting."
  @behaviour AshHateoas.Gate

  @impl true
  def filter(_candidates, _context), do: []
end

defmodule AshHateoas.Test.OnlyReadGate do
  @moduledoc "Keeps only :read — used to test that custom gates compose."
  @behaviour AshHateoas.Gate

  @impl true
  def filter(candidates, _context) do
    Enum.filter(candidates, &(&1.name == :read))
  end
end

defmodule AshHateoas.Test.RaisingGate do
  @moduledoc """
  Raises if it is ever reached. Proves the chain short-circuits: placed after a
  gate that empties the set, it must never run.
  """
  @behaviour AshHateoas.Gate

  @impl true
  def filter(_candidates, _context) do
    raise "RaisingGate ran — the chain failed to short-circuit on an empty set"
  end
end

defmodule AshHateoas.Test.RaisingAuthGate do
  @moduledoc """
  Simulates a policy check that blows up, to prove R7: the exception is logged
  with context and the affordance is dropped, rather than silently vanishing.
  """
  @behaviour AshHateoas.Gate

  require Logger

  @impl true
  def filter(candidates, context) do
    Enum.filter(candidates, fn action ->
      try do
        raise "simulated policy explosion"
      rescue
        exception ->
          Logger.error("""
          [ash_hateoas] Authorization check raised while computing affordances; \
          dropping #{inspect(action.name)}.

            resource: #{inspect(context.resource)}
            action:   #{inspect(action.name)}

          #{Exception.message(exception)}
          """)

          false
      end
    end)
  end
end
