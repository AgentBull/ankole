defmodule Ankole.AgentWorkers.AgentWorker do
  @moduledoc "The durable lifecycle, launch identity, and current connection of one Agent's Worker."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.AgentWorkers.Domain,
    extensions: [AshStateMachine]

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

  attributes do
    attribute(:agent_uid, Ankole.Ash.Types.PrincipalKey, primary_key?: true, allow_nil?: false)
    attribute(:provider_id, :string, constraints: [trim?: false])

    for field <- [
          :generation,
          :instance_ref,
          :image,
          :settings_digest,
          :incarnation_id,
          :transport_route,
          :drain_reason
        ] do
      attribute(field, :string, constraints: [trim?: false])
    end

    for field <- [:create_sent_at, :instance_seen_at, :wanted_until, :last_worker_heartbeat_at] do
      attribute(field, :utc_datetime_usec)
    end

    attribute(:state_changed_at, :utc_datetime_usec, allow_nil?: false, generated?: true)
    attribute(:storage_ref, Ankole.Ash.Types.JSONMap)
    attribute(:token_digest, :binary, sensitive?: true)
    attribute(:token_ciphertext, :binary, sensitive?: true)
    attribute(:protocol_version, :integer)

    for field <- [:instance_settings, :capacity, :load] do
      attribute(field, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    end

    attribute(:initial_start_pending, :boolean, allow_nil?: false, default: false)
    attribute(:last_error, :string, constraints: [trim?: false, max_length: 4000])
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
      transaction?(false)
      accept([:agent_uid, :provider_id])
      change(Ankole.Ash.RequireTransaction)
      validate(present(:provider_id))
      change(set_attribute(:initial_start_pending, true))
    end

    atomic_in_tx_update :reserve_slot do
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
      transaction?(false)
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

    atomic_in_tx_update :begin_generation do
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

    atomic_in_tx_update :resume do
      accept([])
      change(transition_state(:starting))
      change({Ankole.AgentWorkers.Changes.StateClock, target: :starting})
    end

    atomic_in_tx_update :pause do
      accept([])
      change(transition_state(:paused))
      change(set_attribute(:drain_reason, nil))
      change(set_attribute(:transport_route, nil))
      change({Ankole.AgentWorkers.Changes.StateClock, target: :paused})
    end

    atomic_in_tx_update :drain do
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

    in_tx_update :admit do
      accept([:incarnation_id, :transport_route, :capacity])
      argument(:generation, :string, allow_nil?: false, constraints: [trim?: false])
      validate(present([:incarnation_id, :transport_route]))
      change(Ankole.AgentWorkers.Changes.AdmitConnection)
      change(transition_state(:ready), only_when_valid?: true)
      change(set_attribute(:initial_start_pending, false))
      change(set_attribute(:last_error, nil))
      change(set_attribute(:last_error_kind, nil))
      change(atomic_update(:last_worker_heartbeat_at, expr(fragment("now()"))))

      change(
        atomic_update(:instance_seen_at, expr(fragment("coalesce(?, now())", instance_seen_at)))
      )

      change({Ankole.AgentWorkers.Changes.StateClock, target: :ready})
    end

    atomic_in_tx_update :heartbeat do
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

    in_tx_update :disconnect do
      accept([])
      change(next_state())
      change(set_attribute(:transport_route, nil))

      change(
        {Ankole.AgentWorkers.Changes.StateClock,
         target: expr(if state == :draining, do: :draining, else: :stale)},
        only_when_valid?: true
      )
    end

    in_tx_update :settle do
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

    atomic_in_tx_update :mark_deleting do
      accept([])
      change(transition_state(:deleting))
      change(set_attribute(:incarnation_id, nil))
      change(set_attribute(:transport_route, nil))
      change(set_attribute(:initial_start_pending, false))
      change(set_attribute(:wanted_until, nil))
      change(atomic_update(:state_changed_at, expr(fragment("now()"))))
    end

    in_tx_update :observe do
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
      transaction?(false)
      require_atomic?(true)
      accept([:last_error, :last_error_kind])
    end

    atomic_in_tx_update :clear_rejection do
      accept([])
      change(filter(expr(last_error_kind == "rejected")))
      change(set_attribute(:last_error, nil))
      change(set_attribute(:last_error_kind, nil))
    end

    in_tx_update :assign_provider do
      accept([:provider_id])
      validate(present(:provider_id))

      change(fn changeset, _ ->
        cond do
          not is_nil(changeset.data.provider_id) ->
            Ash.Changeset.add_error(
              changeset,
              Ankole.Ash.DomainError.exception(reason: :worker_provider_immutable)
            )

          changeset.data.state == :deleting ->
            Ash.Changeset.add_error(
              changeset,
              Ankole.Ash.DomainError.exception(reason: :agent_uid_pending_deletion)
            )

          true ->
            changeset
            |> Ash.Changeset.force_change_attribute(:last_error, nil)
            |> Ash.Changeset.force_change_attribute(:last_error_kind, nil)
        end
      end)
    end

    destroy :remove do
      transaction?(false)
      require_atomic?(false)
      atomic_upgrade?(false)
      change(Ankole.Ash.RequireTransaction)
      validate(attribute_equals(:state, :deleting))
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
