defmodule AshHateoas.BackboneTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AshHateoas.Affordance
  alias AshHateoas.Test.{Actor, Document, Domain, PublicNote, Unrouted}

  @admin %Actor{id: "admin-1", role: :admin}
  @viewer %Actor{id: "viewer-1", role: :viewer}

  # Fixed values in identity-bearing fields deadlock under concurrent tests, so
  # each test gets its own owner. `editor` and `doc` are generated per test and
  # travel together — the owner is the actor the record's expression policies
  # (`expr(owner_id == ^actor(:id))`) will match.
  setup do
    editor = %Actor{id: unique("editor"), role: :editor}

    doc =
      Document
      |> Ash.Changeset.for_create(:create, %{title: "Spec", owner_id: editor.id})
      |> Ash.create!(authorize?: false)

    %{doc: doc, editor: editor}
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  describe "record-level affordances" do
    test "advertises actions the actor is authorized for", %{doc: doc} do
      names = doc |> affordances(@admin) |> Map.keys() |> MapSet.new()

      assert MapSet.member?(names, :approve)
      assert MapSet.member?(names, :update)
      assert MapSet.member?(names, :destroy)
    end

    test "drops actions the actor is not authorized for", %{doc: doc} do
      names = doc |> affordances(@viewer) |> Map.keys() |> MapSet.new()

      refute MapSet.member?(names, :approve),
             "viewer must not be offered :approve — its policy requires role :admin"

      refute MapSet.member?(names, :destroy)
    end

    test "two actors receive different sets for the same record", %{doc: doc} do
      assert affordances(doc, @admin) != affordances(doc, @viewer)
    end

    test "returns an empty map rather than nil when nothing survives", %{doc: doc} do
      assert affordances(doc, @viewer, gates: [AshHateoas.Test.DenyAllGate]) == %{}
    end
  end

  describe "collection-level affordances" do
    test "offers create without a record in hand" do
      names = Document |> affordances_for_type(@admin) |> Map.keys() |> MapSet.new()

      assert MapSet.member?(names, :create),
             "the cold-start case must tell a client it may create"
    end

    test "does not offer record-only actions" do
      names = Document |> affordances_for_type(@admin) |> Map.keys() |> MapSet.new()

      refute MapSet.member?(names, :approve)
      refute MapSet.member?(names, :destroy)
    end

    test "still applies authorization" do
      names = Document |> affordances_for_type(@viewer) |> Map.keys() |> MapSet.new()

      refute MapSet.member?(names, :create),
             "viewer's role is neither :editor nor :admin"
    end

    test "editor may create but viewer may not", %{editor: editor} do
      assert Document |> affordances_for_type(editor) |> Map.has_key?(:create)
      refute Document |> affordances_for_type(@viewer) |> Map.has_key?(:create)
    end
  end

  describe "record-dependent policies are resolved, not guessed" do
    # :archive is gated by `expr(owner_id == ^actor(:id))`. Because the record
    # is passed as the subject, `run_queries?` (default true) lets Ash resolve
    # the expression against real data rather than degrading to `:maybe`.
    #
    # This is the case that could have been imprecise, and it turns out not to
    # be: the owner is offered :archive and a stranger is not. The `maybe_is:
    # true` default only matters where a decision genuinely cannot be reached.

    test "offers the action to the record's owner", %{doc: doc, editor: editor} do
      owner = %Actor{editor | role: :viewer}

      assert doc |> affordances(owner) |> Map.has_key?(:archive),
             "the owner satisfies expr(owner_id == ^actor(:id))"
    end

    test "withholds the action from a non-owner", %{doc: doc} do
      stranger = %Actor{id: unique("stranger"), role: :viewer}

      refute doc |> affordances(stranger) |> Map.has_key?(:archive),
             "a record-dependent policy must be resolved against the record, not assumed"
    end

    test "the same record yields different sets for owner and stranger", %{
      doc: doc,
      editor: editor
    } do
      owner = %Actor{editor | role: :viewer}
      stranger = %Actor{id: unique("stranger"), role: :viewer}

      assert affordances(doc, owner) != affordances(doc, stranger)
    end
  end

  describe "read policies that are filters" do
    # A read policy of `expr(owner_id == ^actor(:id))` is a FILTER: the query
    # succeeds for anyone and simply returns fewer rows. Asking "may you read?"
    # in the abstract is therefore the wrong question — the gate passes `data:`
    # so the question becomes "may you read THIS record?".
    setup do
      owner = %Actor{id: unique("secret-owner"), role: :viewer}

      secret =
        AshHateoas.Test.Secret
        |> Ash.Changeset.for_create(:create, %{body: "classified", owner_id: owner.id})
        |> Ash.create!(authorize?: false)

      %{secret: secret, owner: owner}
    end

    test "offers :read to the owner", %{secret: secret, owner: owner} do
      assert secret |> affordances(owner) |> Map.has_key?(:read)
    end

    test "withholds :read from a non-owner", %{secret: secret} do
      stranger = %Actor{id: unique("stranger"), role: :viewer}

      refute secret |> affordances(stranger) |> Map.has_key?(:read),
             "a filter-based read policy must not advertise a record the actor cannot see"
    end
  end

  describe "resources with no authorizers" do
    test "advertise every routed action, per Ash semantics" do
      note =
        PublicNote
        |> Ash.Changeset.for_create(:create, %{text: "hi"})
        |> Ash.create!(authorize?: false)

      names = note |> affordances(nil) |> Map.keys() |> MapSet.new()

      assert MapSet.member?(names, :destroy),
             "no policies means no restrictions — Ash.can?/3 short-circuits to true"
    end
  end

  describe "candidate fallback when no routes are declared" do
    test "falls back to the resource's actions when no routes are declared" do
      record =
        Unrouted
        |> Ash.Changeset.for_create(:create, %{label: "x"})
        |> Ash.create!(authorize?: false)

      affordances = affordances(record, @admin)

      assert map_size(affordances) > 0,
             "a resource with no derived routes must still produce affordances"

      assert Map.has_key?(affordances, :destroy)
    end

    test "affordances from the fallback path have no href" do
      record =
        Unrouted
        |> Ash.Changeset.for_create(:create, %{label: "x"})
        |> Ash.create!(authorize?: false)

      for {_name, affordance} <- affordances(record, @admin) do
        assert affordance.href == nil
      end
    end
  end

  describe "descriptors" do
    test "surface the action's description verbatim", %{doc: doc} do
      %Affordance{description: description} = affordances(doc, @admin)[:approve]

      assert description == "Approve this document so it can be published."
    end

    test "derive href and method from the declared route", %{doc: doc} do
      %Affordance{href: href, method: method} = affordances(doc, @admin)[:approve]

      assert href == "/documents/:id/approve"
      assert method == :patch
    end

    test "include only public arguments", %{doc: doc} do
      names = field_names(affordances(doc, @admin)[:approve])

      assert :note in names
      assert :notify in names
      refute :internal_trace in names, "private arguments must never be exposed"
    end

    test "never emit a sensitive argument's default, but keep the field", %{doc: doc} do
      field = find_field(affordances(doc, @admin)[:approve], :signing_key)

      assert field, "a sensitive argument must still appear so clients know to supply it"

      assert field.default == :error,
             "a sensitive argument's default must never reach the wire"
    end

    test "emit non-sensitive defaults wrapped so nil is distinguishable", %{doc: doc} do
      field = find_field(affordances(doc, @admin)[:approve], :notify)

      assert field.default == {:ok, false}
    end

    test "derive constraints.enum from one_of", %{doc: doc} do
      field = find_field(affordances(doc, @admin)[:approve], :visibility)

      assert field.constraints[:enum] == [:public, :private]
    end

    test "map field types through the type table", %{doc: doc} do
      approve = affordances(doc, @admin)[:approve]

      assert find_field(approve, :note).type == "string"
      assert find_field(approve, :notify).type == "boolean"
    end

    test "carry Ash's allow_nil? name and polarity, not the wire's required", %{doc: doc} do
      # The Hydra renderer inverts this at the edge (a hydra:SupportedProperty
      # is described by `hydra:required`). Pinning the polarity here means an
      # accidental flip fails loudly rather than silently marking optional
      # fields mandatory.
      approve = affordances(doc, @admin)[:approve]

      assert find_field(approve, :note).allow_nil? == true,
             ":note declares allow_nil? true, so the field must too"
    end
  end

  describe "overrides and exclusions" do
    test "exclude drops an action from the set", %{doc: doc} do
      refute doc
             |> affordances(@admin, exclude: [:approve])
             |> Map.has_key?(:approve)
    end

    test "override replaces the derived href", %{doc: doc} do
      affordances = affordances(doc, @admin, overrides: %{approve: [href: "/custom/path"]})

      assert affordances[:approve].href == "/custom/path"
    end

    test "override leaves other affordances untouched", %{doc: doc} do
      affordances = affordances(doc, @admin, overrides: %{approve: [href: "/custom/path"]})

      assert affordances[:update].href == "/documents/:id"
    end
  end

  describe "gate chain" do
    test "a custom gate can reduce the set", %{doc: doc} do
      gates = [AshHateoas.Gate.Authorization, AshHateoas.Test.OnlyReadGate]

      assert doc |> affordances(@admin, gates: gates) |> Map.keys() == [:read]
    end

    test "short-circuits without running later gates once empty", %{doc: doc} do
      gates = [AshHateoas.Test.DenyAllGate, AshHateoas.Test.RaisingGate]

      assert affordances(doc, @admin, gates: gates) == %{}
    end
  end

  describe "errors are loud" do
    test "a raising authorization check is logged and the affordance dropped", %{doc: doc} do
      log =
        capture_log(fn ->
          assert affordances(doc, @admin, gates: [AshHateoas.Test.RaisingAuthGate]) == %{}
        end)

      assert log =~ "ash_hateoas",
             "an unexpected exception must be logged, not silently swallowed"
    end
  end

  describe "domain resolution" do
    test "raises a helpful error when the resource declares no domain" do
      # A module that is a resource but has no domain of its own. Ash raises for
      # a non-DSL module before we get a chance to, so use a real resource and
      # stub the lookup by passing an explicit nil domain.
      assert_raise ArgumentError, ~r/could not determine the domain/, fn ->
        AshHateoas.Backbone.for_resource(AshHateoas.Test.Domainless, @admin, [])
      end
    end

    test "uses the resource's own domain when none is passed", %{doc: doc} do
      assert AshHateoas.affordances(doc, @admin) |> map_size() > 0,
             "Document declares its domain, so :domain should be optional"
    end
  end

  defp affordances(record, actor, opts \\ []) do
    AshHateoas.affordances(record, actor, Keyword.put_new(opts, :domain, Domain))
  end

  defp affordances_for_type(resource, actor, opts \\ []) do
    AshHateoas.affordances(resource, actor, Keyword.put_new(opts, :domain, Domain))
  end

  defp field_names(%Affordance{fields: fields}), do: Enum.map(fields, & &1.name)

  defp find_field(%Affordance{fields: fields}, name) do
    Enum.find(fields, &(&1.name == name))
  end
end
