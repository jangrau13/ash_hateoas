defmodule AshHateoas.RootActions do
  @moduledoc """
  The bodies of the `:validate` and `:save` actions generated for an aggregate
  root. See `AshHateoas.Resource.Transformers.DeriveRootActions`.

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

  Elements are cast **individually**. Casting the list into an embedded array
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
  Validates a document and **writes nothing**.

  Wired as the body of the generated `:validate` generic action, which returns
  a value and therefore cannot write by construction. Safe to call on every
  editor save, and callable by an actor with no write permission.
  """
  @spec validate(Ash.ActionInput.t(), term()) :: {:ok, map()}
  def validate(input, _context) do
    document = document_of(input)
    errors = errors_for(document, input.resource)

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

    case errors_for(document, input.resource) do
      [] ->
        persist(document, input)

      errors ->
        {:ok, %{"valid?" => false, "errors" => Enum.map(errors, &stringify/1)}}
    end
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp errors_for(document, root) when is_list(document) do
    index = index_for(root)

    element_errors(document, index, root) ++ graph_errors(document, index)
  end

  defp errors_for(_document, _root) do
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

  defp element_errors(document, index, root) do
    document
    |> Enum.with_index()
    |> Enum.flat_map(fn {element, position} ->
      element_error(element, position, index, root)
    end)
  end

  defp element_error(element, position, index, root) when is_map(element) do
    kind = element["kind"] || element[:kind]

    case Index.fetch(index, to_string(kind)) do
      :error ->
        [error_at(position, kind, element, "kind", "unknown element kind #{inspect(kind)}")]

      {:ok, resource} ->
        owner = owner_key(resource, root)

        resource
        |> changeset_errors(authorable(element, resource, root))
        # The owning foreign key is filtered from the *errors*, not merely from
        # the input. A part declaring `belongs_to :root, allow_nil?: false`
        # fails its own `allow_nil?` check whenever it is cast standalone —
        # nothing the author wrote is wrong, and `save/2` supplies the value.
        # Filtering the input alone leaves the error, which would put an
        # unfixable problem on every element in the document.
        |> Enum.reject(fn {field, _message} -> to_string(field) == owner end)
        |> Enum.map(fn {field, message} ->
          error_at(position, kind, element, to_string(field), message)
        end)
    end
  end

  defp element_error(_element, position, _index, _root) do
    [error_at(position, nil, %{}, nil, "element must be a map")]
  end

  # A changeset that is never run. `for_create/4` casts, applies constraints and
  # runs the action's own validations, collecting every problem — and touches no
  # data layer, so this is a true dry run.
  defp changeset_errors(resource, attributes) do
    resource
    |> Ash.Changeset.for_create(create_action(resource), attributes)
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
    |> Enum.filter(fn {key, _value} -> to_string(key) in accepted end)
    |> Map.new()
  end

  defp accepted_keys_for(resource) do
    attributes = resource |> Ash.Resource.Info.attributes() |> Enum.map(&to_string(&1.name))

    arguments =
      case Ash.Resource.Info.primary_action(resource, :create) do
        %{arguments: arguments} -> Enum.map(arguments, &to_string(&1.name))
        _ -> []
      end

    attributes ++ arguments
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

  defp graph_errors(document, index) do
    named = Enum.filter(document, &is_map/1)
    names = named |> Enum.map(&name_of/1) |> Enum.reject(&is_nil/1) |> MapSet.new()

    dangling_errors(named, names, index) ++ duplicate_errors(named)
  end

  defp dangling_errors(document, names, index) do
    document
    |> Enum.with_index()
    |> Enum.flat_map(fn {element, position} ->
      element
      |> reference_keys(index)
      |> Enum.reject(fn {_key, target} -> MapSet.member?(names, target) end)
      |> Enum.map(fn {key, target} ->
        error_at(position, element["kind"], element, key, "no element named #{inspect(target)}")
      end)
    end)
  end

  # A reference is any key that is not an attribute of the element's own class
  # but does hold a string naming another element.
  #
  # Derived rather than listed. A fixed list of names (`from`, `to`, `uses`, …)
  # would be a guess about one domain's vocabulary, and this module must not
  # carry one: a reference key is whatever the language calls it. What makes a
  # key a reference is structural — the class does not accept it, so it cannot
  # be data, and it names something.
  defp reference_keys(element, index) do
    known = accepted_keys(element, index)

    for {key, target} <- element,
        is_binary(target),
        key = to_string(key),
        key not in @document_keys,
        key not in known,
        do: {key, target}
  end

  defp accepted_keys(element, index) do
    case Index.fetch(index, to_string(element["kind"] || element[:kind])) do
      {:ok, resource} -> accepted_keys_for(resource)
      :error -> []
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

  defp persist(document, input) do
    root = input.resource
    index = index_for(root)
    root_id = Map.get(input.arguments, :id)

    created =
      Enum.reduce_while(document, {:ok, []}, fn element, {:ok, acc} ->
        case create_element(element, index, root, root_id, input) do
          {:ok, record} -> {:cont, {:ok, [record | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case created do
      {:ok, records} ->
        {:ok, %{"valid?" => true, "errors" => [], "created" => length(records)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_element(element, index, root, root_id, input) do
    with {:ok, resource} <- Index.fetch(index, to_string(element["kind"])) do
      attributes =
        element
        |> authorable(resource, root)
        |> put_owner(resource, root, root_id)

      resource
      |> Ash.Changeset.for_create(create_action(resource), attributes,
        actor: input.context[:private][:actor],
        tenant: input.tenant
      )
      |> Ash.create(authorize?: true)
    else
      :error -> {:error, "unknown element kind #{inspect(element["kind"])}"}
    end
  end

  defp put_owner(attributes, resource, root, root_id) do
    case owner_key(resource, root) do
      nil -> attributes
      key when is_nil(root_id) -> attributes |> Map.delete(key)
      key -> Map.put(attributes, key, root_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Shared
  # ---------------------------------------------------------------------------

  defp document_of(input), do: Map.get(input.arguments, :document, [])

  defp index_for(root) do
    root
    |> Ash.Resource.Info.domain()
    |> List.wrap()
    |> Index.build()
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
