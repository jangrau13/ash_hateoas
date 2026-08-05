defmodule AshHateoas.Test.Scripted.Author do
  @moduledoc """
  A resource a script may reference. `name` carries an identity, which is what
  makes `author["Ada Lovelace"]` resolve to one record rather than to whichever
  the database happens to return.
  """

  use Ash.Resource,
    domain: AshHateoas.Test.Scripted,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshHateoas.Resource]

  ets do
    private?(true)
  end

  hateoas do
    type("scripted_author")
    warn_on_missing_authorizers?(false)
  end

  identities do
    identity(:unique_name, [:name], pre_check_with: AshHateoas.Test.Scripted)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true, allow_nil?: false)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule AshHateoas.Test.Scripted.Function do
  @moduledoc """
  A callable function, published as a resource so a client can *fetch* the
  signatures rather than being handed bare names it cannot check against.

  A row is a signature, never a definition — what the function does stays in
  code. Holding the behaviour as data would make the domain an interpreter.
  """

  use Ash.Resource,
    domain: AshHateoas.Test.Scripted,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshHateoas.Resource]

  ets do
    private?(true)
  end

  hateoas do
    type("scripted_function")
    warn_on_missing_authorizers?(false)
  end

  identities do
    identity(:unique_name, [:name], pre_check_with: AshHateoas.Test.Scripted)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true, allow_nil?: false)

    attribute(:arities, {:array, :integer},
      public?: true,
      allow_nil?: false,
      description: "How many arguments this accepts. `min` takes 2 through 8."
    )
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule AshHateoas.Test.Scripted.Formula do
  @moduledoc """
  Holds a script, and declares what that script may reference.
  """

  use Ash.Resource,
    domain: AshHateoas.Test.Scripted,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshHateoas.Resource, AshHateoas.LuaScript]

  ets do
    private?(true)
  end

  hateoas do
    type("formula")
    warn_on_missing_authorizers?(false)
  end

  lua do
    script(:body)
    bind(:author, AshHateoas.Test.Scripted.Author)
    functions(AshHateoas.Test.Scripted.Function)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true, allow_nil?: false)
    attribute(:body, AshHateoas.Type.Lua, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end
end

defmodule AshHateoas.Test.Scripted do
  @moduledoc """
  A domain exercising `AshHateoas.LuaScript`: a resource holding a script, the
  resources it may reference, and the functions it may call.
  """

  use Ash.Domain, extensions: [AshHateoas.Domain]

  resources do
    resource(AshHateoas.Test.Scripted.Author)
    resource(AshHateoas.Test.Scripted.Function)
    resource(AshHateoas.Test.Scripted.Formula)
  end
end
