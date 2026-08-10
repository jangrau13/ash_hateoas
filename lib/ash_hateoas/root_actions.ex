defmodule AshHateoas.RootActions do
  @moduledoc """
  The bodies of the `:validate` and `:save` actions generated for an aggregate
  root. See `AshHateoas.DslRoot.Transformers.DeriveRootActions`.

  A document is a **flat list of elements**. Each element names its class in a
  `kind` key and carries that class's attributes alongside:

      [
        %{"kind" => "stock", "name" => "Susceptible", "initial_value" => "9990"},
        %{"kind" => "flow",  "name" => "Recovery", "from" => "Infected", "to" => "Recovered"}
      ]

  Flat rather than nested because a domain graph *is* a graph: the same element
  is referenced from several places, and nesting would force a spanning tree
  onto it, making an arbitrary choice about which edge gets to be containment.

  ## Two classes of error, which is why one call carries the whole document

    * **Per-element** — from the element's own `create` changeset. The domain's
      own validations, constraints and `allow_nil?` are picked up for free;
      nothing about them is restated here.
    * **Cross-element** — a flat pass over the whole list. A duplicate name or a
      dangling reference is not a property of any single changeset, so it can
      only be found with every element in hand.

  ## Every error, not the first

  Elements are cast **individually**. Casting the list as one array type
  would stop at the first bad element, which would give an author one error per
  round-trip — the "fix one, discover the next" loop this design exists to
  avoid. `Ash.Changeset.for_create/4` accumulates every bad field within an
  element, and casting each element separately accumulates across them.

  ## Only errors the author can act on

  Casting an element standalone surfaces problems that are not the author's:

    * the owning foreign key (`model_id`) is supplied on save, never written by
      an author, and would otherwise put an unfixable error on every element;
    * structural keys (`kind`, and reference keys like `from`/`to`) are
      document-level, not resource attributes, and passing them through would
      produce errors with an **empty field name** — an error the editor has
      nowhere to put.

  Both are filtered. The general rule: surface an error only for a field the
  author could actually edit.

  ## A save is a sync, not an append

  The document is the aggregate's whole contents, so an element absent from it
  has been removed. `save/2` hands each relationship to
  `Ash.Changeset.manage_relationship/4`, which matches by identity, creates the
  missing, updates the matched and removes the absent — inside one transaction.

  **Matching is by the resource's declared identity**, which is what lets the
  authoring language keep primary keys out of the text: `stock Susceptible` is
  matched on its name because the domain declared name unique. A resource with
  no identity falls back to the primary key, and a document for it would have
  to carry ids. One consequence worth stating: under name matching a rename is
  indistinguishable from a delete plus a create.

  ### Which makes a short document dangerous, so `:save` asks

  If the document is the whole contents, a client that read only *part* of the
  aggregate and saved it back has deleted the rest — and it cannot tell, because
  a truncated read and a deliberate deletion produce the same document. A paged
  collection is the ordinary way to get one: read page 1 of 250, save, lose the
  remainder.

  The server can tell, because it holds both counts. So `:save` takes a
  **`complete`** boolean, and refuses a document holding fewer elements than the
  aggregate does unless it is set:

      the document holds 1 ingredients but the recipe has 2. A save removes what
      the document omits, so this would delete 1. Read the whole aggregate
      first, or pass `complete: true` to confirm.

  It defaults to `false`, so a client that has not thought about this gets the
  safe answer rather than the silent one. Deleting stays possible — it just has
  to be said out loud. Counted per relationship, since a document that adds
  three stocks while dropping thirty flows has grown in total while losing data.

  **How an element is managed is derived from the schema**, never decided here
  — see `manage_opts/2`. A `has_many` whose far side declares `allow_nil?:
  false` states exclusive ownership, so the document owns the element outright:
  it is created, updated and destroyed with the document.

  A `many_to_many` states the element is shared, so the document may only
  **reference** it — link it, unlink it, and create it if it does not exist
  yet, but never edit its attributes. Otherwise one author's file could change
  what another author's file refers to, invisibly. Renaming is the sharpest
  case and the reason for the rule: with no id in the document text, a rename
  and a delete-plus-create are byte-identical, so a rename cannot be detected,
  let alone handled safely. A shared element's attributes are edited through
  its own resource, where the authority for them lives.
  """

  alias AshHateoas.Index

  @typedoc """
  One problem with the document.

  `index` is the element's position in the submitted list, which is what lets a
  client map an error back to a source range. It is `nil` for an error about
  the document as a whole.
  """
  @type error :: %{
          index: non_neg_integer() | nil,
          kind: String.t() | nil,
          name: String.t() | nil,
          field: String.t() | nil,
          message: String.t()
        }

  @doc """
  Validates a document and **writes nothing of its own**.

  Wired as the body of the generated `:validate` generic action, which returns a
  value and therefore persists nothing itself: the changesets built below are
  never run. Safe to call on every editor save, and callable by an actor with no
  write permission.

  > #### A change module can still write {: .warning}
  >
  > That guarantee covers this module, not the resources it casts. A `change`
  > runs during `Ash.Changeset.for_create/4` — which is what distinguishes it
  > from a hook — so anything it does happens while a document is merely being
  > checked, and no amount of not-running the changeset undoes it.
  >
  > Measured: a change that wrote its parsed input leaked roughly 600 rows per
  > validation of a 214-element document, while reporting `valid?` and leaving
  > every record correct. Only the row count moved, so nothing noticed.
  >
  > **A change that writes belongs in `before_action`**, which runs when the
  > action does — and inside its transaction, so a later failure rolls the write
  > back instead of stranding it.
  """
  @spec validate(Ash.ActionInput.t(), term()) :: {:ok, map()}
  def validate(input, _context) do
    document = document_of(input)
    errors = errors_for(document, input.resource, input)

    {:ok, %{"valid?" => errors == [], "errors" => Enum.map(errors, &stringify/1)}}
  end

  @doc """
  Validates a document and, when it is valid, persists it.

  Runs exactly the validation `validate/2` runs, so a document that passes
  there cannot fail here for a reason the author has not already seen — except
  for rules only the data layer can enforce (unique indexes, foreign keys,
  check constraints), which surface here and nowhere else. A client must be
  able to display an error that appears only on save.
  """
  @spec save(Ash.ActionInput.t(), term()) :: {:ok, map()} | {:error, term()}
  def save(input, _context) do
    document = document_of(input)

    case errors_for(document, input.resource, input) do
      [] ->
        persist(document, input)

      errors ->
        {:ok, %{"valid?" => false, "errors" => Enum.map(errors, &stringify/1)}}
    end
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp errors_for(document, root, input) when is_list(document) do
    index = index_for(root)

    # The record a root element is cast against, when there is one. `validate`
    # permits no `:id` — a client checks a document before the record exists —
    # and then the root is cast against a fresh struct instead, which reports a
    # missing required attribute rather than pretending one is set.
    record =
      case fetch_root(input) do
        {:ok, found} -> found
        :error -> nil
      end

    element_errors(document, index, root, document_context(root, document), record) ++
      graph_errors(document, index, root)
  end

  defp errors_for(_document, _root, _input) do
    [
      %{
        index: nil,
        kind: nil,
        name: nil,
        field: "document",
        message: "must be a list of elements"
      }
    ]
  end

  # Whatever the root wants every element to have in hand, computed **once**.
  #
  # A `change` runs per element and cannot see the document, so a change that
  # reads the database reads it once per element — the multiplication a document
  # makes certain. This is where a root gets to do that reading once instead.
  # See `AshHateoas.DslRoot.document_context/1`; the library never inspects what
  # comes back.
  defp document_context(root, document) do
    if function_exported?(root, :document_context, 1) do
      root.document_context(document)
    else
      %{}
    end
  rescue
    # A root that raises while preparing context must not take the whole
    # validation with it: every element is still castable without it, since a
    # change reads the context as a cache and falls back to its own lookup.
    _ -> %{}
  end

  defp element_errors(document, index, root, context, record) do
    document
    |> Enum.with_index()
    |> Enum.flat_map(fn {element, position} ->
      element_error(element, position, index, root, context, record)
    end)
  end

  defp element_error(element, position, index, root, context, record) when is_map(element) do
    kind = element["kind"] || element[:kind]

    case Index.fetch(index, to_string(kind)) do
      :error ->
        if to_string(kind) == root_kind(root) do
          root_element_errors(element, position, kind, root, context, record)
        else
          [error_at(position, kind, element, "kind", "unknown element kind #{inspect(kind)}")]
        end

      {:ok, resource} ->
        owner = owner_key(resource, root)

        unknown_key_errors(element, resource, root, position, kind) ++
          (resource
           |> changeset_errors(authorable(element, resource, root), context)
           # The owning foreign key is filtered from the *errors*, not merely from
           # the input. A part declaring `belongs_to :root, allow_nil?: false`
           # fails its own `allow_nil?` check whenever it is cast standalone —
           # nothing the author wrote is wrong, and `save/2` supplies the value.
           # Filtering the input alone leaves the error, which would put an
           # unfixable problem on every element in the document.
           |> Enum.reject(fn {field, _message} -> to_string(field) == owner end)
           |> Enum.map(fn {field, message} ->
             error_at(position, kind, element, to_string(field), message)
           end))
    end
  end

  defp element_error(_element, position, _index, _root, _context, _record) do
    [error_at(position, nil, %{}, nil, "element must be a map")]
  end

  # The root, carried by its own document.
  #
  # Cast for **update**, never create. A document's root always exists — a save
  # is addressed to it — so casting for create would report `allow_nil?` on
  # every required attribute the author correctly left out, having set it once
  # already. The action is the same one `persist/2` runs, so validation and the
  # save cannot disagree about the root.
  #
  # `authorable/3` and `unknown_key_errors/5` need no root-specific handling:
  # both take a resource and read what it accepts, and the root is a resource.
  #
  # Without a record — `validate` may be called before one exists — there is
  # nothing to update, so the attributes are only checked for keys the root does
  # not accept. Casting a bare struct would report every required attribute as
  # missing on a document that is perfectly good.
  defp root_element_errors(element, position, kind, root, context, record) do
    unknown_key_errors(element, root, root, position, kind) ++
      root_changeset_errors(element, position, kind, root, context, record)
  end

  defp root_changeset_errors(_element, _position, _kind, _root, _context, nil), do: []

  defp root_changeset_errors(element, position, kind, root, context, record) do
    record
    |> Ash.Changeset.for_update(update_action(root), authorable(element, root, root),
      context: context
    )
    |> Map.get(:errors, [])
    |> Enum.map(fn error -> {Map.get(error, :field), message_for(error)} end)
    |> Enum.reject(fn {field, _message} -> is_nil(field) end)
    |> Enum.map(fn {field, message} ->
      error_at(position, kind, element, to_string(field), message)
    end)
  end

  # A key that is neither an attribute nor a reference vanishes silently.
  #
  # `authorable/3` drops what the resource does not accept, and `reference_keys/2`
  # treats any remaining **string** value as a cross-element reference — so a
  # misspelled attribute is caught there, as a dangling reference. What falls
  # between the two is a key whose value is not a string: it is not cast, not
  # resolved, and reported by nothing.
  #
  # That gap is not theoretical. Measured on a real document, elements written
  # with key names the resource did not have saved cleanly and arrived empty,
  # because the wrong keys carried non-string values. A save reporting success
  # while discarding the value is the worst answer available.
  #
  # Structural keys are exempt: `kind` names the class rather than being an
  # attribute of it, and the owning foreign key is supplied by `save/2`.
  defp unknown_key_errors(element, resource, root, position, kind) do
    accepted = accepted_keys_for(resource)
    structural = ["kind", to_string(owner_key(resource, root))]

    for {key, value} <- element,
        not is_binary(value),
        key = to_string(key),
        key not in accepted,
        key not in structural,
        do:
          error_at(
            position,
            kind,
            element,
            key,
            "#{inspect(kind)} has no #{key}. Accepted: #{Enum.join(Enum.sort(accepted), ", ")}."
          )
  end

  # A changeset that is never run. `for_create/4` casts, applies constraints and
  # runs the action's own validations, collecting every problem without reaching
  # the data layer itself.
  #
  # It is a dry run of *Ash's* machinery, not of the resource's. `for_create/4`
  # also runs every `change` the action declares, and a change is ordinary code
  # — one that writes, writes here. See the warning on `validate/2`.
  defp changeset_errors(resource, attributes, context) do
    resource
    |> Ash.Changeset.for_create(create_action(resource), attributes, context: context)
    |> Map.get(:errors, [])
    |> Enum.map(fn error -> {Map.get(error, :field), message_for(error)} end)
    |> Enum.reject(fn {field, _message} -> is_nil(field) end)
  end

  defp create_action(resource) do
    case Ash.Resource.Info.primary_action(resource, :create) do
      %{name: name} -> name
      _ -> :create
    end
  end

  defp message_for(error) do
    case Map.get(error, :message) do
      message when is_binary(message) -> message
      _ -> "is invalid"
    end
  end

  @document_keys ~w(kind)

  # Keep only what the element's own class can actually accept.
  #
  # An allow-list rather than a deny-list, and derived rather than named. A
  # document carries two kinds of key: data the class accepts, and structure
  # the *language* owns — `kind`, and reference keys naming other elements.
  # Passing a structural key to `for_create/4` does not raise; it produces an
  # error with an **empty field name**, which the editor has nowhere to put.
  #
  # Deriving the allow-list from the resource means this module never has to
  # guess what a domain calls its references.
  defp authorable(element, resource, _root) do
    accepted = accepted_keys_for(resource)

    element
    |> Enum.map(&resolve_link(&1, resource))
    |> Enum.filter(fn {key, _value} -> to_string(key) in accepted end)
    |> Map.new()
  end

  # A `belongs_to` named the way the wire names it, turned back into the key an
  # action accepts.
  #
  # `AshHateoas.Descriptor` publishes a foreign key **as its relationship**:
  # `source_id` reaches the wire as `source`, typed `sh:nodeKind: sh:IRI`, and
  # the target class publishes `ah:identity` naming the field that keys it. So
  # a client is told to send `{"source": {"name": "Prey"}}` — and does.
  #
  # `AshHateoas.Hydra.LinkInput` reverses that for a write to a resource's own
  # URL, and `Hydra.Plug` calls it. Nothing reversed it here, so a document
  # carrying the key the wire advertises had it filtered out as unaccepted:
  # `source_id` is what the action takes, and `source` is not. The save
  # reported `valid?: true` and the element arrived unconnected.
  #
  # Measured: a flow added through the DSL, gating on a state, drained no stock
  # and moved none of 214 series.
  #
  # Only the resolvable case is handled — a target named by a single-field
  # identity, or an id given directly. Anything else falls through unchanged
  # and is filtered as before, which keeps a to-many or a composite key an
  # error the author can see rather than a silent guess.
  # The map test comes first, and it is not a micro-optimisation: this runs per
  # key per element, so 100,000 elements carrying two scalar fields each ask it
  # 200,000 times. Reaching for `public_relationships/1` on every one of those
  # — which builds and scans a list — cost 6% of a 100,000-element validation
  # against a budget that exists precisely to keep validation off the per-element
  # path. A link is always a map; a scalar never is, and answers in one guard.
  defp resolve_link({key, value}, resource) when is_map(value) do
    with relationship when not is_nil(relationship) <- link_named(resource, key),
         {:ok, id} <- target_id(value, relationship) do
      {to_string(relationship.source_attribute), id}
    else
      _ -> {key, value}
    end
  end

  defp resolve_link(pair, _resource), do: pair

  defp link_named(resource, key) do
    resource
    |> Ash.Resource.Info.public_relationships()
    |> Enum.find(&(&1.type == :belongs_to and to_string(&1.name) == to_string(key)))
  rescue
    _ -> nil
  end

  # The target's primary key, from whatever the document named it by.
  defp target_id(value, relationship) do
    destination = relationship.destination

    case Map.to_list(value) do
      [{field, name}] ->
        lookup(destination, to_string(field), name)

      _ ->
        :error
    end
  end

  defp lookup(destination, field, name) do
    key = String.to_existing_atom(field)

    destination
    |> Ash.Query.do_filter([{key, name}])
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [record]} -> {:ok, Map.get(record, :id)}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # What a resource will actually take, asked of the actions that will run.
  #
  # This used to be every attribute paired with the *create* action's arguments,
  # which is wrong in both halves. An attribute is not writable by virtue of
  # existing: `id` is `writable?: false`, and a domain's own `accept` list is
  # its statement of what a document may set. Reading past it lets a document
  # write a field the domain deliberately withheld, and reports a field the
  # action will reject as though it were accepted.
  #
  # Ash resolves `accept` at compile time — `Ash.Resource.Transformers.
  # DefaultAccept` expands `:*` to the public writable attributes, applies
  # `default_accept`, and strips argument names back out — so the list on the
  # action is final and reading it needs no interpretation. `[]` genuinely
  # means "accepts nothing", which is the default for a non-embedded resource.
  #
  # ## Why the union of create and update
  #
  # `manage_opts/2` sets `on_no_match: :create, on_match: :update`, so which
  # action an element meets is decided at *runtime* by whether it already
  # exists. A new stock is created; the same stock on the next save is updated.
  # Filtering by one action would silently drop a field the other accepts —
  # and which one that is would depend on the state of the database, so the
  # same document would behave differently on its first and second save.
  defp accepted_keys_for(resource) do
    accepted_keys_for(resource, [:create, :update])
  end

  # Memoised per process, because the answer is a property of the *resource*
  # and this is asked once per element — three times, from three callers. It
  # reads two actions and the relationship list, none of which can change while
  # a document is being validated, so recomputing it 300,000 times for a
  # 100,000-element document is pure waste against a budget that exists to keep
  # validation off the per-element path.
  #
  # The process dictionary rather than a cross-request cache: a document is
  # validated in one process, and a resource recompiled between requests must
  # not be answered from a stale table.
  defp accepted_keys_for(resource, types) do
    key = {__MODULE__, :accepted_keys, resource, types}

    case Process.get(key) do
      nil ->
        computed = compute_accepted_keys(resource, types)
        Process.put(key, computed)
        computed

      cached ->
        cached
    end
  end

  defp compute_accepted_keys(resource, types) do
    keys = Enum.flat_map(types, &action_keys(resource, &1))

    Enum.uniq(keys ++ link_names(resource, keys))
  end

  # A `belongs_to`'s own name, alongside the foreign key it is accepted under.
  #
  # The two are one affordance seen from either side. `AshHateoas.Descriptor`
  # publishes `follows_id` as `follows`, so `follows` is the key a client is
  # told to send — and a key the wire advertises must be a key a document may
  # carry. `resolve_link/2` turns it back into `follows_id` before the cast.
  #
  # Derived from the accepted keys rather than from every relationship, so a
  # `belongs_to` whose key the action does *not* accept stays unwritable: the
  # domain withheld it, and publishing a second spelling would not change that.
  defp link_names(resource, keys) do
    resource
    |> Ash.Resource.Info.public_relationships()
    |> Enum.filter(&(&1.type == :belongs_to and to_string(&1.source_attribute) in keys))
    |> Enum.map(&to_string(&1.name))
  rescue
    _ -> []
  end

  defp action_keys(resource, type) do
    case Ash.Resource.Info.primary_action(resource, type) do
      %{} = action ->
        accepted = Map.get(action, :accept) || []
        arguments = action |> Map.get(:arguments, []) |> Enum.map(& &1.name)

        Enum.map(accepted ++ arguments, &to_string/1)

      _ ->
        []
    end
  end

  # The attribute pointing back at the aggregate root, if any.
  defp owner_key(resource, root) do
    resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find_value(fn relationship ->
      if relationship.destination == root and relationship.cardinality == :one do
        to_string(relationship.source_attribute)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Cross-element rules
  # ---------------------------------------------------------------------------
  # A flat pass over the list, building a name map and checking edges against
  # it. A graph algorithm, not a traversal — nothing recurses, because the
  # document does not nest.

  defp graph_errors(document, index, root) do
    named = Enum.filter(document, &is_map/1)
    names = named |> Enum.map(&name_of/1) |> Enum.reject(&is_nil/1) |> MapSet.new()

    dangling_errors(named, names, index, root) ++
      duplicate_errors(named) ++ duplicate_root_errors(named, root)
  end

  defp dangling_errors(document, names, index, root) do
    document
    |> Enum.with_index()
    |> Enum.flat_map(fn {element, position} ->
      element
      |> reference_keys(index, root)
      |> Enum.reject(fn {_key, target} -> MapSet.member?(names, target) end)
      |> Enum.map(fn {key, target} ->
        error_at(position, element["kind"], element, key, "no element named #{inspect(target)}")
      end)
    end)
  end

  # A document naming its root twice has asked for two different sets of
  # attributes on one record, and there is no principled winner: taking the last
  # silently discards the other, which is the shape every other check here
  # exists to prevent. The client cannot produce it — `serializeGraph` sends one
  # root — but a hand-written document can, and that guarantee is the client's
  # rather than this server's.
  defp duplicate_root_errors(document, root) do
    case root_kind(root) do
      nil ->
        []

      kind ->
        case Enum.filter(document, &(to_string(&1["kind"] || &1[:kind]) == kind)) do
          [_one] ->
            []

          [] ->
            []

          many ->
            [
              %{
                index: nil,
                kind: kind,
                name: nil,
                field: "kind",
                message:
                  "a document names its root once; this one names #{kind} #{length(many)} times"
              }
            ]
        end
    end
  end

  # A reference is any key that is not an attribute of the element's own class
  # but does hold a string naming another element.
  #
  # Derived rather than listed. A fixed list of names (`from`, `to`, `uses`, …)
  # would be a guess about one domain's vocabulary, and this module must not
  # carry one: a reference key is whatever the language calls it. What makes a
  # key a reference is structural — the class does not accept it, so it cannot
  # be data, and it names something.
  # "Writable" and "is a reference" are different questions, and answering the
  # second with the first reports a read-only field as a dangling reference.
  #
  # `id` is the case that proves it: an attribute the class has, does not
  # accept, and which names nothing. A rendered element carries it — that is
  # how it was read back — so judging references by the accept list alone
  # reports every element's own id as naming an element that does not exist,
  # and the author has no way to act on it. The field being unwritable is
  # already handled: `authorable/3` drops it before anything is cast.
  defp reference_keys(element, index, root) do
    known = accepted_keys(element, index, root) ++ own_attributes(element, index, root)

    for {key, target} <- element,
        is_binary(target),
        key = to_string(key),
        key not in @document_keys,
        key not in known,
        do: {key, target}
  end

  # Every attribute of the element's own class, writable or not.
  defp own_attributes(element, index, root) do
    kind = to_string(element["kind"] || element[:kind])

    resource =
      case Index.fetch(index, kind) do
        {:ok, found} -> found
        :error -> if kind == root_kind(root), do: root
      end

    case resource do
      nil -> []
      resource -> resource |> Ash.Resource.Info.attributes() |> Enum.map(&to_string(&1.name))
    end
  end

  # What this element's own class accepts — so everything *else* that is a
  # string is read as naming another element.
  #
  # The root needs the same answer as any other kind. Without it the miss
  # returns `[]`, and then every string attribute the root carries — its title,
  # an algorithm, a unit — is reported as a reference to an element that does
  # not exist. Harmless while the root was refused outright; a document full of
  # spurious errors the moment it is accepted.
  defp accepted_keys(element, index, root) do
    kind = to_string(element["kind"] || element[:kind])

    case Index.fetch(index, kind) do
      {:ok, resource} -> accepted_keys_for(resource)
      :error -> if kind == root_kind(root), do: accepted_keys_for(root), else: []
    end
  end

  defp duplicate_errors(document) do
    document
    |> Enum.map(&name_of/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> Enum.map(fn {name, _count} ->
      %{
        index: nil,
        kind: nil,
        name: name,
        field: "name",
        message: "duplicate element name #{inspect(name)}"
      }
    end)
  end

  # ---------------------------------------------------------------------------
  # Persistence
  # ---------------------------------------------------------------------------

  # A save is a **sync**, not an append: the document is the aggregate's whole
  # contents, so an element absent from it has been removed.
  #
  # `manage_relationship` does exactly that — match by identity, create the
  # missing, update the matched, remove the absent — inside the changeset's own
  # transaction. Hand-rolling the loop instead means reimplementing identity
  # matching, deletion and atomicity, and getting all three wrong: a create-only
  # loop duplicates the whole document on a second save and orphans anything
  # deleted from it.
  defp persist(document, input) do
    root = input.resource
    grouped = group_by_relationship(document, root)

    case fetch_root(input) do
      {:ok, record} ->
        with :ok <- refuse_truncated(grouped, record, root, input) do
          save_document(record, document, grouped, root, input)
        end

      :error ->
        {:error, "no #{AshHateoas.Resource.Info.type(root)} with that id"}
    end
  end

  # A document holding fewer elements than the aggregate does, without saying it
  # meant to.
  #
  # This is the one failure a client cannot detect for itself. A save is a sync,
  # so the omitted elements are deleted — and a truncated read produces exactly
  # the same document as a deliberate deletion. Only the server holds both
  # numbers, so only the server can tell them apart, and it can only do so by
  # being told which was intended.
  #
  # Counted per relationship rather than in total: a document that adds three
  # stocks while dropping thirty flows has more elements than before, and a
  # total would report it as growth.
  defp refuse_truncated(grouped, record, root, input) do
    if Map.get(input.arguments, :complete, false) do
      :ok
    else
      case truncated_relationships(grouped, record, root) do
        [] ->
          :ok

        losses ->
          {:ok,
           %{
             "valid?" => false,
             "errors" =>
               Enum.map(losses, fn {name, sending, holding} ->
                 stringify(%{
                   "message" =>
                     "the document holds #{sending} #{name} but the " <>
                       "#{AshHateoas.Resource.Info.type(root)} has #{holding}. A save removes " <>
                       "what the document omits, so this would delete #{holding - sending}. " <>
                       "Read the whole aggregate first, or pass `complete: true` to confirm.",
                   "kind" => to_string(name)
                 })
               end)
           }}
      end
    end
  end

  # `{relationship, in the document, currently stored}` for each relationship
  # the document would shrink. The count is a query per relationship, not a
  # load: the elements themselves are not wanted, only how many there are.
  defp truncated_relationships(grouped, record, root) do
    root
    |> managed_relationships()
    |> Enum.flat_map(fn relationship ->
      # `grouped` is keyed by the relationship *struct*, which is what
      # `manage_all/3` iterates — not by its name.
      sending = grouped |> Map.get(relationship, []) |> length()

      case stored_count(record, relationship) do
        {:ok, holding} when holding > sending -> [{relationship.name, sending, holding}]
        _ -> []
      end
    end)
  end

  defp stored_count(record, relationship) do
    key = relationship.destination_attribute
    value = Map.fetch!(record, relationship.source_attribute)

    relationship.destination
    |> Ash.Query.filter_input(%{key => value})
    |> Ash.count(authorize?: false)
  rescue
    _ -> :error
  end

  defp save_document(record, document, grouped, root, input) do
    record
    |> Ash.Changeset.for_update(update_action(root), root_attributes(document, root),
      actor: actor(input),
      tenant: input.tenant,
      # The same context `validate` computes, and computed the same way —
      # once for the document. `manage_relationship` propagates a
      # changeset's context to the changesets it creates for each element,
      # so an element's `change` reads it without knowing a document exists.
      context: document_context(root, document)
    )
    |> manage_all(grouped, root)
    |> Ash.update(authorize?: true)
    |> case do
      {:ok, _updated} ->
        {:ok, %{"valid?" => true, "errors" => [], "synced" => count(grouped)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The root's own attributes, from the element a document carries for it.
  #
  # This was `%{}`, and that was the whole of the defect: a client rendering a
  # root's fields into a buffer, an author editing one, and a save reporting
  # success having written none of them. There is no separate update
  # affordance, so a document is the only way those values travel.
  #
  # `%{}` remains the answer for a document that carries no root element, which
  # is every document sent before this and every one a client writes by hand.
  defp root_attributes(document, root) do
    kind = root_kind(root)

    document
    |> Enum.filter(&is_map/1)
    |> Enum.find(&(kind && to_string(&1["kind"] || &1[:kind]) == kind))
    |> case do
      nil -> %{}
      # The root is the one thing in a document that always already exists, so
      # only `update` ever runs on it — unlike an element, which may meet
      # either action. Passing a key `update` does not accept is not a filtered
      # field but a raised `NoSuchInput`, and a rendered root carries its own
      # `id` like every other element, so the whole save fails on it.
      element -> element |> authorable(root, root) |> Map.take(root_keys(root))
    end
  end

  defp root_keys(root), do: accepted_keys_for(root, [:update])

  # Every managed relationship is passed, including the ones the document says
  # nothing about — those get an empty list.
  #
  # Iterating only the relationships present in the document would make removal
  # impossible to express: deleting the last stock from a file leaves no stock
  # element behind to group, so the relationship would never be managed and the
  # record would survive. "Absent from the document" has to mean "managed with
  # nothing in it", or a save can add but never remove.
  defp manage_all(changeset, grouped, root) do
    root
    |> managed_relationships()
    |> Enum.reduce(changeset, fn relationship, acc ->
      Ash.Changeset.manage_relationship(
        acc,
        relationship.name,
        Map.get(grouped, relationship, []),
        manage_opts(relationship, root)
      )
    end)
  end

  @doc """
  The relationships a document's elements belong to — what a save accepts.

  Public because the wire has to describe the same set the runtime syncs. A
  document naming a class this does not return would be rejected, so describing
  a different set would advertise a document the API will not take.

  Reads only cardinality and the destination *module name*, never the
  destination's attributes, so it is safe to call from a transformer: a
  destination compiled after the root does not exist yet, and asking it anything
  raises.
  """
  @spec managed_relationships(Ash.Resource.t() | map()) :: [
          Ash.Resource.Relationships.relationship()
        ]
  def managed_relationships(root) do
    relationships =
      root
      |> Ash.Resource.Info.relationships()
      |> Enum.filter(&(&1.cardinality == :many))

    # A `many_to_many` names the join relationship it travels through, and Ash
    # exposes that join as a `has_many` of its own. Managing both syncs the join
    # table twice — once as itself and once through the `many_to_many` — and on
    # the wire it would advertise the join as an element kind an author writes,
    # when it is plumbing the domain never asked anyone to author.
    joins =
      relationships
      |> Enum.map(&Map.get(&1, :join_relationship))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    relationships
    |> Enum.reject(&MapSet.member?(joins, &1.name))
    # `public?` is Ash's own word for "appears in public interfaces", and it
    # defaults to `false`. Every other path here honours it — routes, the
    # documentation's properties, the ontology — and this one did not, so a
    # relationship nobody opted in was advertised as an element kind by
    # `element_classes/1` and *managed* by a save. Since `on_missing/2` returns
    # `:destroy` for an owned `has_many`, a document that merely omitted those
    # elements deleted them.
    #
    # Filtered **after** the joins are collected, deliberately: a join
    # relationship is usually not public, so filtering first would remove it
    # from `relationships` before the name-rejection above could see it — and
    # it would then be neither rejected nor excluded.
    |> Enum.filter(& &1.public?)
  end

  @doc """
  How a relationship's absent elements are removed, derived from the schema.

  The domain has already said who owns what, so nothing here is a policy this
  module invents:

    * a `has_many` whose far side declares `allow_nil?: false` states
      **exclusive ownership** — the child cannot exist without this parent, so
      removing it from the document destroys it;
    * a `many_to_many` states the opposite. The element is reachable from other
      aggregates, so removal unlinks it and the record survives. Destroying it
      would delete data another aggregate still refers to — and on a
      polymorphic edge the database will not stop that, because such a column
      carries no foreign key.

  Anything else falls back to unlinking, which is the recoverable mistake.
  """
  @spec manage_opts(map(), Ash.Resource.t()) :: keyword()
  def manage_opts(%{type: :many_to_many} = relationship, _root) do
    # A shared element is **edited where it is written**, and the edit reaches
    # every aggregate holding it.
    #
    # `on_match: :update` — and this reverses what stood here. The argument for
    # `:ignore` was that one document must not change what another document
    # refers to, so a shared element was read-only and edited only at its own
    # URL. That protects a reader at a price nobody agreed to pay: a document
    # carrying an edited element saved **clean and discarded the edit**, so an
    # author changed a value, was told it saved, and found it unchanged. Silent
    # loss is worse than a visible consequence.
    #
    # The visible consequence is the honest one: linking an element into two
    # aggregates says they hold *the same element*, so editing it changes both.
    # A caller wanting an independent copy copies it — the two operations are
    # different and both exist.
    #
    # A rename is still the sharp case, and it is unchanged by this: identity
    # matching cannot tell a rename from a delete plus a create, so a renamed
    # element is created anew and the old one unlinked. That is a property of
    # matching by name, not of `on_match`.
    #
    # `on_lookup: :relate` is what makes sharing work at all. Without it an
    # element not yet linked to *this* aggregate is created fresh, so two
    # documents naming the same technique produce two records rather than one
    # shared one — silently on a data layer that does not enforce identities,
    # and as a constraint violation on one that does.
    [
      on_lookup: :relate,
      on_no_match: :create,
      on_match: :update,
      on_missing: :unrelate,
      use_identities: identities_for(relationship.destination)
    ]
  end

  def manage_opts(relationship, root) do
    [
      on_lookup: :ignore,
      on_no_match: :create,
      on_match: :update,
      on_missing: on_missing(relationship, root),
      use_identities: identities_for(relationship.destination)
    ]
  end

  defp on_missing(%{type: :has_many, destination: destination}, root) do
    owned? =
      destination
      |> Ash.Resource.Info.relationships()
      |> Enum.any?(fn back ->
        back.type == :belongs_to and back.destination == root and
          Map.get(back, :allow_nil?) == false
      end)

    if owned?, do: :destroy, else: :unrelate
  end

  defp on_missing(_relationship, _root), do: :unrelate

  # Matching is by the resource's declared identity, which is what lets the DSL
  # keep primary keys out of the text an author writes: `stock Susceptible` is
  # matched on its name because the domain declared name unique, not because
  # this module assumed it. A resource with no identity falls back to the
  # primary key, so a document for it would have to carry ids.
  defp identities_for(resource) do
    case Ash.Resource.Info.identities(resource) do
      [] -> [:_primary_key]
      identities -> Enum.map(identities, & &1.name)
    end
  rescue
    _ -> [:_primary_key]
  end

  # Which relationship an element belongs to is decided by its class: the
  # element names its `kind`, and exactly one of the root's relationships points
  # at that resource.
  defp group_by_relationship(document, root) do
    index = index_for(root)
    by_destination = relationships_by_destination(root)
    kind = root_kind(root)

    document
    # The root is not one of its own elements — `root_attributes/2` applies it
    # to the changeset these groups are managed onto. Removed **by name** rather
    # than by widening the `else` below, so the raise keeps meaning exactly what
    # it says: the index and the relationship map have diverged.
    |> Enum.reject(&(kind && is_map(&1) && to_string(&1["kind"] || &1[:kind]) == kind))
    |> Enum.reduce(%{}, fn element, acc ->
      with {:ok, resource} <- Index.fetch(index, to_string(element["kind"])),
           %{} = relationship <- Map.get(by_destination, resource) do
        attributes = authorable(element, resource, root)
        Map.update(acc, relationship, [attributes], &(&1 ++ [attributes]))
      else
        # Unreachable, and deliberately loud rather than silent. `index_for/1`
        # is built from the same relationships as `by_destination`, so a miss
        # here means the two have diverged — and the previous `_ -> acc` turned
        # exactly that into a 200 with an element quietly missing from the
        # saved document. Losing data is worse than crashing.
        _ ->
          raise "unreachable: #{inspect(element["kind"])} is indexed but has no managed relationship"
      end
    end)
  end

  defp relationships_by_destination(root) do
    root
    |> Ash.Resource.Info.relationships()
    |> Enum.filter(&(&1.cardinality == :many))
    |> Map.new(&{&1.destination, &1})
  end

  defp fetch_root(input) do
    case Map.get(input.arguments, :id) do
      nil ->
        :error

      id ->
        case Ash.get(input.resource, id, authorize?: false, tenant: input.tenant) do
          {:ok, record} -> {:ok, record}
          _ -> :error
        end
    end
  end

  defp update_action(resource) do
    case Ash.Resource.Info.primary_action(resource, :update) do
      %{name: name} -> name
      _ -> :update
    end
  end

  defp actor(input), do: get_in(input.context, [:private, :actor])

  defp count(grouped) do
    grouped |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
  end

  # ---------------------------------------------------------------------------
  # Shared
  # ---------------------------------------------------------------------------

  defp document_of(input), do: Map.get(input.arguments, :document, [])

  # The kinds a document may name: exactly the destinations a save manages.
  #
  # Scoped to the root's own relationships rather than to its domain. Building
  # from the domain indexed every extension-carrying resource in it, so a kind
  # could be known to validation and unreachable to persistence — validation
  # cast the element against a resource this root cannot hold, reporting that
  # resource's own required fields, while `group_by_relationship/2` found no
  # relationship and dropped it through an `else` clause. A 200, and an element
  # gone.
  #
  # This is also the set the wire advertises: `element_classes/1` reads the same
  # relationships, so the document a client is told it may send is now the
  # document both paths accept.
  defp index_for(root) do
    root
    |> managed_relationships()
    |> Enum.map(& &1.destination)
    |> Enum.filter(&AshHateoas.Resource.Info.extension?/1)
    |> Enum.reduce(%{}, fn resource, acc ->
      case AshHateoas.Resource.Info.type(resource) do
        nil -> acc
        type -> Map.put(acc, to_string(type), resource)
      end
    end)
  end

  @doc false
  # What the root itself is called in a document.
  #
  # A document *is* the root, so it is not one of the kinds `index_for/1` holds
  # — those are the destinations a save manages, and the root manages itself.
  # But a document may still **carry** the root, and should: the root's own
  # attributes have nowhere else to travel. There is no separate update
  # affordance, and a client editing `time_step` in a document had it silently
  # discarded, because `persist/2` passed an empty attribute map.
  #
  # Spelled by `Resource.Info.type/1`, the same function that keys every element
  # kind, so the root is named in a document by exactly the rule that names
  # everything else. Any other basis would be a second naming convention to keep
  # in step.
  #
  # `nil` when a root has no readable type, which leaves every path exactly as
  # it was before.
  def root_kind(root) do
    case AshHateoas.Resource.Info.type(root) do
      nil -> nil
      type -> to_string(type)
    end
  rescue
    _ -> nil
  end

  defp name_of(element) when is_map(element), do: element["name"] || element[:name]
  defp name_of(_element), do: nil

  defp error_at(position, kind, element, field, message) do
    %{
      index: position,
      kind: kind && to_string(kind),
      name: name_of(element),
      field: field,
      message: message
    }
  end

  # Keys are strings on the wire, so the returned map is JSON-shaped rather than
  # atom-keyed — this crosses an HTTP boundary, not a function call.
  defp stringify(error) do
    Map.new(error, fn {key, value} -> {to_string(key), value} end)
  end
end
