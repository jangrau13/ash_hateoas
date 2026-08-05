defmodule AshHateoas.Hydra.LinkInput do
  @moduledoc """
  Reads relationship links out of a write body.

  A client relates one resource to another by naming the target, never by
  writing a foreign key: the wire carries identities, and a raw id is an
  implementation detail of the data layer. Two ways to name a target, both
  JSON-LD node objects under the relationship's own key:

      {"author": {"@id": "https://api.example.org/authors/person/7"}}
      {"author": {"name": "Jane Austen"}}

  The first is a **node reference** — the target's IRI, which is what a read
  emits, so a client can write back what it read. The second is an
  **identity object**: the properties a class declares as its key
  (`ah:identity` in the ApiDocumentation, `identity :unique_name, [:name]` in
  Ash), which is what lets an author name a target without holding its URL.
  A bare IRI string is accepted for the first form, since a to-one link
  compacted with `"@type": "@id"` is a string on the wire.

  `null` clears a link. A required relationship refuses, so an affordance that
  advertises `hydra:required` is not contradicted by the write path.

  ## Resolution is reverse routing

  An IRI resolves by matching its path against the same derived routes that
  serve a GET, so exactly the URLs this API issues are the URLs it accepts.
  An IRI that resolves to some other class is a mismatch rather than a
  silently-ignored key — relating a Book to a Tag where a Person belongs is an
  error the client can act on.

  Resolution never confirms existence: the id is handed to Ash, and
  `manage_relationship`'s lookup answers with the actor's authorization
  applied. An unauthorized target is indistinguishable from a missing one, so
  a write cannot be used to probe for records.
  """

  alias AshHateoas.Route

  @typedoc "A link's resolved value, ready for `Ash.Changeset.manage_relationship/4`."
  @type value :: {:id, term()} | {:identity, map()} | {:list, [value()]} | :clear

  @typedoc "One relationship to manage, with the value the body named."
  @type link :: {Ash.Resource.Relationships.relationship(), value()}

  @doc """
  Splits a write body into plain input and relationship links.

  Keys naming a public relationship become links; everything else stays input
  for the action. Returns `{:error, reason}` when a link cannot be honoured, so
  the caller answers before running the write.
  """
  @spec split(map(), module(), Ash.Resource.Actions.action(), keyword()) ::
          {:ok, map(), [link()]} | {:error, atom(), String.t()}
  def split(body, resource, action, opts) do
    relationships = Map.new(public_relationships(resource), &{to_string(&1.name), &1})

    body
    |> Enum.reduce_while({%{}, []}, fn {key, raw}, {input, links} ->
      case Map.fetch(relationships, key) do
        # An action argument of the same name is the author's own handling —
        # `change manage_relationship(:author, ...)` — so the value is passed
        # through as input rather than managed here. Two managers of one
        # relationship would fight over it.
        {:ok, relationship} ->
          if argument?(action, relationship.name) do
            {:cont, {Map.put(input, key, argument_value(raw)), links}}
          else
            case resolve(raw, relationship, opts) do
              {:ok, value} -> {:cont, {input, [{relationship, value} | links]}}
              {:error, reason, detail} -> {:halt, {:error, reason, detail}}
            end
          end

        :error ->
          {:cont, {Map.put(input, key, raw), links}}
      end
    end)
    |> case do
      {:error, reason, detail} -> {:error, reason, detail}
      {input, links} -> {:ok, input, Enum.reverse(links)}
    end
  end

  @doc """
  Splits resolved links into those the action takes as plain input and those
  that need managing.

  A `belongs_to` resolved to an id **is** the foreign key, and an action that
  accepts that attribute takes it as input. This is not an optimisation: a
  required `belongs_to` is validated while the changeset is built, before any
  queued relationship management runs, so a link supplied only through
  `manage_relationship` would fail `attribute document_id is required` on the
  very writes that supplied it.

  Everything else — an identity object to look up, a to-many set, a clear —
  is managed.
  """
  @spec partition([link()], module(), Ash.Resource.Actions.action()) :: {map(), [link()]}
  def partition(links, resource, action) do
    Enum.reduce(links, {%{}, []}, fn {relationship, value} = link, {input, managed} ->
      case foreign_key_input(relationship, value, resource, action) do
        {:ok, key, id} -> {Map.put(input, key, id), managed}
        :error -> {input, [link | managed]}
      end
    end)
    |> then(fn {input, managed} -> {input, Enum.reverse(managed)} end)
  end

  @doc """
  Checks that every link names a target that exists.

  Writing a foreign key sets a link without ever reading what it points at, so
  a reference to nothing would be stored and served — a link the API itself
  emits and cannot resolve. `manage_relationship` refuses that (`on_no_match:
  :error`), and this is the same refusal for the keys that bypass it.

  The read runs as the actor, so a target they may not see answers exactly as a
  missing one does. That is deliberate: a write must not report whether a
  record it cannot show exists.
  """
  @spec verify_targets([link()], keyword()) :: :ok | {:error, atom(), String.t()}
  def verify_targets(links, ash_opts) do
    Enum.reduce_while(links, :ok, fn {relationship, value}, _acc ->
      case unresolvable_ids(relationship, value, ash_opts) do
        [] ->
          {:cont, :ok}

        [missing | _rest] ->
          {:halt,
           {:error, :dangling_link,
            "#{relationship.name} references #{missing}, which is not an existing #{destination_type(relationship)}."}}
      end
    end)
  end

  defp unresolvable_ids(relationship, {:id, id}, ash_opts) do
    if exists?(relationship.destination, id, ash_opts), do: [], else: [id]
  end

  defp unresolvable_ids(relationship, {:list, values}, ash_opts) do
    Enum.flat_map(values, &unresolvable_ids(relationship, &1, ash_opts))
  end

  # An identity object is looked up by `manage_relationship`, which refuses a
  # no-match itself; a clear names no target.
  defp unresolvable_ids(_relationship, _value, _ash_opts), do: []

  defp exists?(destination, id, ash_opts) do
    match?({:ok, _record}, Ash.get(destination, id, ash_opts ++ [authorize?: true]))
  rescue
    _ -> false
  end

  defp foreign_key_input(%{type: :belongs_to} = relationship, value, resource, action)
       when value == :clear or elem(value, 0) == :id do
    key = relationship.source_attribute

    if accepts?(action, key) and not is_nil(Ash.Resource.Info.attribute(resource, key)) do
      {:ok, to_string(key), if(value == :clear, do: nil, else: elem(value, 1))}
    else
      :error
    end
  rescue
    _ -> :error
  end

  defp foreign_key_input(_relationship, _value, _resource, _action), do: :error

  defp accepts?(%{accept: accept}, key) when is_list(accept), do: key in accept
  defp accepts?(_action, _key), do: false

  @doc """
  Applies resolved links to a changeset.

  Every link is managed with `:append_and_remove`, which relates what the body
  names and unrelates what it omits — the set the client sent becomes the set
  that holds. Its `on_no_match: :error` is what turns a target that does not
  exist (or that this actor may not see) into an error rather than a silent
  create.
  """
  @spec manage(Ash.Changeset.t(), [link()]) :: Ash.Changeset.t()
  def manage(changeset, links) do
    Enum.reduce(links, changeset, fn {relationship, value}, acc ->
      Ash.Changeset.manage_relationship(
        acc,
        relationship.name,
        manage_value(value),
        manage_opts(relationship, value)
      )
    end)
  end

  @doc """
  Whether a relationship must always hold a link.

  A `belongs_to` is required when its foreign key may not be nil — the same
  fact `hydra:required` advertises on the link property. Ash and the data layer
  remain the backstop; refusing here is what makes the refusal legible.
  """
  @spec required?(module(), Ash.Resource.Relationships.relationship()) :: boolean()
  def required?(resource, %{type: :belongs_to} = relationship) do
    case Ash.Resource.Info.attribute(resource, relationship.source_attribute) do
      %{allow_nil?: false} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  def required?(_resource, _relationship), do: false

  # ── Resolution ──────────────────────────────────────────────────────────────

  defp resolve(nil, relationship, opts) do
    if required?(opts[:resource], relationship) do
      {:error, :required_link,
       "#{relationship.name} is required and cannot be unlinked — relate it to another #{destination_type(relationship)} instead."}
    else
      {:ok, :clear}
    end
  end

  defp resolve(values, relationship, opts) when is_list(values) do
    if values == [] and required?(opts[:resource], relationship) do
      {:error, :required_link,
       "#{relationship.name} is required and must keep at least one link."}
    else
      values
      |> Enum.reduce_while([], fn value, acc ->
        case resolve(value, relationship, opts) do
          {:ok, resolved} -> {:cont, [resolved | acc]}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:error, _reason, _detail} = error -> error
        resolved -> {:ok, {:list, Enum.reverse(resolved)}}
      end
    end
  end

  defp resolve(iri, relationship, opts) when is_binary(iri) do
    case resolve_iri(iri, relationship, opts) do
      {:ok, id} -> {:ok, {:id, id}}
      error -> error
    end
  end

  defp resolve(%{} = object, relationship, opts) do
    case Map.fetch(object, "@id") do
      {:ok, iri} when is_binary(iri) ->
        resolve(iri, relationship, opts)

      _no_iri ->
        identity_object(object, relationship)
    end
  end

  defp resolve(other, relationship, _opts) do
    {:error, :unresolvable_link,
     "#{relationship.name} must be a node reference, an identity object, or null — got #{inspect(other)}."}
  end

  # An `@id`-less node object names a target by its declared key. Only keys the
  # destination declares as an identity are honoured: matching on a guessed
  # property matches the wrong record, or none, and does so silently.
  defp identity_object(object, relationship) do
    properties = object |> Map.drop(["@type", "@context"]) |> Map.new()
    keys = properties |> Map.keys() |> Enum.sort()

    if keys != [] and keys in identity_key_sets(relationship.destination) do
      {:ok, {:identity, properties}}
    else
      {:error, :unknown_identity,
       "#{relationship.name} was named by #{inspect(keys)}, which is not a declared identity of #{destination_type(relationship)}."}
    end
  end

  defp identity_key_sets(destination) do
    destination
    |> Ash.Resource.Info.identities()
    |> Enum.map(fn identity -> identity.keys |> Enum.map(&to_string/1) |> Enum.sort() end)
  rescue
    _ -> []
  end

  # The reverse of href building: an IRI names a member of some resource, and
  # the routes that serve a GET are what say which.
  defp resolve_iri(iri, relationship, opts) do
    with {:ok, path} <- request_path(iri, opts),
         {:ok, resource, id} <- match_member(path, opts) do
      if resource == relationship.destination do
        {:ok, id}
      else
        {:error, :wrong_destination,
         "#{relationship.name} must reference a #{destination_type(relationship)} — #{iri} is a #{AshHateoas.Resource.Info.type(resource)}."}
      end
    else
      _ ->
        {:error, :unresolvable_link,
         "#{relationship.name} references #{iri}, which is not a resource of this API."}
    end
  end

  # A link may arrive absolute (what a read emits when `base_url` is set) or
  # relative. An absolute IRI from another origin is not ours to resolve: it
  # names a resource in some other API, which no local relationship can hold.
  #
  # With no origin configured there is nothing to compare a foreign host
  # against, and its path may still match a local route — `/documents/1` under
  # any host at all. Matching on the path alone would take some other API's
  # record as though it were ours, so an absolute IRI is refused outright
  # unless it is under the configured origin. A client sends back what it read,
  # and what a read emits is relative in exactly this case.
  defp request_path(iri, opts) do
    uri = URI.parse(iri)
    origin = opts[:base_url]

    cond do
      is_nil(uri.scheme) ->
        {:ok, strip_prefix(uri.path, opts[:prefix])}

      is_binary(origin) and String.starts_with?(iri, String.trim_trailing(origin, "/")) ->
        {:ok, strip_prefix(uri.path, opts[:prefix])}

      true ->
        :error
    end
  end

  defp strip_prefix(nil, _prefix), do: nil
  defp strip_prefix(path, nil), do: path
  defp strip_prefix(path, ""), do: path

  defp strip_prefix(path, prefix) do
    case String.replace_prefix(path, prefix, "") do
      "" -> "/"
      stripped -> stripped
    end
  end

  @doc """
  Resolves an IRI this API issued to the `{resource, id}` it addresses.

  The public form of what a link write already does, exposed because a
  *relationship* is not the only thing that can hold a reference. A domain may
  store one in an attribute — a citation inside an expression, say — and it must
  resolve the IRI the same way a link does, or the API accepts two spellings of
  the same reference and only one of them round-trips.

  **No query.** The path is matched against the derived route table, which is
  the same table `Plug.match/2` reads, so the answer comes from the routes alone
  — the kind from which route matched, the id from the path. That is what makes
  an IRI affordable where a name is not: resolving a name asks the database
  which resource holds it, and resolving an IRI asks nobody.

  Returns `:error` for anything this API does not serve — an unparseable IRI, a
  foreign origin, or a path matching no member route. A caller that wants to
  accept *external* references must handle them as such rather than reading
  `:error` as "does not exist"; the two are different claims.
  """
  @spec resolve_member(String.t(), keyword()) ::
          {:ok, Ash.Resource.t(), String.t()} | :error
  def resolve_member(iri, opts) when is_binary(iri) do
    with {:ok, path} <- request_path(iri, opts) do
      match_member(path, opts)
    end
  end

  def resolve_member(_iri, _opts), do: :error

  @doc """
  The IRI this API serves a record at — the inverse of `resolve_member/2`.

  Exposed for the same reason and as its exact counterpart: a domain that stores
  a reference somewhere a relationship cannot go must be able to *render* the
  address as well as read one back, and both directions must use the one route
  table. A reference the API emits but will not accept, or accepts but will not
  emit, is a link that only works one way.

  Returns `nil` when the resource serves no member route, so a caller can fall
  back rather than emit a URL that resolves to nothing.
  """
  @spec member_iri(Ash.Resource.t(), String.t()) :: String.t() | nil
  def member_iri(resource, id) when is_binary(id) do
    case member_route(resource) do
      %Route{route: route} -> String.replace(route, ":id", id)
      _ -> nil
    end
  end

  def member_iri(_resource, _id), do: nil

  # The member route of every routed resource, tried against the path. This is
  # the same route table `Plug.match/2` reads, so a URL this API issues is a URL
  # it accepts back.
  defp match_member(nil, _opts), do: :error

  defp match_member(path, opts) do
    opts[:domains]
    |> AshHateoas.Index.build()
    |> Enum.find_value(:error, fn {_type, resource} ->
      with %Route{route: route} <- member_route(resource),
           {:ok, id} <- capture_id(route, path) do
        {:ok, resource, id}
      else
        _ -> nil
      end
    end)
  end

  defp member_route(resource) do
    resource
    |> AshHateoas.Resource.Info.routes()
    |> Enum.find(&(&1.type == :get and &1.primary?))
  rescue
    _ -> nil
  end

  # A route pattern (`/ledger/:ledger_id/entry/:id`) matched segment by segment
  # against a path, yielding what `:id` captured.
  defp capture_id(route, path) do
    pattern = String.split(route, "/", trim: true)
    segments = String.split(path, "/", trim: true)

    if length(pattern) == length(segments) do
      pattern
      |> Enum.zip(segments)
      |> Enum.reduce_while(:error, fn
        {":id", value}, _acc -> {:cont, {:ok, value}}
        {":" <> _owner, _value}, acc -> {:cont, acc}
        {same, same}, acc -> {:cont, acc}
        {_literal, _other}, _acc -> {:halt, :error}
      end)
    else
      :error
    end
  end

  # ── Managing ────────────────────────────────────────────────────────────────

  defp manage_value({:id, id}), do: id
  defp manage_value({:identity, properties}), do: properties
  defp manage_value({:list, values}), do: Enum.map(values, &manage_value/1)
  defp manage_value(:clear), do: nil

  # An identity object is looked up by the keys the destination declares, plus
  # the primary key — the same set `ApiDocumentation` publishes as
  # `ah:identity`, so a client that read the catalogue agrees with the server
  # rather than coincides with it.
  defp manage_opts(relationship, value) do
    opts = [type: :append_and_remove]

    if identity?(value) do
      Keyword.put(opts, :use_identities, identity_names(relationship.destination) ++ [:_primary_key])
    else
      opts
    end
  end

  defp identity?({:identity, _properties}), do: true
  defp identity?({:list, values}), do: Enum.any?(values, &identity?/1)
  defp identity?(_value), do: false

  defp identity_names(destination) do
    destination
    |> Ash.Resource.Info.identities()
    |> Enum.map(& &1.name)
  rescue
    _ -> []
  end

  # ── Shared ──────────────────────────────────────────────────────────────────

  defp public_relationships(resource) do
    Ash.Resource.Info.public_relationships(resource)
  rescue
    _ -> []
  end

  defp argument?(nil, _name), do: false

  defp argument?(%{arguments: arguments}, name) when is_list(arguments) do
    Enum.any?(arguments, &(&1.name == name))
  end

  defp argument?(_action, _name), do: false

  # An action argument takes the value the body named, unwrapped: the argument's
  # own type decides what it accepts, and a node reference's `@id` is the part
  # that identifies.
  defp argument_value(%{"@id" => iri}), do: iri
  defp argument_value(values) when is_list(values), do: Enum.map(values, &argument_value/1)
  defp argument_value(value), do: value

  defp destination_type(%{destination: destination}) do
    AshHateoas.Resource.Info.type(destination) || inspect(destination)
  rescue
    _ -> inspect(destination)
  end
end
