defmodule Ankole.Repo.Migrations.CreateAgentWorkers do
  use Ecto.Migration

  # Provider assignment and storage outlive a Worker generation. There is no
  # Principal foreign key: Agent deletion keeps this row until cleanup ends.
  def up do
    create table(:worker_providers, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :provider_id, :text, null: false
      add :kind, :text, null: false
      add :display_name, :text, null: false
      add :config, :text, null: false
      add :credentials, :map, null: false, default: %{}
      add :is_default, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:worker_providers, [:provider_id])

    create unique_index(:worker_providers, [:is_default],
             where: "is_default",
             name: :worker_providers_one_default
           )

    create constraint(:worker_providers, :worker_providers_id_format,
             check: "provider_id ~ '^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$'"
           )

    create constraint(:worker_providers, :worker_providers_credentials_object,
             check: "jsonb_typeof(credentials) = 'object'"
           )

    execute """
    CREATE TABLE agent_workers (
      agent_uid text PRIMARY KEY,
      provider_id text REFERENCES worker_providers(provider_id) ON DELETE RESTRICT,
      state text NOT NULL DEFAULT 'absent',
      generation text,
      instance_ref text,
      storage_ref jsonb,
      token_digest bytea,
      token_ciphertext bytea,
      instance_seen_at timestamptz,
      image text,
      protocol_version integer,
      settings_digest text,
      instance_settings jsonb NOT NULL DEFAULT '{}'::jsonb,
      wanted_until timestamptz,
      last_error text,
      state_changed_at timestamptz NOT NULL DEFAULT now(),
      incarnation_id text,
      transport_route text,
      capacity jsonb NOT NULL DEFAULT '{}'::jsonb,
      load jsonb NOT NULL DEFAULT '{}'::jsonb,
      last_worker_heartbeat_at timestamptz,
      drain_reason text,
      CONSTRAINT agent_workers_state_check CHECK
        (state IN ('absent', 'starting', 'ready', 'stale', 'paused', 'draining', 'deleting')),
      CONSTRAINT agent_workers_generation_state CHECK
        ((state = 'absent' AND generation IS NULL) OR state = 'deleting' OR
          (state NOT IN ('absent', 'deleting') AND generation IS NOT NULL)),
      CONSTRAINT agent_workers_token_with_generation CHECK
        ((token_digest IS NULL) = (generation IS NULL)),
      CONSTRAINT agent_workers_ciphertext_with_generation CHECK
        ((token_ciphertext IS NULL) = (generation IS NULL)),
      CONSTRAINT agent_workers_seen_with_generation CHECK
        (instance_seen_at IS NULL OR generation IS NOT NULL),
      CONSTRAINT agent_workers_target_with_generation CHECK
        (generation IS NULL OR
          (image IS NOT NULL AND protocol_version IS NOT NULL AND settings_digest IS NOT NULL)),
      CONSTRAINT agent_workers_provider_with_generation CHECK
        (generation IS NULL OR provider_id IS NOT NULL),
      CONSTRAINT agent_workers_storage_ref_object CHECK
        (storage_ref IS NULL OR jsonb_typeof(storage_ref) = 'object'),
      CONSTRAINT agent_workers_instance_settings_object CHECK
        (jsonb_typeof(instance_settings) = 'object'),
      CONSTRAINT agent_workers_route_state CHECK
        (transport_route IS NULL OR state IN ('ready', 'draining')),
      CONSTRAINT agent_workers_ready_connection CHECK
        (state <> 'ready' OR (transport_route IS NOT NULL AND incarnation_id IS NOT NULL)),
      CONSTRAINT agent_workers_capacity_object CHECK (jsonb_typeof(capacity) = 'object'),
      CONSTRAINT agent_workers_load_object CHECK (jsonb_typeof(load) = 'object')
    )
    """

    create unique_index(:agent_workers, [:transport_route],
             where: "transport_route IS NOT NULL",
             name: :agent_workers_transport_route_index
           )

    create index(:agent_workers, [:state, :state_changed_at])
    create index(:agent_workers, [:provider_id])

    execute "COMMENT ON TABLE agent_workers IS 'The one Worker of each Agent: control-plane decisions and connection facts.'"

    for {column, comment} <- [
          state: "Worker lifecycle state.",
          provider_id: "The provider selected once for this Agent.",
          generation: "Random id of the current Worker; a new Worker gets a new generation.",
          instance_ref:
            "Platform instance identifier, when it cannot be derived from generation.",
          storage_ref: "Committed platform storage reference or storage cleanup progress.",
          token_digest: "SHA-256 of the credential of the current generation.",
          token_ciphertext: "Encrypted credential for retries of the current generation.",
          instance_seen_at: "First platform observation or admission of this generation.",
          image: "Worker image of the current generation.",
          protocol_version:
            "RuntimeFabric protocol version of the control plane that created the Worker.",
          settings_digest: "Digest of the provider instance settings that created the Worker.",
          instance_settings: "Instance settings selected when the generation was recorded.",
          wanted_until: "A path needs a running Worker until this time.",
          last_error: "Latest wait or failure reason from the backend.",
          state_changed_at: "Time the row entered its current state.",
          incarnation_id: "Process that joined last.",
          transport_route: "Current connection of the Worker.",
          capacity: "Turn slots that the Worker reported.",
          load: "Load that the Worker reported, including active tasks and idle time.",
          last_worker_heartbeat_at: "Latest heartbeat, in database time.",
          drain_reason: "Why the Worker is draining."
        ] do
      execute "COMMENT ON COLUMN agent_workers.#{column} IS '#{comment}'"
    end

    execute "INSERT INTO agent_workers (agent_uid) SELECT uid FROM principals WHERE type = 'agent'"

    # Old Worker thread files were transient. Only these Jobs can replay the
    # stored transcript until they establish a native thread on persistent storage.
    execute """
    UPDATE background_agent_jobs
    SET metadata = COALESCE(metadata, '{}'::jsonb) || '{"legacy_thread_replay":true}'::jsonb
    WHERE runtime_thread_id IS NOT NULL AND runtime_thread_id <> ''
    """

    drop table(:agent_computer_workers)
    drop table(:actor_session_worker_assignments)

    # One Worker per Agent: the per-Agent Job cap already bounds its Job Turns.
    execute """
    DELETE FROM app_configurations
    WHERE key = 'agent_computer.background_agent_job.max_turns_per_worker'
    """
  end

  def down do
    raise Ecto.MigrationError, message: "Agent Workers replaced the pooled Worker registry"
  end
end
