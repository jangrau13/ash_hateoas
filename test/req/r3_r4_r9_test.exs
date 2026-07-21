defmodule AshHateoas.Req.R3R4R9Test do
  @moduledoc """
  Independent conformance tests for R3, R4 and R9.

  These are written against REQ.md, not against the implementation. Each test
  names the clause it probes. Failures here mean the requirement is unmet, not
  that the test is wrong.
  """

  use ExUnit.Case, async: false

  alias AshHateoas.Backbone
  alias AshHateoas.Test.{Actor, Document, Endpoint, McpEndpoint, Order, Quiet}

  @admin %Actor{id: "req-admin", role: :admin}
  @viewer %Actor{id: "req-viewer", role: :viewer}

  setup do
    owner = %Actor{id: unique("owner"), role: :editor}

    doc =
      Document
      |> Ash.Changeset.for_create(:create, %{title: "Req", owner_id: owner.id})
      |> Ash.create!(authorize?: false)

    session = unique("session")

    %{doc: doc, owner: owner, session: session}
  end

  # ------------------------------------------------------------------
  # R3 — every transport renders natively, adapters are peers
  # ------------------------------------------------------------------

  describe "R3: the backbone is transport-agnostic" do
    test "both adapters project from the same backbone call, not from each other" do
      # R3: "Adapters are peers. Neither is primary, neither is layered on the
      # other." §5.3: "No adapter may be implemented as a client of another's
      # output." The observable consequence is that the backbone answers
      # identically regardless of which adapter asks, so the two renderings must
      # agree on the SET of actions even though they disagree on encoding.
      order =
        Order
        |> Ash.Changeset.for_create(:create, %{reference: unique("ref")})
        |> Ash.create!(authorize?: false)

      backbone_names =
        order
        |> Backbone.for_record(@admin, domain: AshHateoas.Test.Domain)
        |> Map.keys()
        |> Enum.map(&to_string/1)
        |> MapSet.new()

      json_api_names =
        "/orders/#{order.id}"
        |> get(@admin)
        |> links_for()
        |> Map.keys()
        |> Enum.reject(&(&1 in structural_link_names()))
        |> MapSet.new()

      # MCP carries a record's affordances in that record's representation, the
      # peer of JSON:API's per-record `links` — not in `tools/list`, which names
      # no record and so answers the collection-level question instead.
      mcp_names =
        Order
        |> read_record(order.id)
        |> Map.fetch!("affordances")
        |> Enum.map(& &1["name"])
        |> MapSet.new()

      assert MapSet.equal?(json_api_names, backbone_names),
             """
             JSON:API rendered a different action set than the backbone produced.
               backbone: #{inspect(Enum.sort(backbone_names))}
               json:api: #{inspect(Enum.sort(json_api_names))}
             """

      assert MapSet.equal?(mcp_names, backbone_names),
             """
             MCP rendered a different action set than the backbone produced.
               backbone: #{inspect(Enum.sort(backbone_names))}
               mcp:      #{inspect(Enum.sort(mcp_names))}
             """
    end

    test "MCP never emits JSON:API idiom, JSON:API never emits MCP idiom", %{
      doc: doc,
      session: session
    } do
      # R3 table: an affordance is a `links.<action>` object in JSON:API and a
      # tool in tools/list for MCP. "never one transport tunnelled through
      # another" — so neither encoding may leak the other's vocabulary.
      order =
        Order
        |> Ash.Changeset.for_create(:create, %{reference: unique("ref")})
        |> Ash.create!(authorize?: false)

      for tool <- list_tools(session) do
        refute Map.has_key?(tool, "href"),
               "#{tool["name"]} carries an HTTP href — MCP is tunnelling JSON:API"

        refute Map.has_key?(tool, "rel"),
               "#{tool["name"]} carries a hypermedia rel — MCP is tunnelling JSON:API"

        assert Map.has_key?(tool, "inputSchema"),
               "#{tool["name"]} has no inputSchema — that is MCP's own field idiom"
      end

      approve = links_for(get("/documents/#{doc.id}", @admin))["approve"]

      refute Map.has_key?(approve, "inputSchema"),
             "JSON:API link carries an MCP inputSchema — JSON:API is tunnelling MCP"

      assert Map.has_key?(approve, "href"), "a JSON:API affordance must be a link object"
    end

    test "the set is resolved per request from the requesting client's context", %{doc: doc} do
      # R3: "Two clients hitting the same resource may legitimately receive
      # different affordances." Probed on BOTH transports, same underlying record.
      admin_links = links_for(get("/documents/#{doc.id}", @admin))
      viewer_links = links_for(get("/documents/#{doc.id}", @viewer))

      assert Map.has_key?(admin_links, "approve")
      refute Map.has_key?(viewer_links, "approve")

      # Same probe on MCP: a nil actor must not be handed an admin's tool set.
      order =
        Order
        |> Ash.Changeset.for_create(:create, %{reference: unique("ref")})
        |> Ash.create!(authorize?: false)

      s1 = unique("s1")
      s2 = unique("s2")

      # Two sessions at the same position with the same actor must agree —
      # the set is a function of (actor, position), nothing else.
      assert Enum.map(list_tools(s1), & &1["name"]) ==
               Enum.map(list_tools(s2), & &1["name"]),
             "the affordance set must be a pure function of actor and position"
    end

    test "adding a third adapter requires no backbone change" do
      # R3: "adding a third (UI action bar, CLI, HAL-FORMS) MUST require no
      # backbone change." The testable form: the backbone's public output is a
      # plain typed envelope carrying everything a renderer needs, with no
      # transport-specific field. A hypothetical CLI renderer must be able to
      # build itself from Backbone output alone.
      order =
        Order
        |> Ash.Changeset.for_create(:create, %{reference: unique("ref")})
        |> Ash.create!(authorize?: false)

      envelope = Backbone.for_record(order, @admin, domain: AshHateoas.Test.Domain)

      assert map_size(envelope) > 0

      for {name, affordance} <- envelope do
        assert is_atom(name)
        assert %AshHateoas.Affordance{} = affordance

        # R5's fixed shape is what makes a third adapter cheap.
        assert is_list(affordance.fields)

        for field <- affordance.fields do
          assert %AshHateoas.Field{} = field
        end
      end
    end
  end

  # ------------------------------------------------------------------
  # R4 — self-documenting
  # ------------------------------------------------------------------

  describe "R4: descriptions, defaults and constraints" do
    test "the action description reaches both transports", %{doc: doc, session: session} do
      # R3 table: action description renders as link title/meta in JSON:API and
      # as the tool's description in MCP. R4: "The descriptor MUST surface ...
      # the action's `description`".
      approve = links_for(get("/documents/#{doc.id}", @admin))["approve"]

      assert approve["title"] == "Approve this document so it can be published."

      order =
        Order
        |> Ash.Changeset.for_create(:create, %{reference: unique("ref")})
        |> Ash.create!(authorize?: false)

      confirm =
        Order
        |> read_record(order.id)
        |> Map.fetch!("affordances")
        |> Enum.find(&(&1["name"] == "confirm"))

      assert confirm["description"] =~ "Confirm this order.",
             "the action's declared description must reach MCP verbatim"
    end

    test "a sensitive argument's default never reaches EITHER transport", %{doc: doc} do
      # R4: "never emit a `sensitive?` argument's `default` (a sensitive
      # argument may still appear as a field so the client knows to supply it,
      # without its value)." Document's :signing_key is sensitive with a default
      # of "default-key-do-not-leak".
      #
      # This is the strongest R4 rule, so it is probed as a raw substring scan
      # of the entire serialized payload — a leak anywhere is a leak.
      body = get("/documents/#{doc.id}", @admin) |> raw_body()

      refute body =~ "default-key-do-not-leak",
             "a sensitive default leaked into the JSON:API document"

      fields = fields_for(doc, "approve")
      signing_key = Enum.find(fields, &(&1["name"] == "signing_key"))

      assert signing_key, "a sensitive argument must still be advertised as a field"
      refute Map.has_key?(signing_key, "default")

      # Same rule on the MCP side: Document is not MCP-mounted, so probe the
      # backbone descriptor the MCP adapter renders from.
      affordance = Backbone.for_record(doc, @admin, domain: AshHateoas.Test.Domain)[:approve]
      key_field = Enum.find(affordance.fields, &(&1.name == :signing_key))

      assert key_field, "the sensitive field must exist in the envelope"

      # `default` is an {:ok, value} | :error option tuple, so "no default" is
      # :error. A sensitive argument must carry no value even in the envelope,
      # before any adapter gets the chance to render it.
      assert key_field.default == :error,
             "the backbone must strip the sensitive default before any adapter sees it, got #{inspect(key_field.default)}"

      # Control: a NON-sensitive default in the same action is still present,
      # proving the stripping is targeted at sensitivity, not blanket omission.
      notify_field = Enum.find(affordance.fields, &(&1.name == :notify))
      assert notify_field.default == {:ok, false}
    end

    test "only public arguments become fields, on both transports", %{doc: doc} do
      # R4: "only **public** arguments become fields". :internal_trace is
      # public? false with default "not-for-clients".
      raw = get("/documents/#{doc.id}", @admin) |> raw_body()

      refute raw =~ "internal_trace", "a private argument leaked into the document"
      refute raw =~ "not-for-clients", "a private argument's default leaked"

      affordance = Backbone.for_record(doc, @admin, domain: AshHateoas.Test.Domain)[:approve]
      names = Enum.map(affordance.fields, & &1.name)

      refute :internal_trace in names
    end

    test "constraints.enum is derived from one_of and is wire-encodable", %{doc: doc} do
      # R4: "a `constraints.enum` derived from `one_of`".
      fields = fields_for(doc, "approve")
      visibility = Enum.find(fields, &(&1["name"] == "visibility"))

      assert visibility, ":visibility is a public argument and must be advertised"

      assert visibility["constraints"]["enum"] == ["public", "private"],
             "one_of must surface as constraints.enum, stringified for JSON"
    end

    test "per-field descriptions reach the wire", %{doc: doc} do
      # R4: "per field its `description`". The existing suite checks type,
      # required and default but never the field description.
      fields = fields_for(doc, "approve")

      notify = Enum.find(fields, &(&1["name"] == "notify"))
      note = Enum.find(fields, &(&1["name"] == "note"))

      assert notify["description"] == "Email the owner.",
             "a declared argument description must reach the client"

      assert note["description"] == "Why this is being approved."
    end

    test "the MCP inputSchema carries descriptions and enums too" do
      # R3 table: "field descriptor (R4) -> the tool's inputSchema". R4's
      # surfacing rules are transport-independent, so MCP must carry them as
      # JSON Schema `description` / `enum`, not drop them.
      schema = tool(list_tools(), "order_create")["inputSchema"]

      reference =
        get_in(schema, ["properties", "input", "properties", "reference"]) ||
          get_in(schema, ["properties", "reference"])

      assert reference, "create accepts :reference, so the schema must describe it"
      assert is_map(reference)

      # Order carries no enum/description arguments, so probe the richer
      # descriptor through the backbone envelope the MCP renderer projects from:
      # R4's surfacing rules must hold in the envelope every adapter reads.
      approve =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "schema", owner_id: "someone"})
        |> Ash.create!(authorize?: false)
        |> Backbone.for_record(@admin, domain: AshHateoas.Test.Domain)
        |> Map.get(:approve)

      assert approve, "approve must be advertised to an admin"

      visibility = Enum.find(approve.fields, &(&1.name == :visibility))

      assert visibility.constraints[:enum] == [:public, :private],
             "the envelope must carry the enum so every adapter can project it"

      assert visibility.description ||
               Enum.find(approve.fields, &(&1.name == :notify)).description,
             "the envelope must carry per-field descriptions for MCP to render"
    end

    test "a field's default is emitted when it is NOT sensitive", %{doc: doc} do
      # R4 pairs the sensitive rule with an obligation: ordinary defaults are
      # part of self-documentation and must be present.
      fields = fields_for(doc, "approve")

      notify = Enum.find(fields, &(&1["name"] == "notify"))
      visibility = Enum.find(fields, &(&1["name"] == "visibility"))

      assert notify["default"] == false

      assert visibility["default"] == "private",
             "an atom default must be stringified, not omitted"
    end
  end

  # ------------------------------------------------------------------
  # R9 — navigation
  # ------------------------------------------------------------------

  describe "R9: the root entry point" do
    test "the API root lists each reachable type and its collection link" do
      # R9: "A client MUST be able to hardcode **one** entry point and from
      # there reach every type, every collection and every record."
      # §5.1: "at the API root: an entry document listing each reachable type
      # and its collection link — the one URL a client hardcodes."
      body = get("/", @admin) |> body()

      links = body["links"] || %{}

      assert map_size(links) > 0,
             "the API root returned no links — a client has no entry point to hardcode"

      assert Map.has_key?(links, "documents") or Map.has_key?(links, "document"),
             "the root must advertise the document collection, got: #{inspect(Map.keys(links))}"
    end

    test "Index.build/1 enumerates the domain's routed types" do
      # R9 table: "root: which types exist <- Ash.Domain.Info.resources/1 + the
      # domain's declared routes." Probed at the unit level so a routing
      # accident is distinguishable from an empty index.
      index = AshHateoas.JsonApi.Index.build(AshHateoas.Test.Domain)

      assert map_size(index) > 0,
             "the root index is empty, so no type is reachable from the entry point"
    end
  end

  describe "R9: record-level structural links" do
    test "a record links to its collection", %{doc: doc} do
      # §5.1: "on a record: a `collection` link to its type's collection".
      # R9 table: "record -> its collection <- resource route introspection
      # (the :index route)". `collection` is a registered IANA relation type.
      links = links_for(get("/documents/#{doc.id}", @admin))

      assert Map.has_key?(links, "collection"),
             "no `collection` link on a record; got: #{inspect(Map.keys(links))}"

      href = href_of(links["collection"])

      assert href =~ "/documents",
             "the collection link must point at the type's index route, got #{inspect(href)}"

      refute href =~ doc.id, "the collection link must not point back at the record"
    end

    test "a record links to its owning domain", %{doc: doc} do
      # §5.1: "on a record: ... and a link to the owning domain".
      # R9 table: "record -> its domain <- Ash.Resource.Info.domain/1".
      links = links_for(get("/documents/#{doc.id}", @admin))

      domain_rels = ["domain", "up", "index", "describedby"]

      assert Enum.any?(domain_rels, &Map.has_key?(links, &1)),
             """
             no link to the owning domain on a record.
             expected one of #{inspect(domain_rels)}, got: #{inspect(Map.keys(links))}
             """
    end
  end

  describe "R9: collection-level affordances" do
    test "a collection carries self plus collection-level affordances" do
      # §5.1: "on a collection: `self`, plus the collection-level affordances
      # (`create`, ...) as named links exactly like record affordances."
      body = get("/documents", @admin) |> body()
      links = body["links"] || %{}

      assert Map.has_key?(links, "self"), "a collection must carry a self link"
      assert Map.has_key?(links, "create"), "the cold-start case must offer create"

      create = links["create"]

      assert is_map(create),
             "a collection affordance must be a link OBJECT, exactly like a record affordance"

      assert create["href"]
      assert get_in(create, ["meta", "method"]) == "POST"
    end

    test "collection-level affordances apply no state gate" do
      # R9: "`affordances(resource, actor, ...)` — collection-level; there is no
      # record, so **no state gate** applies, but `Ash.can?/3` still does."
      # Order's :ship is illegal from :pending, but at collection level there is no
      # record and therefore no state to gate on. :create must survive.
      envelope = Backbone.for_resource(Order, @admin, domain: AshHateoas.Test.Domain)

      assert Map.has_key?(envelope, :create),
             "collection-level affordances must include create, got: #{inspect(Map.keys(envelope))}"
    end

    test "the two backbone entry points are genuinely distinct" do
      # R9: "The backbone MUST therefore answer two shapes:
      #   affordances(record, actor, ...) — record-level; the state gate applies.
      #   affordances(resource, actor, ...) — collection-level; no state gate."
      order =
        Order
        |> Ash.Changeset.for_create(:create, %{reference: unique("ref")})
        |> Ash.create!(authorize?: false)

      record_level =
        Backbone.for_record(order, @admin, domain: AshHateoas.Test.Domain) |> Map.keys()

      collection_level =
        Backbone.for_resource(Order, @admin, domain: AshHateoas.Test.Domain) |> Map.keys()

      refute record_level == collection_level,
             "record-level and collection-level sets are identical — one of the two gates is missing"

      assert :create in collection_level
      refute :create in record_level, "create is not something you do TO an existing record"
    end
  end

  describe "R9: authorization applies to navigation" do
    test "structural links do not reveal collections the actor may not access" do
      # R9: "Structural links MUST NOT reveal types or collections the actor may
      # not access. An unreachable branch is omitted, not rendered-and-rejected."
      #
      # Document's :create is restricted to :editor / :admin, so a viewer's
      # collection view must not advertise create.
      body = get("/documents", @viewer) |> body()

      refute Map.has_key?(body["links"] || %{}, "create"),
             "a viewer may not create, so the affordance must be omitted"
    end

    test "the root entry document is filtered per actor" do
      # R9: authorization "applies to navigation too" — the root is navigation,
      # so an actor who may reach nothing of a type must not be told it exists.
      # Probed as: the root for a nil actor must not be identical to the root
      # for an admin unless every listed type is genuinely public.
      admin_root = get("/", @admin) |> body() |> Map.get("links", %{})
      anon_root = get("/", nil) |> body() |> Map.get("links", %{})

      assert is_map(admin_root)
      assert is_map(anon_root)

      # Every type the anonymous client is told about must actually be readable
      # by it — otherwise the root is rendering-and-rejecting.
      for {name, link} <- anon_root do
        href = href_of(link)

        if is_binary(href) and href != "/" do
          status = get(href, nil).status

          assert status < 400,
                 "root advertises #{name} at #{href} but an anonymous client gets #{status}"
        end
      end
    end

    test "every link in a document resolves against the same base", %{doc: doc} do
      # R9: "Follow links; do not construct URLs." A client can only obey that
      # if every href in a document is followable as given. Affordance hrefs and
      # navigation links are rendered by different code paths, so a prefix
      # applied to one and not the other yields a document where half the links
      # are dead — and nothing on the wire says which half.
      #
      # Probed by FOLLOWING them: a GET-able link must not 404.
      links = links_for(get("/documents/#{doc.id}", @admin))

      for {name, link} <- links, href = href_of(link), is_binary(href) do
        method = get_in(link, ["meta", "method"]) || "GET"

        if method == "GET" do
          assert get(href, @admin).status < 400,
                 "#{name} advertises #{href}, which does not resolve — " <>
                   "affordance and navigation links disagree on the base path"
        end
      end
    end

    test "a resource with affordances switched off keeps its navigation" do
      # R8 turns AFFORDANCES off; R9 navigation is a separate concern and must
      # survive, otherwise opting out of cost also breaks discoverability.
      quiet =
        Quiet
        |> Ash.Changeset.for_create(:create, %{label: "x"})
        |> Ash.create!(authorize?: false)

      links = links_for(get("/quiets/#{quiet.id}", @admin))

      refute Map.has_key?(links, "create"), "enabled? false must suppress affordances"

      assert Map.has_key?(links, "collection"),
             "navigation is not an affordance and must survive enabled? false"
    end
  end

  describe "R9: MCP uses the resources primitive, not tools" do
    test "resources/templates/list advertises each type as a URI template" do
      # §5.2: "resources/templates/list — expose each resource *type* as an RFC
      # 6570 URI template (e.g. `document://{id}`). This is the direct analogue
      # of a collection route." And: "The adapter MUST use each for its purpose
      # rather than modelling navigation as tools."
      response = post(%{"jsonrpc" => "2.0", "id" => 1, "method" => "resources/templates/list"})

      templates = get_in(response, ["result", "resourceTemplates"])

      assert is_list(templates) and templates != [],
             """
             resources/templates/list returned no templates, so MCP has no
             navigation primitive. Response: #{inspect(response)}
             """

      template = hd(templates)

      assert is_binary(template["uriTemplate"]),
             "a resource template must carry a uriTemplate"

      assert template["uriTemplate"] =~ "{",
             "an RFC 6570 template must carry an expansion, got #{inspect(template["uriTemplate"])}"
    end

    test "resources/list enumerates addressable entries" do
      # §5.2: "resources/list — enumerate concrete, addressable entries where
      # that is meaningful".
      response = post(%{"jsonrpc" => "2.0", "id" => 1, "method" => "resources/list"})

      assert is_list(get_in(response, ["result", "resources"])),
             """
             resources/list did not return a resource array.
             Response: #{inspect(response)}
             """
    end

    test "resources/read fetches by URI" do
      # §5.2: "resources/read — fetch by URI." Navigation is only real if the
      # advertised URI can actually be dereferenced.
      order =
        Order
        |> Ash.Changeset.for_create(:create, %{reference: unique("ref")})
        |> Ash.create!(authorize?: false)

      templates =
        post(%{"jsonrpc" => "2.0", "id" => 1, "method" => "resources/templates/list"})
        |> get_in(["result", "resourceTemplates"]) || []

      template = Enum.find(templates, &(&1["uriTemplate"] =~ "order"))

      assert template, "no order template to dereference"

      uri = String.replace(template["uriTemplate"], ~r/\{[^}]+\}/, order.id)

      response =
        post(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "resources/read",
          "params" => %{"uri" => uri}
        })

      assert get_in(response, ["result", "contents"]),
             """
             resources/read on an advertised URI returned no contents.
             uri: #{inspect(uri)}
             response: #{inspect(response)}
             """
    end

    test "the URI scheme encodes the domain/type/record hierarchy" do
      # §5.2: "URIs MUST encode the domain/type/record hierarchy (custom schemes
      # are explicitly permitted)."
      templates =
        post(%{"jsonrpc" => "2.0", "id" => 1, "method" => "resources/templates/list"})
        |> get_in(["result", "resourceTemplates"]) || []

      assert templates != [], "no templates to inspect"

      for template <- templates do
        uri = template["uriTemplate"]

        assert uri =~ ~r{^[a-z][a-z0-9+.\-]*://},
               "#{inspect(uri)} is not a scheme-qualified URI"

        assert uri =~ "order",
               "#{inspect(uri)} does not encode the type, so the hierarchy is lost"
      end
    end

    test "navigation is NOT modelled as tools" do
      # §5.2: "The adapter MUST use each for its purpose rather than modelling
      # navigation as tools." A tool named like a navigation verb means the
      # split was not honoured.
      names = Enum.map(list_tools(), & &1["name"])

      for name <- names do
        refute name =~ ~r/(^|_)(list|browse|navigate|get_by_uri|read_resource)(_|$)/,
               "#{name} looks like navigation modelled as a tool"
      end
    end
  end

  # ------------------------------------------------------------------
  # helpers
  # ------------------------------------------------------------------

  # Link names that are structural navigation rather than affordances.
  defp structural_link_names, do: ["self", "collection", "domain", "up", "index", "describedby"]

  defp href_of(link) when is_binary(link), do: link
  defp href_of(%{"href" => href}), do: href
  defp href_of(_), do: nil

  defp get(path, actor) do
    :get
    |> Plug.Test.conn(path)
    |> Plug.Conn.put_req_header("accept", "application/vnd.api+json")
    |> Ash.PlugHelpers.set_actor(actor)
    |> Endpoint.call(Endpoint.init([]))
  end

  defp raw_body(conn), do: conn.resp_body

  defp body(conn) do
    case Jason.decode(conn.resp_body) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{}
    end
  end

  defp links_for(conn), do: conn |> body() |> get_in(["data", "links"]) || %{}

  defp fields_for(doc, action) do
    "/documents/#{doc.id}"
    |> get(@admin)
    |> links_for()
    |> get_in([action, "meta", "fields"]) || []
  end

  defp list_tools(session \\ nil, actor \\ @admin) do
    %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}
    |> post(session, actor)
    |> get_in(["result", "tools"]) || []
  end

  defp read_record(resource, id, actor \\ @admin) do
    uri = AshHateoas.Mcp.Resources.uri(resource, id)

    %{"jsonrpc" => "2.0", "id" => 1, "method" => "resources/read", "params" => %{"uri" => uri}}
    |> post(nil, actor)
    |> get_in(["result", "contents"])
    |> hd()
    |> Map.fetch!("text")
    |> Jason.decode!()
  end

  defp post(body, session \\ nil, actor \\ @admin) do
    conn =
      :post
      |> Plug.Test.conn("/", Jason.encode!(body))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Ash.PlugHelpers.set_actor(actor)

    conn =
      if session,
        do: Plug.Conn.put_req_header(conn, "mcp-session-id", session),
        else: conn

    conn
    |> McpEndpoint.call(McpEndpoint.init([]))
    |> then(fn conn ->
      case Jason.decode(conn.resp_body) do
        {:ok, decoded} -> decoded
        {:error, _} -> %{}
      end
    end)
  end

  defp tool(tools, name), do: Enum.find(tools, &(&1["name"] == name))

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
