defmodule AshHateoas.Document.Transformers.DeriveRootActions do
  @moduledoc """
  Generates `:validate` and `:save` on a resource declaring `aggregate_root?`.

      document do
        aggregate_root? true
      end

  That one line is the whole declaration. Both actions take a `document`
  argument carrying the aggregate as a flat list of elements.

  This transformer runs **before**
  `AshHateoas.Resource.Transformers.DeriveActionRoutes`, so the generated
  actions exist by the time routes are derived and are routed like any other
  action. That ordering is why they reach the wire as Hydra operations with no
  route declaration of their own.

  ## Why generic actions

  `:validate` is a **generic action**, which returns a value and therefore
  cannot write. The invariant a client depends on — that checking a document
  never leaves a trace — is enforced by the action type rather than by
  reviewing the body. That is what makes it safe to call on every editor save,
  and callable by an actor holding no write permission.

  `:save` is generic too, because it writes *many* resources rather than the
  one it is declared on; a `create` would be a claim about a single record.

  ## Both declare what they are for

  Each is given a `semantic_action` — `CheckAction` for `:validate`,
  `UpdateAction` for `:save` — so the wire states the operation's *role* rather
  than leaving a client to infer it. Both are POSTs, so without this the
  inferred type is `schema:CreateAction` for each, and a client can only tell
  them apart by matching the string `"validate"`. That is a naming convention
  two parties happen to share, not something the API says. See
  `declare_semantic_action/2` for why these two terms.

  ## Default, with deliberate override

  Both are added with `Ash.Resource.Builder.add_new_action/4`, which is a no-op
  when an action of that name already exists. A resource wanting different
  behaviour writes its own:

      actions do
        action :validate, :map do
          argument :document, {:array, :map}, allow_nil?: false
          run &MyApp.check/2
        end
      end

  and the generated one is never built. The declaration and the override live
  side by side rather than the author having to choose between "generated" and
  "hand-written" for the pair.

  ## More than one root per domain is allowed

  Deliberately unverified. A second root is a second document and therefore a
  second language, which is a coherent thing for a domain to offer — the two are
  told apart by the operation a client calls, not by a rule here. What would be
  wrong is a client having to *guess* which root to author, and nothing about
  two roots forces that: each advertises its own `:validate`.

  ## On the `document` argument's type

  `{:array, :map}` describes the argument as an array of *something*:
  `AshHateoas.TypeMapper.to_wire/1` has no inner type to report. `hateoas2dsl`
  does not need one — it derived the document's shape from the same API
  documentation — but a client reading only the wire cannot construct a call
  from this description.

  Typing it as a generated embedded-resource tree would fix that, since an
  embedded resource has real attributes for `AshHateoas.Descriptor` to walk.
  It is deliberately not done here: an embedded resource currently maps to
  `"string"` in `TypeMapper`, so the wire description would be no better until
  that and `Descriptor`'s recursion land. When they do, this one line changes
  and every aggregate root picks it up on recompile.

  Note that the *validation* does not depend on the choice.
  `AshHateoas.RootActions` casts each element individually, which reports every
  error in one pass; relying on an array cast would stop at the first bad
  element.
  """

  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias AshHateoas.Document.Info
  alias Spark.Dsl.Transformer

  @doc false
  def after?(_), do: false

  @doc false
  # Before routing: the actions must exist by the time routes are derived, or
  # they are never routed and never reach the wire. This is the whole reason
  # `:validate` and `:save` need no route declaration of their own.
  def before?(AshHateoas.Resource.Transformers.DeriveActionRoutes), do: true
  def before?(_), do: false

  @doc false
  def transform(dsl_state) do
    if Info.aggregate_root?(dsl_state) do
      with {:ok, dsl_state} <- add_action(dsl_state, :validate),
           {:ok, dsl_state} <- add_action(dsl_state, :save),
           {:ok, dsl_state} <- declare_method(dsl_state, :validate),
           {:ok, dsl_state} <- declare_method(dsl_state, :save),
           {:ok, dsl_state} <- declare_semantic_action(dsl_state, :validate),
           {:ok, dsl_state} <- declare_semantic_action(dsl_state, :save) do
        {:ok, dsl_state}
      end
    else
      {:ok, dsl_state}
    end
  end

  # A generic action declares no HTTP semantics, so `DeriveActionRoutes` assumes
  # POST and warns that it did. Here the assumption is not one: both actions
  # take a document in a body, and `:save` writes. Declaring the method says so
  # and silences a warning that would otherwise fire on every aggregate root
  # for something the author did not write and cannot fix.
  #
  # `:validate` is POST despite writing nothing: it is not safe to cache and
  # its input does not fit in a URL. The invariant that it never writes is
  # carried by the action type, not by the verb.
  defp declare_method(dsl_state, name) do
    if AshHateoas.Resource.Info.method(dsl_state, name) do
      {:ok, dsl_state}
    else
      with {:ok, entity} <-
             Transformer.build_entity(AshHateoas.Resource, [:hateoas], :method,
               action: name,
               method: :post
             ) do
        {:ok, Transformer.add_entity(dsl_state, [:hateoas], entity)}
      end
    end
  end

  # What the operation *is for*, declared rather than left to be guessed from
  # the verb.
  #
  # Without this both actions are POSTs, and `put_potential_action/3` infers
  # `schema:CreateAction` from the method — which says a document check creates
  # something. A client then has no way to tell the two apart except by matching
  # the string "validate", which is a naming convention two parties happen to
  # share rather than anything the API states. Declaring the type puts the role
  # on the wire, where a client can match on it.
  #
  # `schema:CheckAction` — "An agent inspects, determines, investigates,
  # inquires, or examines an object's accuracy, quality, condition, or state."
  # That is validation, and it sits under `FindAction`, which carries no
  # mutation semantics. Not `AssessAction`, whose siblings are `ReviewAction`
  # and `ReactAction`: that is forming an opinion, not checking a fact.
  #
  # `schema:UpdateAction` — "The act of managing by changing/editing the state
  # of the object", whose subtypes are Add/Replace/Delete. `:save` reconciles a
  # whole document against what exists, which is all three. `CreateAction` would
  # claim it only ever creates.
  #
  # Overridable like everything else here: a resource declaring its own
  # `semantic_action` for either keeps it.
  defp declare_semantic_action(dsl_state, name) do
    if Map.has_key?(AshHateoas.Resource.Info.semantic_actions(dsl_state), name) do
      {:ok, dsl_state}
    else
      with {:ok, entity} <-
             Transformer.build_entity(AshHateoas.Resource, [:hateoas], :semantic_action,
               action: name,
               iri: semantic_action_iri(name)
             ) do
        {:ok, Transformer.add_entity(dsl_state, [:hateoas], entity)}
      end
    end
  end

  defp semantic_action_iri(:validate), do: "CheckAction"
  defp semantic_action_iri(:save), do: "UpdateAction"

  defp add_action(dsl_state, name) do
    with {:ok, document} <- document_argument(),
         {:ok, id} <- id_argument(name) do
      Builder.add_new_action(dsl_state, :action, name,
        returns: :map,
        arguments: [document, id],
        run: run_for(name),
        description: description(name)
      )
    end
  end

  # `:save` writes the document's elements *into* an aggregate, so it needs to
  # know which one — the route is `/recipes/:id/save`, and the plug supplies
  # `:id` from the path. `:validate` accepts it too, since a document may be
  # checked against an existing aggregate, but does not require it: a document
  # can be validated before its root exists.
  defp id_argument(name) do
    Builder.build_action_argument(:id, :uuid,
      allow_nil?: name == :validate,
      public?: true,
      description: "The aggregate this document belongs to."
    )
  end

  # `:run` takes a module or a 2-arity function, not an MFA tuple.
  defp run_for(:validate), do: &AshHateoas.RootActions.validate/2
  defp run_for(:save), do: &AshHateoas.RootActions.save/2

  defp document_argument do
    Builder.build_action_argument(:document, {:array, :map},
      allow_nil?: false,
      public?: true,
      description: "The aggregate as a flat list of elements, each naming its class in `kind`."
    )
  end

  defp description(:validate) do
    "Check the whole document and report every problem. Writes nothing."
  end

  defp description(:save) do
    "Check the whole document and persist it."
  end
end
