defmodule AshHateoas.Test.Actor do
  @moduledoc "A plain actor struct — not a resource, so policies can read it freely."
  defstruct [:id, :role, :org_id]
end

defmodule AshHateoas.Test.Document do
  @moduledoc """
  The primary test resource: ETS-backed, with policies that exercise both an
  attribute check (cheap, decidable without the record) and an expression check
  (record-dependent, resolved against real data).
  """

  use Ash.Resource,
    domain: AshHateoas.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshHateoas.Resource]

  ets do
    private? true
  end

  hateoas do
    type "document"
    base "/documents"
  end

  relationships do
    has_many :comments, AshHateoas.Test.Comment do
      public?(true)
      destination_attribute(:document_id)
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:body, :string, public?: true)
    attribute(:owner_id, :string, public?: true)

    # A resource in ANOTHER API. No Ash relationship can express this — they
    # resolve in-process, and the Hydra plug renders every link against the
    # requesting host — so the URL is stored and the type marks it followable.
    attribute(:related_order, AshHateoas.Type.ResourceLink, public?: true)

    attribute(:state, :atom,
      public?: true,
      default: :draft,
      constraints: [one_of: [:draft, :approved, :archived]]
    )
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:title, :body, :owner_id, :related_order])
    end

    update :update do
      primary?(true)
      accept([:title, :body])
    end

    update :approve do
      description("Approve this document so it can be published.")
      require_atomic?(false)

      argument :note, :string do
        public?(true)
        description("Why this is being approved.")
        allow_nil?(true)
      end

      argument :notify, :boolean do
        public?(true)
        description("Email the owner.")
        default(false)
      end

      argument :signing_key, :string do
        public?(true)
        sensitive?(true)
        default("default-key-do-not-leak")
        description("Signing key for the approval record.")
      end

      argument :internal_trace, :string do
        public?(false)
        default("not-for-clients")
      end

      argument :visibility, :atom do
        public?(true)
        constraints(one_of: [:public, :private])
        default(:private)
      end

      change(set_attribute(:state, :approved))
    end

    update :archive do
      description("Archive this document.")
      require_atomic?(false)
      change(set_attribute(:state, :archived))
    end
  end

  policies do
    # Attribute check: decidable without the record.
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action(:create) do
      authorize_if(actor_attribute_equals(:role, :editor))
      authorize_if(actor_attribute_equals(:role, :admin))
    end

    policy action(:approve) do
      authorize_if(actor_attribute_equals(:role, :admin))
    end

    # Expression check: record-dependent, so it exercises the path where Ash
    # must resolve the policy against real data rather than decide statically.
    policy action(:archive) do
      authorize_if(expr(owner_id == ^actor(:id)))
    end

    # Stacked `authorize_if` is OR — admin OR owner. That is deliberate here:
    # two independently-satisfiable paths make the admin/owner/stranger
    # distinctions in the tests meaningful. If you want AND, `forbid_unless`
    # the required condition first; see rules/ash/authorization.md.
    policy action(:update) do
      authorize_if(actor_attribute_equals(:role, :admin))
      authorize_if(expr(owner_id == ^actor(:id)))
    end

    policy action_type(:destroy) do
      authorize_if(actor_attribute_equals(:role, :admin))
    end
  end
end

defmodule AshHateoas.Test.PublicNote do
  @moduledoc """
  A resource with NO authorizers — `Ash.can?/3` short-circuits to true for
  every action. Exercises the "no policies means no restrictions" path.
  """

  use Ash.Resource,
    domain: AshHateoas.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshHateoas.Resource]

  ets do
    private?(true)
  end

  hateoas do
    type("public_note")
    base("/public_notes")
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:text, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: [:text]])
  end
end

defmodule AshHateoas.Test.Unrouted do
  @moduledoc """
  A resource that does not carry AshHateoas.Resource at all — exercises the
  fallback candidate path, where the set comes from actions directly.
  """

  use Ash.Resource,
    domain: AshHateoas.Test.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private?(true)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: [:label]])
  end
end

defmodule AshHateoas.Test.Domain do
  @moduledoc "Test domain wiring the resources together."

  use Ash.Domain, extensions: [AshHateoas.Domain]

  resources do
    resource(AshHateoas.Test.Document)
    resource(AshHateoas.Test.Paged)
    resource(AshHateoas.Test.Person)
    resource(AshHateoas.Test.Comment)
    resource(AshHateoas.Test.PublicNote)
    resource(AshHateoas.Test.Unrouted)
    resource(AshHateoas.Test.Secret)
    resource(AshHateoas.Test.Article)
    resource(AshHateoas.Test.Order)
    resource(AshHateoas.Test.Quiet)
    resource(AshHateoas.Test.Derived)
    resource(AshHateoas.Test.AdminOnly)
    resource(AshHateoas.Test.AutoRouted)
    resource(AshHateoas.Test.HandRouted)
    resource(AshHateoas.Test.NoJsonApi)
    resource(AshHateoas.Test.GenericGet)
    resource(AshHateoas.Test.NoBase)
    resource(AshHateoas.Test.Compensating)
    resource(AshHateoas.Test.MultiRead)
    resource(AshHateoas.Test.EagerPrepare)
    resource(AshHateoas.Test.ReadFailure)
    resource(AshHateoas.Test.AuthUser)
    resource(AshHateoas.Test.AuthToken)
    resource(AshHateoas.Test.Observed)
    resource(AshHateoas.Test.Recipe)
    resource(AshHateoas.Test.Ingredient)
    resource(AshHateoas.Test.Step)
    resource(AshHateoas.Test.HandValidated)
    resource(AshHateoas.Test.Technique)
    resource(AshHateoas.Test.RecipeTechnique)
    resource(AshHateoas.Test.RecipeAudit)
  end
end
