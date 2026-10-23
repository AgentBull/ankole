defmodule Ankole.Brain.Schemas.Contradiction do
  @moduledoc "Immutable proposal facts and their one-time review decision."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Brain,
    extensions: [AshStateMachine, AshJsonApi.Resource]

  # The Console list gives the text of both Claims of a finding.
  json_api do
    type("brain_contradiction")
    derive_filter?(false)
    derive_sort?(false)

    default_fields([
      :a_claim_text,
      :b_claim_text,
      :verdict,
      :axis,
      :severity,
      :confidence,
      :status,
      :created_at
    ])
  end

  postgres do
    table("brain_contradictions")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(proposal: "brain_contradictions_pair_key")

    foreign_key_names([
      {:a_claim_id, "brain_contradictions_a_claim_id_fkey"},
      {:b_claim_id, "brain_contradictions_b_claim_id_fkey"}
    ])

    check_constraints do
      check_constraint(:severity, "brain_contradictions_severity_values")
      check_constraint(:status, "brain_contradictions_status_values")
      check_constraint(:confidence, "brain_contradictions_confidence_range")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:a_claim_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:b_claim_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:verdict, :string, allow_nil?: false, public?: true, constraints: [trim?: false])

    attribute(:axis, :string,
      allow_nil?: false,
      public?: true,
      default: "",
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:severity, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:info, :low, :medium, :high]]
    )

    attribute(:confidence, :float,
      allow_nil?: false,
      public?: true,
      constraints: [min: 0.0, max: 1.0]
    )

    attribute(:resolution_note, :string,
      allow_nil?: true,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:created_at, :utc_datetime_usec,
      allow_nil?: false,
      public?: true,
      default: &DateTime.utc_now/0
    )

    attribute(:decided_at, :utc_datetime_usec)
  end

  relationships do
    belongs_to :a_claim, Ankole.Brain.Schemas.Claim do
      source_attribute(:a_claim_id)
      define_attribute?(false)
    end

    belongs_to :b_claim, Ankole.Brain.Schemas.Claim do
      source_attribute(:b_claim_id)
      define_attribute?(false)
    end
  end

  calculations do
    calculate(:a_claim_text, :string, expr(a_claim.claim), public?: true)
    calculate(:b_claim_text, :string, expr(b_claim.claim), public?: true)
  end

  identities do
    identity(:proposal, [:a_claim_id, :b_claim_id])
  end

  state_machine do
    state_attribute(:status)
    initial_states([:open, :dismissed])

    transitions do
      transition(:resolve, from: :open, to: :resolved)
      transition(:dismiss, from: :open, to: :dismissed)
    end
  end

  actions do
    defaults([:read])

    # The Console list: the first 100 findings of one status, newest first.
    read :console_list do
      argument(:status, :atom,
        default: :open,
        constraints: [one_of: [:open, :resolved, :dismissed]]
      )

      filter(expr(status == ^arg(:status)))
      prepare(build(sort: [created_at: :desc], limit: 100))
    end

    create_if_absent :record_verdict do
      accept([
        :id,
        :a_claim_id,
        :b_claim_id,
        :verdict,
        :axis,
        :severity,
        :confidence,
        :created_at
      ])

      upsert_identity(:proposal)
      change(Ankole.Brain.Changes.ClassifyContradiction)
    end

    update :resolve do
      require_atomic?(true)
      accept([:resolution_note])
      change(set_attribute(:decided_at, &DateTime.utc_now/0))
      change(transition_state(:resolved))
    end

    update :dismiss do
      require_atomic?(true)
      accept([:resolution_note])
      change(set_attribute(:decided_at, &DateTime.utc_now/0))
      change(transition_state(:dismissed))
    end

    # An operator decision locks the finding and owns its transaction.
    action :decide, :struct do
      constraints(instance_of: __MODULE__)
      argument(:contradiction_id, :uuid, allow_nil?: false)

      argument(:status, :atom,
        allow_nil?: false,
        constraints: [one_of: [:resolved, :dismissed]]
      )

      argument(:resolution_note, :string, constraints: [trim?: false, allow_empty?: true])

      run(fn %{arguments: args}, _context ->
        args.contradiction_id
        |> Ankole.Brain.Dreaming.decide_contradiction_in_tx(args.status, args[:resolution_note])
        |> Ankole.Brain.Console.result(__MODULE__)
      end)
    end
  end

  @type t :: %__MODULE__{}
end
