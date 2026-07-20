defmodule AshHateoas.Req.PropertiesTest do
  @moduledoc """
  Property-based / fuzz tests for the invariants REQ.md states must hold for
  ALL inputs, not just hand-picked ones.

  Each property names the requirement clause it probes. A failure here means the
  invariant is violated for the shrunk counterexample StreamData reports, not
  that the example was unlucky.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias AshHateoas.{Affordance, Field}
  alias AshHateoas.Test.{Actor, Document, Domain, Endpoint, Order}

  @moduletag timeout: 300_000

  @leak "default-key-do-not-leak"

  # ==================================================================
  # Generators
  # ==================================================================

  defp maybe_string_gen do
    one_of([constant(nil), string(:alphanumeric, max_length: 20)])
  end

  # Actors across roles, including anonymous. `owner_id` handling is what makes
  # the record-dependent `expr(owner_id == ^actor(:id))` policy on :archive and
  # :update meaningful, so ids are drawn from a small pool that collides with
  # generated record owner_ids often enough to exercise both branches.
  defp actor_gen do
    one_of([
      constant(nil),
      gen all(
            role <- member_of([:admin, :editor, :viewer, :stranger, nil]),
            id <- member_of(["owner-a", "owner-b", "owner-c", "nobody"])
          ) do
        %Actor{id: id, role: role}
      end
    ])
  end

  defp document_attrs_gen do
    gen all(
          title <- string(:alphanumeric, min_length: 1, max_length: 20),
          body <- maybe_string_gen(),
          owner_id <- member_of(["owner-a", "owner-b", "owner-c", nil])
        ) do
      %{title: title, body: body, owner_id: owner_id}
    end
  end

  defp create_document(attrs) do
    Document
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(authorize?: false)
  end

  defp create_order do
    Order
    |> Ash.Changeset.for_create(:create, %{reference: unique("ref")})
    |> Ash.create!(authorize?: false)
  end

  # Drive an order into a state by running the real transitions, so the record
  # is genuinely reachable rather than hand-forged.
  defp drive_order(order, actions) do
    Enum.reduce(actions, order, fn action, acc ->
      acc
      |> Ash.Changeset.for_update(action, %{})
      |> Ash.update!(authorize?: false)
    end)
  rescue
    _ -> order
  end

  # Every path through the transition graph, plus the wildcard :cancel from each.
  defp order_path_gen do
    member_of([
      [],
      [:confirm],
      [:confirm, :ship],
      [:confirm, :ship, :deliver],
      [:cancel],
      [:confirm, :cancel],
      [:confirm, :ship, :cancel],
      [:confirm, :ship, :deliver, :cancel]
    ])
  end

  defp affordances(subject, actor) do
    AshHateoas.affordances(subject, actor, domain: Domain)
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Empty the shared ETS table so the R8 collection property controls page size
  # exactly. Destroying through the action keeps the table itself alive, which
  # `Ash.DataLayer.Ets.stop/1` would not.
  defp clear_documents do
    Document
    |> Ash.read!(authorize?: false)
    |> Enum.each(&Ash.destroy!(&1, authorize?: false))
  end

  # ==================================================================
  # Property 1 — R6: Ash.can?/3 is the single source of truth
  # ==================================================================

  describe "R6: the advertised set never disagrees with Ash.can?/3" do
    # "Single source of truth. Filtering MUST call `Ash.can?/3` and the real
    # state machine — never a parallel reimplementation of a policy."
    #
    # The oracle is an independent Ash.can?/3 call made by this test. For any
    # record/actor, an action's presence in the envelope must equal that call.
    property "record-level affordances agree with a direct Ash.can?/3" do
      check all(
              attrs <- document_attrs_gen(),
              actor <- actor_gen(),
              max_runs: 200
            ) do
        doc = create_document(attrs)
        advertised = doc |> affordances(actor) |> Map.keys() |> MapSet.new()

        for action <- record_level_actions(Document) do
          oracle = Ash.can?({doc, action}, actor, domain: Domain)
          claimed = MapSet.member?(advertised, action)

          assert claimed == oracle,
                 """
                 affordance/oracle disagreement — the gate is not the single source of truth
                   action:      #{inspect(action)}
                   advertised:  #{claimed}
                   Ash.can?/3:  #{oracle}
                   record:      owner_id=#{inspect(doc.owner_id)} state=#{inspect(doc.state)}
                   actor:       #{inspect(actor)}
                 """
        end
      end
    end

    property "collection-level affordances agree with a direct Ash.can?/3" do
      check all(actor <- actor_gen(), max_runs: 200) do
        advertised = Document |> affordances(actor) |> Map.keys() |> MapSet.new()

        for action <- type_level_actions(Document) do
          oracle = Ash.can?({Document, action}, actor, domain: Domain)
          claimed = MapSet.member?(advertised, action)

          assert claimed == oracle,
                 "collection-level #{inspect(action)}: advertised=#{claimed} " <>
                   "Ash.can?/3=#{oracle} actor=#{inspect(actor)}"
        end
      end
    end

    defp routed_actions(resource) do
      resource
      |> AshJsonApi.Resource.Info.routes([Domain])
      |> Enum.map(& &1.action)
      |> Enum.uniq()
    end

    defp record_level_actions(resource) do
      Enum.filter(routed_actions(resource), fn name ->
        action = Ash.Resource.Info.action(resource, name)
        action && action.type in [:update, :destroy, :read]
      end)
    end

    defp type_level_actions(resource) do
      Enum.filter(routed_actions(resource), fn name ->
        action = Ash.Resource.Info.action(resource, name)
        action && action.type in [:create, :read]
      end)
    end
  end

  # ==================================================================
  # Property 2 — R5: the envelope shape is fixed
  # ==================================================================

  describe "R5: the envelope shape never varies" do
    # "The output envelope has a fixed, documented shape... The renderer must
    # not emit structurally different affordances across records or transports."
    property "every envelope entry is a well-formed Affordance with well-formed Fields" do
      check all(
              attrs <- document_attrs_gen(),
              actor <- actor_gen(),
              path <- order_path_gen(),
              max_runs: 200
            ) do
        doc = create_document(attrs)
        order = create_order() |> drive_order(path)

        envelopes = [
          affordances(doc, actor),
          affordances(order, actor),
          affordances(Document, actor),
          affordances(Order, actor)
        ]

        for envelope <- envelopes do
          assert is_map(envelope)

          for {name, affordance} <- envelope do
            assert is_atom(name)
            assert %Affordance{} = affordance
            assert affordance.name == name
            assert is_nil(affordance.href) or is_binary(affordance.href)
            assert is_atom(affordance.method) and not is_nil(affordance.method)
            assert is_nil(affordance.description) or is_binary(affordance.description)
            assert is_boolean(affordance.multi_step?)
            assert is_list(affordance.fields)

            for field <- affordance.fields do
              assert %Field{} = field
              assert is_atom(field.name)
              assert is_binary(field.type)
              # R5's "required": the struct carries Ash's allow_nil? polarity.
              assert is_boolean(field.allow_nil?)
              assert is_nil(field.description) or is_binary(field.description)
              assert match?({:ok, _}, field.default) or field.default == :error
              assert is_map(field.constraints)
            end
          end
        end
      end
    end
  end

  # ==================================================================
  # Property 3 — R4: a sensitive default never leaks, anywhere
  # ==================================================================

  describe "R4: a sensitive argument's default never reaches any transport" do
    # "never emit a `sensitive?` argument's `default`". Document's :approve
    # declares `signing_key` sensitive with default #{@leak}. It must be absent
    # from the serialized JSON:API document and from the MCP inputSchema, for
    # every actor and record.
    property "the sensitive default appears in no rendered output" do
      check all(
              attrs <- document_attrs_gen(),
              actor <- actor_gen(),
              max_runs: 100
            ) do
        doc = create_document(attrs)

        # The backbone envelope itself.
        envelope_json =
          doc
          |> affordances(actor)
          |> Enum.map(fn {name, affordance} ->
            {name, %{affordance | fields: Enum.map(affordance.fields, &Map.from_struct/1)}}
          end)
          |> inspect(limit: :infinity, printable_limit: :infinity)

        refute envelope_json =~ @leak,
               "sensitive default leaked into the backbone envelope for actor #{inspect(actor)}"

        # JSON:API rendering, end to end through the real request path.
        record_body = raw_get("/documents/#{doc.id}", actor)

        refute record_body =~ @leak,
               "sensitive default leaked into the JSON:API record document " <>
                 "for actor #{inspect(actor)}"

        collection_body = raw_get("/documents", actor)

        refute collection_body =~ @leak,
               "sensitive default leaked into the JSON:API collection document " <>
                 "for actor #{inspect(actor)}"

        # MCP rendering: the tool inputSchema.
        mcp_json =
          doc
          |> affordances(actor)
          |> AshHateoas.Mcp.Tools.render("document")
          |> Jason.encode!()

        refute mcp_json =~ @leak,
               "sensitive default leaked into the MCP inputSchema for actor #{inspect(actor)}"

        # And the sensitive field is still ADVERTISED (R4: the client must know
        # to supply it) whenever :approve survives the gates.
        case affordances(doc, actor)[:approve] do
          nil ->
            :ok

          approve ->
            names = Enum.map(approve.fields, & &1.name)
            assert :signing_key in names, "a sensitive argument must still appear as a field"
        end
      end
    end
  end

  # ==================================================================
  # Property 4 — R8: collections carry type-level affordances only
  # ==================================================================

  describe "R8: collections never carry per-record affordances" do
    # "A collection response carries type-level affordances only in its
    # top-level links; records inside it carry navigation but no affordances.
    # ... cost on a collection is N — independent of page size."
    property "no resource object inside a collection carries affordance links" do
      check all(
              attrs_list <- list_of(document_attrs_gen(), max_length: 25),
              actor <- actor_gen(),
              max_runs: 25
            ) do
        # Isolate this collection: wipe the table, then insert exactly the
        # generated records, so page size is genuinely the fuzzed variable.
        clear_documents()
        Enum.each(attrs_list, &create_document/1)

        body = json_get("/documents", actor)
        data = body["data"] || []

        assert length(data) == length(attrs_list)

        affordance_names =
          Document
          |> routed_actions()
          |> Enum.map(&to_string/1)
          |> MapSet.new()

        for resource_object <- data do
          links = Map.get(resource_object, "links", %{})

          offending =
            links
            |> Map.keys()
            |> Enum.filter(&MapSet.member?(affordance_names, &1))

          assert offending == [],
                 """
                 a resource object inside a collection carried affordance links
                   collection size: #{length(data)}
                   offending links: #{inspect(offending)}
                   actor:           #{inspect(actor)}
                 """
        end

        # The other half of the clause: the collection itself DOES carry
        # type-level affordances when the actor may run them.
        top_level = Map.get(body, "links", %{})

        if Ash.can?({Document, :create}, actor, domain: Domain) do
          assert Map.has_key?(top_level, "create"),
                 "a collection must advertise what may be created (R8/R9 cold start)"
        end
      end
    end
  end

  # ==================================================================
  # Property 5 — §3: the state gate advertises exactly the legal set
  # ==================================================================

  describe "§3: advertised transitions are exactly the state-legal ones" do
    # "Advertise an action only if the actor is authorized AND (it is not a
    # transition at all, or it is a legal transition from the record's current
    # state)." Order's policies are permissive, so the state gate is what
    # filters — any divergence from AshStateMachine.Info is the gate's fault.
    property "the advertised transition set equals the legal set for any reachable state" do
      check all(
              path <- order_path_gen(),
              actor <- actor_gen(),
              max_runs: 200
            ) do
        order = create_order() |> drive_order(path)
        state = order.state

        advertised = order |> affordances(actor) |> Map.keys() |> MapSet.new()

        transition_actions =
          Order
          |> AshStateMachine.Info.state_machine_transitions()
          |> Enum.map(& &1.action)
          |> Enum.uniq()
          |> MapSet.new()

        legal = legal_transitions(state)

        advertised_transitions = MapSet.intersection(advertised, transition_actions)

        assert MapSet.equal?(advertised_transitions, legal),
               """
               advertised transitions differ from the state machine's legal set
                 path driven:  #{inspect(path)}
                 state:        #{inspect(state)}
                 advertised:   #{inspect(MapSet.to_list(advertised_transitions))}
                 legal:        #{inspect(MapSet.to_list(legal))}
                 actor:        #{inspect(actor)}
               """
      end
    end

    # Legal from `state` per the public introspection API, honouring the
    # `from: :*` wildcard on :cancel.
    defp legal_transitions(state) do
      Order
      |> AshStateMachine.Info.state_machine_transitions()
      |> Enum.filter(fn transition ->
        from = List.wrap(transition.from)
        state in from or :* in from
      end)
      |> Enum.map(& &1.action)
      |> MapSet.new()
    end
  end

  # ==================================================================
  # HTTP helpers
  # ==================================================================

  defp raw_get(path, actor) do
    :get
    |> Plug.Test.conn(path)
    |> Plug.Conn.put_req_header("accept", "application/vnd.api+json")
    |> Ash.PlugHelpers.set_actor(actor)
    |> Endpoint.call(Endpoint.init([]))
    |> Map.get(:resp_body)
    |> to_string()
  end

  defp json_get(path, actor) do
    case Jason.decode(raw_get(path, actor)) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{}
    end
  end
end
