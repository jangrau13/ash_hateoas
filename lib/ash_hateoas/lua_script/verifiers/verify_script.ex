defmodule AshHateoas.LuaScript.Verifiers.VerifyScript do
  @moduledoc """
  Compile-time checks for the `lua` section.

  Three, and each catches a way the extension would otherwise do nothing while
  appearing to be configured:

    * **`script` names an attribute that exists.** A renamed attribute should
      fail the build rather than silently stop being a script.

    * **That attribute is typed `AshHateoas.Type.Lua`.** The type is what parses
      the source and what puts `ah:Script` on the wire, so pointing `script` at
      a plain `:string` leaves every value unparsed and the wire saying it is
      prose — configured, and inert.

    * **A bind's key names an attribute of its resource.** A subscript matches
      on that attribute, so a key naming nothing means every reference under
      that bind fails to resolve at runtime, for a reason nothing states.

    * **That key is unique.** A reference names one record. If two can share the
      key, `author["Ada"]` resolves to whichever the database returns first —
      the same script meaning different things at different times, with nothing
      reporting it. A *composite* identity does not satisfy this: a name unique
      only within a parent still matches several records when the parent is not
      named, and a reference does not name one.

  Two binds may not share a name: the second would shadow the first, and which
  one wins is not something an author should have to know.

  Every check is a way the section could be configured and inert — the failure
  mode being a script that looks bound and resolves to nothing, or to the wrong
  thing. That is why they are compile-time rather than runtime.
  """

  use Spark.Dsl.Verifier

  alias AshHateoas.LuaScript.Info
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)

    with :ok <- verify_script_attribute(dsl_state, module),
         :ok <- verify_unique_binds(dsl_state, module) do
      verify_bind_keys(dsl_state, module)
    end
  end

  defp verify_script_attribute(dsl_state, module) do
    name = Info.script(dsl_state)

    case Ash.Resource.Info.attribute(dsl_state, name) do
      nil ->
        error(module, :script, """
        `script #{inspect(name)}` names an attribute that does not exist.

        Declare it, typed `AshHateoas.Type.Lua`:

            attribute #{inspect(name)}, AshHateoas.Type.Lua, public?: true
        """)

      %{type: type} ->
        if lua?(type) do
          :ok
        else
          error(module, :script, """
          `script #{inspect(name)}` names an attribute typed #{inspect(type)}.

          It must be `AshHateoas.Type.Lua`. That type is what parses the source
          on write and what declares the property `ah:Script` on the wire — with
          any other type the value is never parsed and a client is told the
          value is prose, so this section would be configured and inert.
          """)
        end
    end
  end

  # `Ash.Type.get_type/1` resolves a short name and passes a module through, so
  # both spellings of the same type answer alike.
  defp lua?(type) do
    Ash.Type.get_type(type) == AshHateoas.Type.Lua
  rescue
    # `get_type/1` raises on an atom that names no type.
    _ -> false
  end

  defp verify_unique_binds(dsl_state, module) do
    duplicates =
      dsl_state
      |> Info.binds()
      |> Enum.frequencies_by(& &1.name)
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    case duplicates do
      [] ->
        :ok

      names ->
        error(module, :bind, """
        More than one `bind` uses #{Enum.map_join(names, ", ", &inspect/1)}.

        A subscript resolves to one resource. With two declarations the second
        shadows the first, and which one wins is not something an author should
        have to know — so name each bind once.
        """)
    end
  end

  defp verify_bind_keys(dsl_state, module) do
    dsl_state
    |> Info.binds()
    |> Enum.reduce_while(:ok, fn bind, :ok ->
      cond do
        not bind_key_exists?(bind) ->
          {:halt,
           error(module, :bind, """
           `bind #{inspect(bind.name)}, #{inspect(bind.resource)}` matches on
           #{inspect(bind.key)}, which #{inspect(bind.resource)} does not declare.

           A subscript resolves by that attribute, so every reference under this
           bind would fail to resolve — with nothing saying why. Name the
           resource's own naming key, the one `ah:identity` publishes.
           """)}

        not bind_key_unique?(bind) ->
          {:halt,
           error(module, :bind, """
           `bind #{inspect(bind.name)}, #{inspect(bind.resource)}` matches on
           #{inspect(bind.key)}, which is not unique on #{inspect(bind.resource)}.

           A reference names one record. If two records can share
           #{inspect(bind.key)}, then #{bind.name}["…"] resolves to whichever the
           database returns first — so the same script means different things at
           different times, and nothing reports it.

           Declare it:

               identities do
                 identity :unique_#{bind.key}, [#{inspect(bind.key)}]
               end

           A primary key satisfies this too. If the key is only unique *within*
           some parent, it cannot key a reference on its own — bind a resource
           whose key stands alone.
           """)}

        true ->
          {:cont, :ok}
      end
    end)
  end

  # A destination still compiling cannot answer, and forcing it here would
  # deadlock the build. Treat an unanswerable case as fine: the check exists to
  # catch a typo, not to be the only guard.
  defp bind_key_exists?(bind) do
    not is_nil(Ash.Resource.Info.attribute(bind.resource, bind.key))
  rescue
    _ -> true
  end

  # A reference names **one** record, so the key it matches on has to be able to
  # pick one out. An identity over exactly that attribute says so; so does the
  # primary key.
  #
  # A *composite* identity does not, and that is the case worth being careful
  # about: `[:model_id, :name]` makes a name unique within a model, so `name`
  # alone still matches several records. A reference carries no model, so it
  # cannot use that identity — which is why the check is for an identity whose
  # key set is exactly `[key]` rather than one that merely mentions it.
  defp bind_key_unique?(bind) do
    primary_key = Ash.Resource.Info.primary_key(bind.resource)

    identities =
      bind.resource
      |> Ash.Resource.Info.identities()
      |> Enum.map(& &1.keys)

    Enum.any?([primary_key | identities], &(&1 == [bind.key]))
  rescue
    # A resource still compiling cannot answer, and forcing it here would
    # deadlock the build. An unanswerable case passes: this catches a
    # declaration that is wrong on its face, and is not the only guard.
    _ -> true
  end

  defp error(module, path, message) do
    {:error,
     Spark.Error.DslError.exception(
       module: module,
       path: [:lua, path],
       message: message
     )}
  end
end
