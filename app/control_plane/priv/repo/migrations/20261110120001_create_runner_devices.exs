defmodule Ankole.Repo.Migrations.CreateRunnerDevices do
  use Ecto.Migration

  def change do
    create table(:runner_devices, primary_key: false) do
      add :tenant_id, references(:tenants, type: :uuid, on_delete: :restrict), primary_key: true
      add :id, :uuid, primary_key: true
      add :owner_uid, :text, null: false
      add :owner_access_version, :integer, null: false
      add :name, :text, null: false
      add :pairing_digest, :binary
      add :pairing_expires_at, :utc_datetime_usec
      add :token_digest, :binary
      add :revoked_at, :utc_datetime_usec
    end

    execute(
      """
      ALTER TABLE runner_devices ADD CONSTRAINT runner_devices_owner_fkey
        FOREIGN KEY (tenant_id, owner_uid) REFERENCES principals (tenant_id, uid)
        ON DELETE CASCADE ON UPDATE CASCADE
      """,
      "ALTER TABLE runner_devices DROP CONSTRAINT runner_devices_owner_fkey"
    )

    create index(:runner_devices, [:tenant_id, :owner_uid])
    create unique_index(:runner_devices, [:pairing_digest], where: "pairing_digest IS NOT NULL")
    create unique_index(:runner_devices, [:token_digest], where: "token_digest IS NOT NULL")

    create constraint(:runner_devices, :runner_devices_pairing_fields,
             check: "(pairing_digest IS NULL) = (pairing_expires_at IS NULL)"
           )

    create table(:runner_bindings, primary_key: false) do
      add :tenant_id, :uuid, primary_key: true
      add :runner_id, :uuid, primary_key: true
      add :agent_uid, :text, primary_key: true
      add :generation, :text, null: false
      add :token_digest, :binary, null: false
      add :token_ciphertext, :binary, null: false
      add :state, :text, null: false, default: "starting"
      add :protocol_version, :integer, null: false
      add :image, :text, null: false
      add :instance_settings, :map, null: false
      add :transport_route, :text
      add :incarnation_id, :text
      add :last_worker_heartbeat_at, :utc_datetime_usec
      add :capacity, :map, null: false, default: %{}
      add :load, :map, null: false, default: %{}
    end

    create unique_index(:runner_bindings, [:token_digest])

    create unique_index(:runner_bindings, [:transport_route],
             where: "transport_route IS NOT NULL"
           )

    create index(:runner_bindings, [:tenant_id, :agent_uid])

    create constraint(:runner_bindings, :runner_bindings_state,
             check: "state IN ('starting', 'ready', 'stale', 'draining')"
           )

    execute(
      """
      ALTER TABLE runner_bindings
        ADD CONSTRAINT runner_bindings_device_fkey FOREIGN KEY (tenant_id, runner_id)
          REFERENCES runner_devices (tenant_id, id) ON DELETE CASCADE,
        ADD CONSTRAINT runner_bindings_agent_fkey FOREIGN KEY (tenant_id, agent_uid)
          REFERENCES agents (tenant_id, uid) ON DELETE CASCADE ON UPDATE CASCADE;
      """,
      """
      ALTER TABLE runner_bindings
        DROP CONSTRAINT runner_bindings_agent_fkey,
        DROP CONSTRAINT runner_bindings_device_fkey;
      """
    )
  end
end
