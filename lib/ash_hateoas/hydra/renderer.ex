defmodule AshHateoas.Hydra.Renderer do
  @moduledoc """
  Projects the affordance envelope onto a resource node's Hydra operations.

  Each affordance becomes a `hydra:Operation` (`@type: "Operation"`,
  `hydra:method`, and — for a write — a `hydra:expects` describing the input as a
  `hydra:Class` with one `hydra:SupportedProperty` per field, plus a
  `hydra:returns` naming the resulting class). A collection read with query
  arguments becomes a `hydra:IriTemplate`.

  Terms are emitted with the `hydra:` prefix. The referenced `@context` maps both
  `hydra:method` and a bare `method` to the same core-vocabulary IRI, so the two
  are equivalent after JSON-LD expansion; the prefixed form is kept because it is
  unambiguous to a raw-JSON reader that does not expand the context (see
  `documentation/hydra-conformance-notes.md`).

  ## What a node's operation says, and what it does not

  **`@type` and `ah:href`, and nothing else.** Those are the two facts that vary
  per request; everything else about an operation holds in every state and for
  every actor, so it is stated once in the `ApiDocumentation` rather than on each
  response.

  | on an operation | varies | why |
  |---|---|---|
  | its presence in `hydra:operation` | **yes** | `Ash.can?/3` and the state gate decide it per request |
  | `ah:href` | **yes** | the record's own id is in it |
  | `hydra:method` | no | a property of the action |
  | `hydra:expects` | no | `AshHateoas.Descriptor` reads the action's `accept` and its public arguments, both declared on the action |
  | `hydra:returns` | no | the class the action yields |
  | `hydra:title` | no | the action's description |

  The class in `@type` is the key that joins the two documents, which is what it
  was minted for. On a captured API 40 node operations occupied 22,354 bytes and
  occupy 6,729 carrying the two keys — the same 13 responses were repeating 92
  statements the catalogue already made once.

  **The rule is not "a node never states a shape".** It is:

  > the catalogue states the shape; a node may restate it; a node that says
  > nothing means the catalogue's answer stands.

  Nothing in Ash makes an action's accepted input depend on a record's state
  today, since `accept` and `arguments` are declared on the action. If that
  changes, or an application wants to narrow an input for one state, the node is
  where the narrower statement belongs — and `operation/2` is still the function
  that builds it. That is one rule a client implements once, and it leaves room
  for the case without paying for it on every response.

  **What this costs.** A node stops being readable on its own: anything holding
  one response and no catalogue — a test, a log line, a client that ignored the
  `Link` header — can no longer say what a request to that operation looks like.
  Every response carries `Link: <…>; rel="…apiDocumentation"`, and the catalogue
  is one fetch, cacheable, and the same document for every actor. That header is
  **load-bearing** now rather than a convenience, so a path that omits it is a
  correctness bug.

  ## Where an operation attaches

  Every affordance is one entry in the node's `hydra:operation`, and the array is
  the only place to look.

  **Every operation states where it is invoked, as `ah:href`.** Hydra core mints
  no term for it — `hydra:Operation` describes a method, an input and an output
  and never a target — which is a gap in the vocabulary rather than a statement
  that an operation has no target. It plainly has one: a client cannot invoke
  anything without a URL.

  The gap used to be filled by a *rule* — "an operation is invoked against the
  node it hangs on" — with `ah:href` written only where that rule did not hold.
  That made the common case implicit: an operation lifted out of its node, logged,
  queued or handed to another process, no longer said where it went. So the rule
  is materialised instead, and an operation is self-contained: read `ah:href`,
  send there. Nothing has to know how the entry was reached.

  A named sub-action (`/:id/approve`) states its own URL the same way; it is no
  longer a special case, only a different value.

  The sub-action used to be a link property (`ah:<action>`) wrapping a
  single-element `hydra:operation`, which named the action twice — once as the
  key, once as `ah:action` — and left a client two traversal paths for one
  question. The wrapper's one benefit was that the URL sat on a followable edge,
  and it was not real: `AshHateoas.Hydra.Plug` routes a sub-action path through
  `match_write/3` only, so a GET on it is a 404. See
  `documentation/change-request-flat-operations.md`.

  ## The edge inversions

  `AshHateoas.Field` carries Ash's `allow_nil?`; Hydra says `hydra:required`, so
  the inversion happens here. A sensitive field's `default` is never emitted.
  Atoms are stringified so the map survives `Jason.encode!/1`.
  """

  alias AshHateoas.{Affordance, Field}
  alias AshHateoas.Hydra.{Context, TypeMapper}

  @doc """
  Render an affordance envelope into the members to merge onto a node.

  Returns a map with one `"hydra:operation"` list holding every affordance, and
  an `"odrl:permission"` list stating the same set as policy. Every operation
  carries the URL it is invoked against as `ah:href`.

  ## Options

    * `:node_id` — the resource node's `@id` (its own URL), used as an
      operation's target where the affordance derived none of its own.
    * `:type` — the resource type string, used to build property IRIs.
    * `:path_params` — substituted into hrefs (`%{"id" => "123"}`).
    * `:prefix` — external mount prefix prepended to every href.
  """
  @spec render(%{atom() => Affordance.t()}, keyword()) :: map()
  def render(affordances, opts \\ []) do
    node_id = Keyword.get(opts, :node_id)

    operations =
      Enum.map(affordances, fn {_name, affordance} ->
        %{"@type" => operation_type(affordance, opts)}
        |> put_href(href(affordance, opts) || node_id)
      end)

    case operations do
      [] -> %{}
      ops -> %{"hydra:operation" => ops}
    end
    |> put_permissions(affordances, opts)
  end

  # Where the operation is invoked. **Always stated**, including where it is the
  # node's own `@id`.
  #
  # Writing it only for a sub-action left the common case resting on a rule the
  # document never states — "invoke against the node this hangs on" — which holds
  # only while the operation is still attached to that node. Lift one out to log
  # it, queue it, or hand it to another process, and it no longer says where it
  # goes. Materialising the rule costs one term per operation and makes an
  # operation mean the same thing wherever it is read.
  #
  # Omitted only when there is nothing to say: no href was derived and no node
  # URL was supplied, which is the `ApiDocumentation`'s case — it describes a
  # class rather than a record, so there is no instance to invoke anything
  # against and a template URL would be a different statement.
  defp put_href(op, nil), do: op
  defp put_href(op, href), do: Map.put(op, "ah:href", %{"@id" => href})

  # The granted affordance set, projected as an ODRL permission list — the W3C
  # standard for "what this party may do to this asset". A fail-closed surface
  # (denied actions are omitted, never carried) has no basis for an
  # `odrl:Prohibition`, so this is permission-only: every present affordance is
  # one `odrl:Permission`, and a `not_delegable?` action carries an `odrl:Duty`
  # (the action commits, so a committing credential is required to discharge it).
  defp put_permissions(node, affordances, _opts) when map_size(affordances) == 0, do: node

  defp put_permissions(node, affordances, opts) do
    node_id = Keyword.get(opts, :node_id)

    # The asset a permission is about is the URL the action is invoked on, so a
    # sub-action targets **its own** URL rather than the record's. Defaulting to
    # the node would say the actor may `odrl:modify` the record itself, when what
    # was granted is one named transition on it — and with the operations now
    # flat, the target is the only thing left distinguishing two permissions that
    # share an ODRL action term.
    permissions =
      affordances
      |> Map.values()
      |> Enum.map(&permission(&1, href(&1, opts) || node_id, opts))

    Map.put(node, "odrl:permission", permissions)
  end

  defp permission(%Affordance{} = affordance, target, opts) do
    perm = %{
      "@type" => "odrl:Permission",
      "odrl:action" => %{"@id" => odrl_action(affordance.method)}
    }

    # Which operation this permission is *about*, as the same class IRI that
    # operation carries in its `@type`. Without it the two lists cannot be
    # joined: ODRL actions are a five-term vocabulary, so an `update` and a
    # `close_sitting` are both `odrl:modify`, and a consumer wanting the duty
    # attached to one named action had nothing to match on. `odrl:target`
    # distinguishes a sub-action from the record but not two operations on the
    # record itself.
    #
    # An IRI rather than the bare string it used to be, for the same reason the
    # operation's own identity is one: a permission that names its operation by
    # a local word can only be joined by a consumer that already knows this
    # API's words. `ah:action` stays an `owl:AnnotationProperty`, which may take
    # an IRI as its value without any description-logic consequence — the class
    # is being *mentioned* here, not used.
    perm =
      case Keyword.get(opts, :type) do
        nil ->
          perm

        type ->
          Map.put(perm, "ah:action", %{"@id" => Context.action_class_iri(type, affordance.name)})
      end

    perm =
      if affordance.not_delegable? do
        duty = %{
          "@type" => "odrl:Duty",
          "odrl:action" => %{"@id" => "odrl:obtainConsent"}
        }

        Map.put(perm, "odrl:duty", [duty])
      else
        perm
      end

    put_unless_nil(perm, "odrl:target", target && %{"@id" => target})
  end

  # ODRL action terms (Common Vocabulary) for each HTTP method. `read`/`modify`/
  # `delete` are defined actions; a create/generic `use`s the asset (ODRL has no
  # dedicated create action).
  defp odrl_action(:get), do: "odrl:read"
  defp odrl_action(:post), do: "odrl:use"
  defp odrl_action(:patch), do: "odrl:modify"
  defp odrl_action(:put), do: "odrl:modify"
  defp odrl_action(:delete), do: "odrl:delete"
  defp odrl_action(_other), do: "odrl:use"

  @doc "Render one affordance as a `hydra:Operation` node."
  @spec operation(Affordance.t(), keyword()) :: map()
  def operation(%Affordance{} = affordance, opts \\ []) do
    %{
      "@type" => operation_type(affordance, opts),
      "hydra:method" => affordance.method |> to_string() |> String.upcase()
    }
    |> put_unless_nil("hydra:title", affordance.description)
    |> put_expects(affordance, opts)
    |> put_returns(affordance, opts)
  end

  # **The operation's identity, as an IRI.**
  #
  # `"Operation"` alone separates nothing: every operation this package emits
  # carries it, so what actually distinguished them was `ah:action`, a bare
  # string. A string cannot be dereferenced, cannot be a subclass of anything,
  # and cannot be the target of an annotation — and it is local, so a consumer
  # meeting two APIs each with an `approve` has no way to tell whether they are
  # the same kind of thing. The class minted here is all three.
  #
  # It says the operation **is** an instance of that class, where
  # `schema:potentialAction` said the operation *has* one. The stronger reading
  # is the accurate one: the node is the offer to act, not a thing with an
  # action hanging off it — and `schema:potentialAction` is defined with domain
  # `Thing` and range `Action`, which makes an `Operation` an awkward subject
  # for it. So `schema:potentialAction` is gone, and a declared
  # `semantic_action` becomes `rdfs:subClassOf` on the minted class instead
  # (`AshHateoas.Hydra.Ontology`), where it is an axiom stated once rather than
  # a fact repeated on every response.
  #
  # **Nothing here is inferred from the HTTP method**, which is the rule
  # `put_potential_action/3` was written to keep and this keeps unchanged. The
  # class comes from the action's own name, which the method does not carry: two
  # `update`-shaped actions on one resource are both `PATCH` returning the same
  # class, so the method cannot separate them and the name can. Minting an IRI
  # for something the payload already named as a string adds no claim about what
  # the operation is *for*; it gives the name an address.
  #
  # Without a resource type there is no vocabulary to mint under, so the bare
  # Hydra type is all that can honestly be said.
  defp operation_type(%Affordance{name: name}, opts) do
    case Keyword.get(opts, :type) do
      nil -> "Operation"
      type -> ["Operation", Context.action_class_iri(type, name)]
    end
  end

  # ## Why there is no `schema:target`, and no CRUD subtype
  #
  # Kept as a note because both were once emitted and the reasoning still binds
  # what may be added back.
  #
  # **A role a method already implies states nothing.** No subtype is inferred
  # from the HTTP verb: deriving `schema:ReadAction` from a GET would be a
  # second spelling of `hydra:method` on the same node, which is only a chance
  # for two spellings to disagree. What a `semantic_action` declares —
  # `CheckAction`, `ConfirmAction`, `ShipAction`, and this library's own
  # `SaveAction`/`RunAction` for roles no published vocabulary carries — is
  # stated as a superclass of the operation's own class, in the ontology.
  #
  # **`schema:target`** would restate what is already here: where the operation
  # acts is the node it hangs on, or `ah:href` where that is not the node; the
  # method is `hydra:method`; the content type is the API's rather than this
  # operation's. `ah:href` carries the one genuinely unstated thing because
  # `schema:target` ranges over `schema:EntryPoint`, a whole second model of an
  # invocation for the sake of one URL.
  #
  # `schema:target` would also be ill-typed for a *templated* route:
  # `schema:urlTemplate` is defined as *"an url template (RFC6570)"*, and a Plug
  # route is not one — RFC 6570 gives `:` no meaning, so an expander finds zero
  # variables and hands back a literal `:id`. A templated URL is stated once,
  # properly, as a `hydra:IriTemplate`.

  # ## An omitted `hydra:expects` is not a statement
  #
  # An operation whose action takes nothing used to carry no `hydra:expects` at
  # all, and in a captured API that was 71 of 115 operations — 17 of them
  # `PATCH`. A client reading one could not tell **"send an empty body"** from
  # **"this document does not describe the body"**, because absence in RDF is the
  # absence of a statement rather than a negative statement. The request it then
  # generates is a guess, and for a write it is a guess about a write.
  #
  # So an operation whose method can carry one declares its input class even when
  # that class has no properties. *"These are the properties, and there are
  # none"* is a statement: a client draws no form, posts an empty body, and knows
  # that is what the server wants.
  #
  # **Not `owl:Nothing`**, although `put_returns/3` reserves it for a response
  # with no body. `hydra:expects owl:Nothing` says an instance of the empty class
  # is expected, which is unsatisfiable — it reads as "no valid request to this
  # operation exists". That is right on the way out, where nothing comes back,
  # and wrong on the way in, where an empty body is a perfectly valid request.
  # The two directions are not symmetric.
  #
  # **`GET` and `DELETE` are left alone**, and that is not an oversight. RFC 9110
  # says a client should not generate content in a `GET`, and a `DELETE` body has
  # no defined semantics, so silence there is already unambiguous. A `GET` with
  # arguments is a query interface and states an `IriTemplate`; a `DELETE` whose
  # action takes arguments still describes them, since otherwise a client could
  # not send what the action requires.
  @body_methods [:post, :patch, :put]

  defp put_expects(op, %Affordance{method: :get, fields: []}, _opts), do: op

  defp put_expects(op, %Affordance{method: :get} = affordance, opts) do
    Map.put(op, "hydra:expects", iri_template(affordance, opts))
  end

  defp put_expects(op, %Affordance{method: method, fields: []} = affordance, opts)
       when method in @body_methods do
    Map.put(op, "hydra:expects", input_class([], affordance, opts))
  end

  defp put_expects(op, %Affordance{fields: []}, _opts), do: op

  defp put_expects(op, %Affordance{} = affordance, opts) do
    Map.put(op, "hydra:expects", input_class(affordance.fields, affordance, opts))
  end

  # `hydra:expects` ranges over a Class. The input class is given its own `@id`
  # (`<class>/<action>Input`) so it is a referenceable node rather than an
  # anonymous blank node a client cannot point back at — and so
  # `AshHateoas.Hydra.ApiDocumentation` can declare it, which is what keeps the
  # ontology's invariant true of every IRI a document references.
  defp input_class(fields, %Affordance{} = affordance, opts) do
    type = Keyword.get(opts, :type)

    %{
      "@type" => "Class",
      "hydra:supportedProperty" => Enum.map(fields, &supported_property(&1, type))
    }
    |> put_unless_nil("@id", input_class_iri(type, affordance.name))
  end

  # `hydra:returns` ranges over a Class, and names the resource's own class for
  # every operation that yields a record — including a **destroy**, which
  # returns the record it destroyed. Without a known type we cannot name the
  # class, so we omit it rather than guess.
  #
  # A destroy sends the record's final state rather than 204 with an empty
  # body, so the declaration names its class: a client wanting to show what it
  # deleted would otherwise have to GET first and hold the result across the
  # delete, when Ash offers the record for the asking.
  #
  # `owl:Nothing` is reserved for the `:ok`-with-no-record path, which sends no
  # body at all: it is the *empty class*, so "an instance of this is returned"
  # is unsatisfiable — the honest reading of "no body". Hydra itself says
  # nothing on the matter; the token appears zero times in the vocabulary,
  # `core.jsonld` and the spec prose. See
  # `documentation/hydra-conformance-notes.md` §5.
  defp put_returns(op, %Affordance{} = affordance, opts) do
    cond do
      # A document action returns a verdict, not the resource. Naming the
      # resource's class here was simply wrong: a validate writes nothing and
      # has no record to give back, and a save reports failures the same way
      # rather than returning an aggregate it did not write. Both consumers
      # hardcode the envelope's shape today because the wire never stated it.
      document_action?(affordance, opts) ->
        Map.put(op, "hydra:returns", %{"@id" => Context.vocab_iri("ValidationReport")})

      true ->
        case Keyword.get(opts, :type) do
          nil -> op
          type -> Map.put(op, "hydra:returns", %{"@id" => Context.class_iri(type)})
        end
    end
  end

  # Read from the action's *declared role*, never from its name. `validate` and
  # `save` are the names this package happens to generate; a domain may rename
  # either, and a client is told what an operation is for by the type on its
  # `schema:potentialAction`. So the same statement that tells a client decides
  # this, and a hand-written action carrying the role is treated identically.
  @document_roles ["https://schema.org/CheckAction", "SaveAction"]

  defp document_action?(%Affordance{name: name}, opts) do
    case Keyword.get(opts, :semantic_actions, %{})[name] do
      iri when is_binary(iri) -> Enum.any?(@document_roles, &String.ends_with?(iri, &1))
      _ -> false
    end
  end

  @doc "Render one field as a `hydra:SupportedProperty`."
  @spec supported_property(Field.t(), String.t() | nil) :: map()
  def supported_property(%Field{} = field, type \\ nil) do
    %{
      "@type" => "SupportedProperty",
      "hydra:property" => property_ref(field, type),
      # Ash says allow_nil?; the wire says required. The inversion lives here.
      "hydra:required" => not field.allow_nil?,
      "hydra:readable" => false,
      "hydra:writable" => true
    }
    |> put_unless_nil("hydra:title", to_string_or_nil(field.name))
    |> put_unless_nil("hydra:description", field.description)
    # `hydra:property` ranges over rdf:Property, so its value is the property
    # reference itself — the value's type is a fact about the property, not
    # about this reference, so it rides alongside under a standard ontology
    # term instead of mistyping the reference.
    |> put_type_info(field)
    |> put_default(field.default)
    |> put_sh_in(field.constraints)
  end

  @doc """
  Render a query/search read's fields as a `hydra:IriTemplate`.

  The template's whole job is to tell a client the URL to build, so a path
  segment still holding a router placeholder would defeat it: `:id` is Plug's
  spelling, not RFC 6570's. On a served node the placeholder is already
  substituted with the record's own id, since the affordance was built for that
  record; in the ApiDocumentation, which describes a class rather than an
  instance, it survives — and becomes `{id}`, a variable the client supplies
  like any other.

  A template with **no** variables is still a template. A collection route
  (`/exam`) is a constant string, and emitting it as one rather than as a second
  shape is what keeps a client reading one key the same way for every operation.
  Its `hydra:mapping` is omitted rather than emitted empty: an empty JSON-LD
  array states nothing, so the key would be present in the JSON and absent from
  the graph — the silent-drop this package tests for elsewhere.
  """
  @spec iri_template(Affordance.t(), keyword()) :: map()
  def iri_template(%Affordance{} = affordance, opts) do
    href = affordance |> href(opts) |> Kernel.||("") |> path_variables()
    variables = Enum.map(affordance.fields, &to_string(&1.name))
    type = Keyword.get(opts, :type)

    mappings =
      Enum.map(affordance.fields, &iri_template_mapping(&1, type)) ++
        path_mappings(href, type, variables)

    %{
      "@type" => "IriTemplate",
      "hydra:template" => href <> template_suffix(variables),
      "hydra:variableRepresentation" => "BasicRepresentation"
    }
    |> put_mapping(mappings)
  end

  defp put_mapping(template, []), do: template
  defp put_mapping(template, mappings), do: Map.put(template, "hydra:mapping", mappings)

  # Plug's router spelling → RFC 6570's, for both `hydra:template` and
  # `schema:urlTemplate`:
  #
  #     /multi_read/:id/by_id            → /multi_read/{id}/by_id
  #     /ledger/:ledger_id/entry/:id     → /ledger/{ledger_id}/entry/{id}
  #
  # An owned resource's route carries two placeholders (stage 5's nesting), so
  # this substitutes every one rather than only the record's own — a template
  # that expanded `id` and left `{ledger_id}` behind would resolve to nothing.
  #
  # The scheme and authority are untouched: `:` there is the URL's own and
  # matches no variable name, since a name cannot start with `//`.
  defp path_variables(href), do: Regex.replace(~r/:([a-zA-Z_][a-zA-Z0-9_]*)/, href, "{\\1}")

  # A path variable is a variable the client must supply, so it belongs in the
  # mapping beside the query ones — otherwise the template names something the
  # document never describes. Always required: a path segment cannot be omitted
  # the way a query parameter can.
  #
  # `already` excludes the query fields, which are mapped from the affordance
  # itself and carry their real types and requiredness. Without it a route whose
  # path segment shares a name with one of its own arguments is described twice
  # — `/multi_read/{id}/by_id{?id}` emitted two mappings for `id`, one claiming
  # required and one not, which is worse than either alone.
  defp path_mappings(template, type, already) do
    seen = MapSet.new(already)

    ~r/\{([a-zA-Z_][a-zA-Z0-9_]*)\}/
    |> Regex.scan(template, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(seen, &1))
    |> Enum.map(fn name ->
      %{
        "@type" => "IriTemplateMapping",
        "hydra:variable" => name,
        "hydra:property" => property_ref(%Field{name: name}, type),
        "hydra:required" => true
      }
    end)
  end

  @doc "Render one field as a `hydra:IriTemplateMapping`."
  @spec iri_template_mapping(Field.t(), String.t() | nil) :: map()
  def iri_template_mapping(%Field{} = field, type \\ nil) do
    %{
      "@type" => "IriTemplateMapping",
      "hydra:variable" => to_string(field.name),
      "hydra:property" => property_ref(field, type),
      "hydra:required" => not field.allow_nil?
    }
    |> put_type_info(field)
  end

  # `hydra:property` ranges over `rdf:Property`, so its value is a reference to
  # the property — `{"@id": iri}` — not the value's datatype. Without a resource
  # type we fall back to the bare field name as the identifier.
  defp property_ref(%Field{} = field, type) do
    iri = if type, do: Context.property_iri(type, field.name), else: to_string(field.name)
    %{"@id" => iri}
  end

  # The `@id` for a write operation's input `hydra:Class`. Named per action so two
  # writes on the same resource (create vs a custom action) are distinct classes.
  defp input_class_iri(nil, _action_name), do: nil

  defp input_class_iri(type, action_name),
    do: Context.class_iri(type) <> "/" <> to_string(action_name) <> "Input"

  defp template_suffix([]), do: ""
  defp template_suffix(variables), do: "{?" <> Enum.join(variables, ",") <> "}"

  # A sensitive argument's default is :error and must never reach the wire.
  defp put_default(map, {:ok, value}), do: Map.put(map, "sh:defaultValue", encodable(value))
  defp put_default(map, :error), do: map

  # An enum's permitted values, as the `rdf:List` SHACL requires.
  #
  # `@list` is not decoration. A bare JSON-LD array has **unordered set**
  # semantics and expands to one independent triple per value:
  #
  #     _:b0 sh:in "g" .        _:b0 sh:in "ml" .       _:b0 sh:in "piece" .
  #
  # whereas `sh:in` is defined to take an `rdf:List` — a `rdf:first`/`rdf:rest`
  # chain ending in `rdf:nil`, which is what `@list` produces. Three loose
  # statements are not that list, so the shape is **ill-formed**.
  #
  # That is not a quiet degradation. SHACL §2.1.1 makes a node carrying a
  # parameter an *implicitly declared shape*, so these `SupportedProperty` nodes
  # become shapes whether or not anyone meant them to; and §3.4.2 says a
  # processor **SHOULD produce a failure** for an ill-formed shapes graph —
  # failing the run rather than skipping the offending shape, taking
  # well-formed shapes elsewhere down with it.
  #
  # Two smaller gains follow: the values keep their declared order, which a set
  # does not guarantee, and the enumeration becomes one object a consumer can
  # follow rather than triples it must gather and hope it found all of.
  defp put_sh_in(map, constraints) when map_size(constraints) == 0, do: map

  defp put_sh_in(map, constraints) do
    case constraints[:enum] do
      nil -> map
      values -> Map.put(map, "sh:in", %{"@list" => Enum.map(values, &encodable/1)})
    end
  end

  defp put_type_info(map, %Field{type: "union", constraints: constraints}) do
    case constraints[:union_types] do
      nil ->
        map

      types ->
        iris =
          types
          |> Enum.map(fn {_name, wire} -> TypeMapper.wire_to_iri(wire) end)
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&%{"@id" => &1})

        Map.put(map, "schema:rangeIncludes", iris)
    end
  end

  # An array whose elements are instances of known classes says which, rather
  # than stopping at "an array of something".
  #
  # The classes are named as links, so a client that can already follow one
  # reads this with nothing new, and each is described in full elsewhere in the
  # same document. That is the hypermedia answer to "what goes in here": link to
  # the description rather than inlining a copy that can drift.
  #
  # ## One class states it; several need `sh:or`
  #
  # `sh:class` applies to **each value node individually**, and here the value
  # nodes are the array's elements. So repeating it — which a bare JSON-LD array
  # does, expanding to one independent triple per class — asserts a
  # **conjunction**: every element must be a Step *and* an Ingredient *and* a
  # Technique at once. Nothing satisfies that, so a document that is perfectly
  # valid fails.
  #
  # What is meant is a disjunction: an element is a Step *or* an Ingredient *or*
  # a Technique. `sh:or` is SHACL's term for it, taking an `rdf:List` of
  # **shapes** (hence `%{"sh:class" => …}` per member, not a bare IRI) — so the
  # `@list` coercion is required here for the same reason as on `sh:in`.
  #
  # Verified against a SHACL processor rather than reasoned about: an element
  # typed `Step` fails the bare form, fails `sh:and`, and conforms only under
  # `sh:or`.
  defp put_type_info(map, %Field{type: "array", constraints: constraints}) do
    map = Map.put(map, "rdfs:range", %{"@id" => "jsonschema:ArraySchema"})

    case constraints[:element_classes] do
      [iri] ->
        Map.put(map, "sh:class", %{"@id" => iri})

      [_ | _] = iris ->
        Map.put(map, "sh:or", %{"@list" => Enum.map(iris, &%{"sh:class" => %{"@id" => &1}})})

      _ ->
        map
    end
  end

  defp put_type_info(map, %Field{type: type} = field) do
    case TypeMapper.type_info(type) do
      {:sh_datatype, iri} -> map |> Map.put("sh:datatype", iri) |> put_script_language(field)
      {:sh_node_kind, kind} -> Map.put(map, "sh:nodeKind", kind)
      {:rdfs_range, iri} -> Map.put(map, "rdfs:range", %{"@id" => iri})
      :union -> map
      :none -> map
    end
  end

  # `ah:Script` says the value is code; this says which language, and the two
  # are one statement split in half. A client told only the first knows to stop
  # rendering a formula as prose and still cannot parse, highlight or complete
  # it — the grammar is the actionable part.
  #
  # It rides on the usage site rather than being looked up, for the same reason
  # `sh:datatype` does: an argument is not a property of any class, so the
  # ontology declares nothing about it. Where the property *is* declared — a
  # class attribute — `AshHateoas.Hydra.Ontology` states the same fact against
  # the declaration, and both read it from the type.
  defp put_script_language(map, %Field{script_language: language})
       when is_binary(language),
       do: Map.put(map, "ah:scriptLanguage", language)

  defp put_script_language(map, _field), do: map

  defp href(%Affordance{href: nil}, _opts), do: nil

  defp href(%Affordance{href: path}, opts) do
    path
    |> substitute(Keyword.get(opts, :path_params, %{}))
    |> prepend(Keyword.get(opts, :prefix))
  end

  defp substitute(path, path_params) when map_size(path_params) == 0, do: path

  defp substitute(path, path_params) do
    Enum.reduce(path_params, path, fn {key, value}, acc ->
      String.replace(acc, ":#{key}", to_string(value))
    end)
  end

  defp prepend(path, nil), do: path
  defp prepend(path, ""), do: path
  defp prepend(path, prefix), do: String.trim_trailing(prefix, "/") <> path

  # Atoms and other terms must survive Jason.encode!/1.
  defp encodable(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: to_string(value)

  defp encodable(value) when is_list(value), do: Enum.map(value, &encodable/1)
  defp encodable(value), do: value

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
