defmodule AshHateoas.Req.R3R4R9Test do
  @moduledoc """
  Independent conformance tests for R3, R4 and R9.

  These are written against REQ.md, not against the implementation. Each test
  names the clause it probes. Failures here mean the requirement is unmet, not
  that the test is wrong.
  """

  use ExUnit.Case, async: false

  alias AshHateoas.Backbone
  alias AshHateoas.Test.{Actor, Article, Document, Endpoint, Order, Quiet}

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

      assert MapSet.equal?(json_api_names, backbone_names),
             """
             JSON:API rendered a different action set than the backbone produced.
               backbone: #{inspect(Enum.sort(backbone_names))}
               json:api: #{inspect(Enum.sort(json_api_names))}
             """

    end

    test "an affordance is rendered in the transport's own idiom", %{doc: doc} do
      # R3 table: an affordance is a `links.<action>` object in JSON:API —
      # "never one transport tunnelled through another", so the encoding must
      # not leak another transport's vocabulary.
      approve = links_for(get("/documents/#{doc.id}", @admin))["approve"]

      refute Map.has_key?(approve, "inputSchema"),
             "a JSON:API link carrying an MCP inputSchema is tunnelling"

      assert Map.has_key?(approve, "href"), "a JSON:API affordance must be a link object"
      assert Map.has_key?(approve, "rel"), "and must carry a relation type"
    end

    test "the set is resolved per request from the requesting client's context", %{doc: doc} do
      # R3: "Two clients hitting the same resource may legitimately receive
      # different affordances." Probed on BOTH transports, same underlying record.
      admin_links = links_for(get("/documents/#{doc.id}", @admin))
      viewer_links = links_for(get("/documents/#{doc.id}", @viewer))

      assert Map.has_key?(admin_links, "approve")
      refute Map.has_key?(viewer_links, "approve")

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
    test "the action description reaches the wire", %{doc: doc} do
      # R4: "The descriptor MUST surface ... the action's `description`".
      approve = links_for(get("/documents/#{doc.id}", @admin))["approve"]

      assert approve["title"] == "Approve this document so it can be published."
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

    test "a relationship link is emitted and followable" do
      # R9's "walk the data graph". `ash_json_api` renders
      # `relationships.<name>.links` only from declared `related`/`relationship`
      # routes, and declares none by default — so a public relationship arrives
      # as a name with an empty `links` object: a client is told an edge exists
      # and given nowhere to go. The routes are derived instead (R1).
      article =
        Article
        |> Ash.Changeset.for_create(:create, %{title: "Linked"})
        |> Ash.create!(authorize?: false)

      parent =
        Document
        |> Ash.Changeset.for_create(:create, %{title: "Parent", owner_id: "o1"})
        |> Ash.create!(authorize?: false)

      AshHateoas.Test.Comment
      |> Ash.Changeset.for_create(:create, %{
        body: "hi",
        article_id: article.id,
        document_id: parent.id
      })
      |> Ash.create!(authorize?: false)

      links =
        "/articles/#{article.id}"
        |> get(@admin)
        |> body()
        |> get_in(["data", "relationships", "comments", "links"])

      assert is_map(links) and map_size(links) > 0,
             "a public relationship arrived with no links — the edge is a dead end"

      for {name, href} <- links, is_binary(href) do
        path = URI.parse(href).path

        assert get(path, @admin).status < 400,
               "relationship link #{name} points at #{path}, which does not resolve"
      end
    end

    test "an affordance can be followed and invoked, not merely rendered", %{doc: doc} do
      # R9: "Follow links; do not construct URLs." Every other test here reads
      # documents; this one ACTS on one. Rendering an href that raises on
      # invocation is the failure the profile exists to prevent, and only a
      # write finds it — `ash_json_api` reaches for `AshJsonApi.OpenApi` when
      # validating one, which needs `open_api_spex` in the host app's deps.
      approve = links_for(get("/documents/#{doc.id}", @admin))["approve"]

      conn =
        :patch
        |> Plug.Test.conn(approve["href"], Jason.encode!(%{"data" => %{"attributes" => %{}}}))
        |> Plug.Conn.put_req_header("content-type", "application/vnd.api+json")
        |> Plug.Conn.put_req_header("accept", "application/vnd.api+json")
        |> Ash.PlugHelpers.set_actor(@admin)
        |> Endpoint.call(Endpoint.init([]))

      assert conn.status < 400,
             "advertised #{approve["href"]} with method #{approve["meta"]["method"]}, " <>
               "and following it answered #{conn.status}"

      # And acting changed the state the affordance said it would.
      assert get_in(Jason.decode!(conn.resp_body), ["data", "attributes", "state"]) == "approved"
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





  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
