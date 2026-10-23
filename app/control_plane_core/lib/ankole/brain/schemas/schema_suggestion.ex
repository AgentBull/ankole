defmodule Ankole.Brain.Schemas.SchemaSuggestion do
  @moduledoc "Immutable proposal facts and their one-time review decision."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Brain,
    extensions: [AshStateMachine, AshJsonApi.Resource]

  json_api do
    type("brain_schema_suggestion")
    derive_filter?(false)
    derive_sort?(false)

    default_fields([
      :kind,
      :term,
      :target_type,
      :evidence_count,
      :rationale,
      :status,
      :created_at
    ])
  end

  postgres do
    table("brain_schema_suggestions")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(proposal: "brain_schema_suggestions_pending_key")
    identity_wheres_to_sql(proposal: "status = 'pending'")

    check_constraints do
      check_constraint(:kind, "brain_schema_suggestions_kind_values")
      check_constraint(:status, "brain_schema_suggestions_status_values")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:kind, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:new_type, :new_subtype, :alias]]
    )

    attribute(:term, :string, allow_nil?: false, public?: true, constraints: [trim?: false])

    attribute(:target_type, :string,
      allow_nil?: true,
      public?: true,
      constraints: [trim?: false]
    )

    attribute(:evidence_count, :integer, allow_nil?: false, public?: true, constraints: [min: 0])

    attribute(:rationale, :string,
      allow_nil?: false,
      public?: true,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:decided_by, Ankole.Ash.Types.ActorRef)

    attribute(:created_at, :utc_datetime_usec,
      allow_nil?: false,
      public?: true,
      default: &DateTime.utc_now/0
    )

    attribute(:decided_at, :utc_datetime_usec)
  end

  identities do
    identity(:proposal, [:term, :kind], where: expr(status == :pending))
  end

  state_machine do
    state_attribute(:status)
    initial_states([:pending])
    default_initial_state(:pending)

    transitions do
      transition(:approve, from: :pending, to: :approved)
      transition(:reject, from: :pending, to: :rejected)
    end
  end

  actions do
    defaults([:read])

    # The Console list: the first 100 suggestions of one status, newest first.
    read :console_list do
      argument(:status, :atom,
        default: :pending,
        constraints: [one_of: [:pending, :approved, :rejected]]
      )

      filter(expr(status == ^arg(:status)))
      prepare(build(sort: [created_at: :desc], limit: 100))
    end

    create_if_absent :suggest do
      accept([:id, :kind, :term, :target_type, :evidence_count, :rationale, :created_at])
      upsert_identity(:proposal)
    end

    update :approve do
      require_atomic?(true)
      accept([])
      argument(:decided_by, Ankole.Ash.Types.ActorRef, allow_nil?: false)
      change(set_attribute(:decided_by, arg(:decided_by)))
      change(set_attribute(:decided_at, &DateTime.utc_now/0))
      change(transition_state(:approved))
    end

    update :reject do
      require_atomic?(true)
      accept([])
      argument(:decided_by, Ankole.Ash.Types.ActorRef, allow_nil?: false)
      change(set_attribute(:decided_by, arg(:decided_by)))
      change(set_attribute(:decided_at, &DateTime.utc_now/0))
      change(transition_state(:rejected))
    end

    # Each review decision owns its transaction; Ankole.Brain.Promotion gives
    # the steps.
    action :approve_promotion, :map do
      argument(:suggestion_id, :uuid, allow_nil?: false)
      argument(:decided_by, Ankole.Ash.Types.ActorRef, allow_nil?: false)
      argument(:attrs, :map, default: %{})

      run(fn %{arguments: args}, _context ->
        args.suggestion_id
        |> Ankole.Brain.Promotion.approve_in_tx(args.decided_by, args.attrs)
        |> Ankole.Errors.wrap()
      end)
    end

    # The Console review. The reviewer is the actor of the action
    # (Ankole.Brain.Console).
    action :console_approve do
      argument(:suggestion_id, :uuid, allow_nil?: false)
      argument(:primitive, :string)
      argument(:slug_prefix, :string)
      argument(:target_type, :string)
      argument(:extractable, :boolean)

      run(fn %{arguments: args}, context ->
        attrs = Map.take(args, [:primitive, :slug_prefix, :target_type, :extractable])
        decided_by = Ankole.Brain.Console.actor_ref(context)

        with {:ok, _outcome} <-
               Ankole.Brain.Console.result(
                 Ankole.Brain.Promotion.approve_in_tx(args.suggestion_id, decided_by, attrs)
               ),
             do: :ok
      end)
    end

    action :console_reject, :struct do
      constraints(instance_of: __MODULE__)
      argument(:suggestion_id, :uuid, allow_nil?: false)

      run(fn %{arguments: args}, context ->
        args.suggestion_id
        |> Ankole.Brain.Promotion.reject_in_tx(Ankole.Brain.Console.actor_ref(context))
        |> Ankole.Brain.Console.result()
      end)
    end

    action :reject_promotion, :struct do
      constraints(instance_of: __MODULE__)
      argument(:suggestion_id, :uuid, allow_nil?: false)
      argument(:decided_by, Ankole.Ash.Types.ActorRef, allow_nil?: false)

      run(fn %{arguments: args}, _context ->
        args.suggestion_id
        |> Ankole.Brain.Promotion.reject_in_tx(args.decided_by)
        |> Ankole.Errors.wrap()
      end)
    end
  end

  @type t :: %__MODULE__{}
end
