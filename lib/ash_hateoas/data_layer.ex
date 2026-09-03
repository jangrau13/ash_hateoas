defmodule AshHateoas.DataLayer do
  @moduledoc """
  Not a data layer — the little this library needs to know about somebody
  else's.

  Two SQL data layers are recognised, **by name**: `AshPostgres.DataLayer` and
  `AshSqlite.DataLayer`. Neither is a dependency of this package and neither
  should become one — a consumer brings whichever it uses, and recognising a
  module name costs nothing at build time. A data layer this does not recognise
  is not an error but the ordinary case: ETS, a manual layer, whatever comes
  next.

  ## Why a transaction boundary is here at all

  `AshSqlite.DataLayer.can?(_, :transact)` is `false`, unconditionally. No repo
  configuration changes it — `default_transaction_mode` and `pool_size` govern
  how a transaction behaves once one is open, not whether Ash opens one.

  Ash reads that answer and acts on it quietly. `Ash.DataLayer.transaction/5`
  checks `can?(:transact)` and, when the answer is no, calls the function and
  returns `{:ok, result}`: no error, no warning, no `BEGIN`. So an action that
  relied on Ash's implicit per-action wrapping loses its rollback boundary the
  day a domain moves from Postgres to SQLite, and loses it **silently** — which
  is how the document sync in `AshHateoas.RootActions` came to be a
  delete-then-rewrite with nothing holding the two halves together.

  `Ash.transaction/2` is not the repair. It goes through that same check, so on
  SQLite it runs the body, opens nothing and reports success — a fix that reads
  correct in review and changes nothing. The boundary has to be the repo's own,
  which is the whole reason this module reaches into the resource's DSL for it.

  Measured rather than reasoned about: inside `Ash.transaction` on SQLite,
  `Repo.in_transaction?` is `false` and no `BEGIN` is logged; inside
  `Repo.transaction` it is `true` and the statement is there.
  """

  @doc """
  The DSL section a data layer keeps its table and repo under, or `nil` for one
  that keeps neither.

  Callers pass the data layer rather than the resource because a transformer has
  only the former — the resource is still compiling when it asks.
  """
  @spec section(module() | nil) :: :postgres | :sqlite | nil
  def section(AshPostgres.DataLayer), do: :postgres
  def section(AshSqlite.DataLayer), do: :sqlite
  def section(_data_layer), do: nil

  @doc """
  The repo `resource` is written through, or `nil` where there is no repo to
  find or nothing useful to do with it.

  Read from the DSL rather than from a persisted key, which `repo` is not. The
  `Ecto.Repo` check is deliberate: `repo` may be configured as something other
  than a plain module, and a boundary is only worth opening if it can be.
  """
  @spec repo(Ash.Resource.t()) :: module() | nil
  def repo(resource) do
    with section when not is_nil(section) <- section(Ash.DataLayer.data_layer(resource)),
         repo when is_atom(repo) and not is_nil(repo) <-
           Spark.Dsl.Extension.get_opt(resource, [section], :repo, nil),
         true <- Code.ensure_loaded?(repo) and function_exported?(repo, :transaction, 1) do
      repo
    else
      _ -> nil
    end
  end

  @doc """
  Runs `fun` with a rollback boundary around it, opening one only where the data
  layer will not open its own.

  `fun` returns `{:ok, result}` or `{:error, reason}`, and an error rolls the
  boundary back — so a caller writes the same two clauses it would have written
  without this, and the atomicity is the only difference.

  Where the data layer transacts, this does nothing: Ash already wraps the
  action, and a second boundary around the first would only move where the
  transaction begins. Where there is no repo either — ETS, and the test fixtures
  with it — `fun` runs as it always did. **Adding no boundary is the correct
  answer there**, not a fallback: a data layer with no transactions has none to
  lose, and the alternative is refusing to run at all.
  """
  @spec transaction(Ash.Resource.t(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def transaction(resource, fun) when is_function(fun, 0) do
    if Ash.DataLayer.data_layer_can?(resource, :transact) do
      fun.()
    else
      case repo(resource) do
        nil -> fun.()
        repo -> in_repo_transaction(repo, fun)
      end
    end
  end

  # `rollback/1` throws, which is how Ecto unwinds — so the error is returned
  # from `transaction/1` rather than by the function that produced it, and the
  # two shapes are flattened back into one here. A caller must not be able to
  # tell from the return value whether a boundary was opened.
  defp in_repo_transaction(repo, fun) do
    case repo.transaction(fn ->
           case fun.() do
             {:ok, result} -> result
             {:error, reason} -> repo.rollback(reason)
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end
end
