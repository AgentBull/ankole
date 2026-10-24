defmodule Ankole.AgentWorkers.AgentWorker do
  @moduledoc "The durable lifecycle, launch identity, and current connection of one Agent's Worker."
  use Ankole.Ash.Resource,
    authorizers: [Ankole.AuthZ.Authorizer],
    tenancy: :tenant,
    domain: Ankole.AgentWorkers,
    extensions: [Ankole.AuthZ.Extension, AshStateMachine, AshJsonApi.Resource]

  authz do
    scope(:site_console)
    resolve_param(:agent_uid, :principal_key)
    allow(:console_list, resource: "site_console:agent_workers", action: "read")
    allow(:console_assign_provider, resource: "site_console:agent:{agent_uid}", action: "update")
  end

  alias Ankole.AgentWorkers.ReconcileJob

  # The fields that the Console shows for each Worker.
  @console_fields [
    :provider_id,
    :state,
    :generation,
    :image,
    :capacity,
    :load,
    :last_worker_heartbeat_at,
    :state_changed_at,
    :drain_reason,
    :last_error
  ]
  @states [:absent, :starting, :ready, :stale, :paused, :draining, :deleting]
  @generation_fields [
    :generation,
    :create_sent_at,
    :token_digest,
    :token_ciphertext,
    :instance_seen_at,
    :instance_ref,
    :image,
    :protocol_version,
    :settings_digest,
    :instance_settings,
    :incarnation_id,
    :transport_route,
    :capacity,
    :load,
    :last_worker_heartbeat_at,
    :drain_reason
  ]

  postgres do
    table("agent_workers")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(transport_route: "agent_workers_transport_route_index")
    identity_wheres_to_sql(transport_route: "transport_route IS NOT NULL")
    foreign_key_names(provider_id: "agent_workers_provider_id_fkey")

    check_constraints do
      check_constraint(:state, "agent_workers_state_check")
      check_constraint(:generation, "agent_workers_generation_state")
      check_constraint(:create_sent_at, "agent_workers_create_sent_generation")
      check_constraint(:token_digest, "agent_workers_token_with_generation")
      check_constraint(:token_ciphertext, "agent_workers_ciphertext_with_generation")
      check_constraint(:instance_seen_at, "agent_workers_seen_with_generation")

      check_constraint(
        [:image, :protocol_version, :settings_digest],
        "agent_workers_target_with_generation"
      )

      check_constraint(:provider_id, "agent_workers_provider_with_generation")
      check_constraint(:storage_ref, "agent_workers_storage_ref_object")
      check_constraint(:instance_settings, "agent_workers_instance_settings_object")
      check_constraint(:transport_route, "agent_workers_route_state")
      check_constraint(:state, "agent_workers_ready_connection")
      check_constraint(:capacity, "agent_workers_capacity_object")
      check_constraint(:load, "agent_workers_load_object")
      check_constraint(:last_error_kind, "agent_workers_error_kind")
      check_constraint([:last_error, :last_error_kind], "agent_workers_error_pair")
    end
  end

  json_api do
    type("agent_worker")
    derive_filter?(false)
    derive_sort?(false)

    # The primary key names the record in the result of a generic action.
    default_fields([:agent_uid | @console_fields])
  end

  attributes do
    attribute(:agent_uid, Ankole.Ash.Types.PrincipalKey,
      primary_key?: true,
      allow_nil?: false,
      public?: true
    )

    attribute(:provider_id, :string, constraints: [trim?: false], public?: true)

    for field <- [
          :generation,
          :instance_ref,
          :image,
          :settings_digest,
          :incarnation_id,
          :transport_route,
          :drain_reason
        ] do
      attribute(field, :string, constraints: [trim?: false], public?: field in @console_fields)
    end

    for field <- [:create_sent_at, :instance_seen_at, :wanted_until, :last_worker_heartbeat_at] do
      attribute(field, :utc_datetime_usec, public?: field in @console_fields)
    end

    attribute(:state_changed_at, :utc_datetime_usec,
      allow_nil?: false,
      generated?: true,
      public?: true
    )

    attribute(:storage_ref, Ankole.Ash.Types.JSONMap)
    attribute(:token_digest, :binary, sensitive?: true)
    attribute(:token_ciphertext, :binary, sensitive?: true)
    attribute(:protocol_version, :integer)

    for field <- [:instance_settings, :capacity, :load] do
      attribute(field, Ankole.Ash.Types.JSONMap,
        allow_nil?: false,
        default: %{},
        public?: field in @console_fields
      )
    end

    attribute(:initial_start_pending, :boolean, allow_nil?: false, default: false)
    attribute(:last_error, :string, constraints: [trim?: false, max_length: 4000], public?: true)
    attribute(:last_error_kind, :string, constraints: [trim?: false])
  end

  identities do
    identity(:transport_route, [:transport_route],
      all_tenants?: true,
      where: expr(not is_nil(transport_route))
    )
  end

  state_machine do
    state_attribute(:state)
    initial_states([:absent])
    default_initial_state(:absent)

    transitions do
      transition(:begin_generation, from: :absent, to: :starting)
      transition(:resume, from: [:paused, :starting], to: :starting)
      transition(:pause, from: :draining, to: :paused)
      transition(:drain, from: [:starting, :ready, :stale, :paused, :draining], to: :draining)
      transition(:admit, from: [:starting, :stale, :ready], to: :ready)
      transition(:disconnect, from: :ready, to: :stale)
      transition(:disconnect, from: :draining, to: :draining)

      transition(:settle,
        from: [:absent, :starting, :ready, :stale, :paused, :draining],
        to: :absent
      )

      transition(:settle, from: :deleting, to: :deleting)
      transition(:mark_deleting, from: @states, to: :deleting)
    end
  end

  actions do
    defaults([:read])

    create :register do
      accept([:agent_uid, :provider_id])
      validate(present(:provider_id))
      change(set_attribute(:initial_start_pending, true))
    end

    update :reserve_slot do
      require_atomic?(true)
      accept([])

      change(
        filter(
          expr(
            state == :ready and
              fragment("coalesce((?->>'available_slots')::bigint, 0) > 0", capacity)
          )
        )
      )

      change(
        atomic_update(
          :capacity,
          expr(
            fragment(
              "jsonb_set(?, '{available_slots}', to_jsonb((?->>'available_slots')::bigint - 1))",
              capacity,
              capacity
            )
          )
        )
      )

      change(
        atomic_update(
          :load,
          expr(
            fragment(
              "jsonb_set(?, '{active_slots}', to_jsonb(coalesce((?->>'active_slots')::bigint, 0) + 1))",
              load,
              load
            )
          )
        )
      )
    end

    update :request do
      require_atomic?(true)
      accept([])
      change(filter(expr(state != :deleting)))

      change(
        atomic_update(
          :wanted_until,
          expr(
            fragment("greatest(coalesce(?, now()), now() + interval '300 seconds')", wanted_until)
          )
        )
      )
    end

    update :begin_generation do
      require_atomic?(true)

      accept([
        :generation,
        :create_sent_at,
        :token_digest,
        :token_ciphertext,
        :image,
        :protocol_version,
        :settings_digest,
        :instance_settings,
        :last_error,
        :last_error_kind
      ])

      validate(
        present([
          :generation,
          :token_digest,
          :token_ciphertext,
          :image,
          :protocol_version,
          :settings_digest
        ])
      )

      change(transition_state(:starting))
      change({Ankole.AgentWorkers.Changes.StateClock, target: :starting})
    end

    update :resume do
      require_atomic?(true)
      accept([])
      change(transition_state(:starting))
      change({Ankole.AgentWorkers.Changes.StateClock, target: :starting})
    end

    update :pause do
      require_atomic?(true)
      accept([])
      change(transition_state(:paused))
      change(set_attribute(:drain_reason, nil))
      change(set_attribute(:transport_route, nil))
      change({Ankole.AgentWorkers.Changes.StateClock, target: :paused})
    end

    update :drain do
      require_atomic?(true)
      accept([:drain_reason])
      change(transition_state(:draining))

      change(
        atomic_update(
          :capacity,
          expr(fragment("jsonb_set(?, '{available_slots}', '0'::jsonb)", capacity))
        )
      )

      change({Ankole.AgentWorkers.Changes.StateClock, target: :draining})
    end

    # The caller locks the row and checks its generation and protocol. The
    # update applies only while no other incarnation has a fresh heartbeat.
    update :admit do
      require_atomic?(true)
      accept([:transport_route, :capacity])
      argument(:incarnation, :string, allow_nil?: false, constraints: [trim?: false])
      validate(present(:transport_route))

      change(
        filter(
          expr(
            is_nil(incarnation_id) or incarnation_id == ^arg(:incarnation) or
              is_nil(transport_route) or is_nil(last_worker_heartbeat_at) or
              last_worker_heartbeat_at <= fragment("clock_timestamp() - interval '60 seconds'")
          )
        )
      )

      change(set_attribute(:incarnation_id, arg(:incarnation)))
      change(transition_state(:ready))
      change(set_attribute(:initial_start_pending, false))
      change(set_attribute(:last_error, nil))
      change(set_attribute(:last_error_kind, nil))
      change(atomic_update(:last_worker_heartbeat_at, expr(fragment("now()"))))

      change(
        atomic_update(:instance_seen_at, expr(fragment("coalesce(?, now())", instance_seen_at)))
      )

      change({Ankole.AgentWorkers.Changes.StateClock, target: :ready})
    end

    update :heartbeat do
      require_atomic?(true)
      accept([:capacity, :load])
      argument(:route, :string, allow_nil?: false, constraints: [trim?: false])
      argument(:incarnation, :string, allow_nil?: false, constraints: [trim?: false])

      change(
        filter(
          expr(
            state in [:ready, :draining] and transport_route == ^arg(:route) and
              incarnation_id == ^arg(:incarnation)
          )
        )
      )

      change(atomic_update(:last_worker_heartbeat_at, expr(fragment("now()"))))
    end

    update :disconnect do
      accept([])
      change(next_state())
      change(set_attribute(:transport_route, nil))

      change(
        {Ankole.AgentWorkers.Changes.StateClock,
         target: expr(if state == :draining, do: :draining, else: :stale)},
        only_when_valid?: true
      )
    end

    update :settle do
      accept([:storage_ref, :last_error, :last_error_kind])
      change(next_state())

      for field <- @generation_fields -- [:instance_settings, :capacity, :load] do
        change(set_attribute(field, nil))
      end

      for field <- [:instance_settings, :capacity, :load] do
        change(set_attribute(field, %{}))
      end

      change(
        {Ankole.AgentWorkers.Changes.StateClock,
         target: expr(if state == :deleting, do: :deleting, else: :absent)},
        only_when_valid?: true
      )
    end

    update :mark_deleting do
      require_atomic?(true)
      accept([])
      change(transition_state(:deleting))
      change(set_attribute(:incarnation_id, nil))
      change(set_attribute(:transport_route, nil))
      change(set_attribute(:initial_start_pending, false))
      change(set_attribute(:wanted_until, nil))
      change(atomic_update(:state_changed_at, expr(fragment("now()"))))
    end

    update :observe do
      accept([
        :instance_ref,
        :instance_seen_at,
        :create_sent_at,
        :storage_ref,
        :last_error,
        :last_error_kind
      ])
    end

    update :record_error do
      require_atomic?(true)
      accept([:last_error, :last_error_kind])
    end

    update :clear_rejection do
      require_atomic?(true)
      accept([])
      change(filter(expr(last_error_kind == "rejected")))
      change(set_attribute(:last_error, nil))
      change(set_attribute(:last_error_kind, nil))
    end

    update :assign_provider do
      accept([:provider_id])
      validate(present(:provider_id))

      change(fn changeset, _ ->
        cond do
          not is_nil(changeset.data.provider_id) ->
            Ash.Changeset.add_error(
              changeset,
              Ankole.Errors.Invalid.Rejected.exception(reason: :worker_provider_immutable)
            )

          changeset.data.state == :deleting ->
            Ash.Changeset.add_error(
              changeset,
              Ankole.Errors.Invalid.Rejected.exception(reason: :agent_uid_pending_deletion)
            )

          true ->
            changeset
            |> Ash.Changeset.force_change_attribute(:last_error, nil)
            |> Ash.Changeset.force_change_attribute(:last_error_kind, nil)
        end
      end)
    end

    destroy :remove do
      validate(attribute_equals(:state, :deleting))
    end

    read :across_tenants do
      multitenancy(:allow_global)
    end

    read :console_list do
      prepare(build(sort: [agent_uid: :asc]))
    end

    # The Console assignment keeps the v1 answers: a missing Agent or provider
    # is not found, and an Agent that has a provider or is being deleted is a
    # conflict.
    action :console_assign_provider, :struct do
      constraints(instance_of: __MODULE__)
      argument(:agent_uid, :string, allow_nil?: false, constraints: [trim?: false])
      argument(:provider_id, :string, allow_nil?: false, constraints: [trim?: false])
      after_commit({ReconcileJob, :enqueue})

      run(__MODULE__.Actions)
    end
  end

  @type t :: %__MODULE__{}

  @doc "Whether the current connection can carry accepted Turn traffic."
  def connected?(%{__struct__: __MODULE__, state: state, transport_route: route}),
    do: state in [:ready, :draining] and is_binary(route)

  @doc "The number of reported free Turn slots."
  def available_slots(%{__struct__: __MODULE__, capacity: %{"available_slots" => slots}})
      when is_integer(slots) and slots > 0, do: slots

  def available_slots(%{__struct__: __MODULE__}), do: 0

  @doc "Keeps a bounded diagnostic and its acquisition category together."
  def error_fields(nil, _kind), do: [last_error: nil, last_error_kind: nil]

  def error_fields(text, kind) when is_binary(text) and kind in ~w(rejected transient pending),
    do: [last_error: String.slice(text, -4000, 4000), last_error_kind: kind]
end
