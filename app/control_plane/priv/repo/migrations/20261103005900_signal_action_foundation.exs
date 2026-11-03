defmodule Ankole.Repo.Migrations.SignalActionFoundation do
  use Ecto.Migration

  def up do
    # The Page identity rename may be pending in the same deployment. Attach
    # ownership to that identity table so its foreign keys follow the rename.
    old_pages? = repo().query!("SELECT to_regclass('drive_nodes')").rows != [[nil]]
    pages = if old_pages?, do: "drive_nodes", else: "pages"
    kind = if old_pages?, do: "kind", else: "type"

    sql = """
    ALTER TABLE #{pages} ADD COLUMN owner_uid text;
    UPDATE #{pages} p SET owner_uid = pr.uid FROM principals pr
    WHERE p.#{kind} = 'applet' AND pr.tenant_id = p.tenant_id
      AND pr.uid = substring(p.created_by FROM '^ankole:[^:]+:principal/(.+)$');
    ALTER TABLE #{pages} ADD CONSTRAINT pages_owner_fkey
      FOREIGN KEY (tenant_id, owner_uid) REFERENCES principals(tenant_id, uid) ON DELETE RESTRICT ON UPDATE CASCADE;

    ALTER TABLE automation_jobs
      ALTER COLUMN agent_uid DROP NOT NULL,
      ALTER COLUMN owner_session_id DROP NOT NULL,
      ALTER COLUMN drive_prefix DROP NOT NULL,
      ADD COLUMN executor_kind text NOT NULL DEFAULT 'agent_script',
      ADD COLUMN page_id uuid,
      ADD COLUMN action_key text,
      ADD COLUMN config jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(config) = 'object'),
      ADD COLUMN idempotent boolean NOT NULL DEFAULT false,
      ADD COLUMN concurrency_mode text NOT NULL DEFAULT 'parallel'
        CHECK (concurrency_mode IN ('parallel', 'serial_fifo', 'serial_coalesce')),
      ADD COLUMN max_slices integer NOT NULL DEFAULT 1000 CHECK (max_slices BETWEEN 1 AND 100000),
      ADD COLUMN unavailable_reason text,
      ADD CONSTRAINT automation_jobs_page_fkey FOREIGN KEY (tenant_id, page_id)
        REFERENCES #{pages}(tenant_id, id) ON DELETE RESTRICT,
      ADD CONSTRAINT automation_jobs_executor_mode_check CHECK (
        (executor_kind = 'applet_function' AND page_id IS NOT NULL
          AND action_key IS NOT NULL AND length(btrim(action_key)) > 0
          AND agent_uid IS NULL AND owner_session_id IS NULL AND drive_prefix IS NULL
          AND wake_on_failure = false) OR
        (executor_kind = 'agent_script' AND page_id IS NULL AND action_key IS NULL
          AND agent_uid IS NOT NULL AND owner_session_id IS NOT NULL AND drive_prefix IS NOT NULL)
      );
    CREATE INDEX automation_jobs_page_action_idx ON automation_jobs(tenant_id, page_id, action_key)
      WHERE page_id IS NOT NULL;

    ALTER TABLE automation_job_runs
      ADD COLUMN signal_id text,
      ADD COLUMN causation_id text,
      ADD COLUMN correlation_id text,
      ADD COLUMN binding_id uuid,
      ADD COLUMN concurrency_key text NOT NULL DEFAULT 'default',
      ADD COLUMN coalesce_key text,
      ADD COLUMN slice_count integer NOT NULL DEFAULT 0 CHECK (slice_count >= 0),
      ADD COLUMN attempts_in_slice integer NOT NULL DEFAULT 0 CHECK (attempts_in_slice >= 0),
      ADD COLUMN attempt_idempotent boolean NOT NULL DEFAULT false,
      ADD COLUMN attempt_deadline_at timestamptz,
      ADD COLUMN progress jsonb NOT NULL DEFAULT '{}'
        CHECK (jsonb_typeof(progress) = 'object' AND octet_length(progress::text) <= 16384),
      ADD COLUMN last_published_revision bigint,
      ADD COLUMN result jsonb;
    UPDATE automation_job_runs SET attempts_in_slice = attempts,
      attempt_deadline_at = started_at + interval '610 seconds' WHERE attempts > 0;
    CREATE UNIQUE INDEX automation_job_runs_coalesce_pending_uniq_idx
      ON automation_job_runs(tenant_id, automation_job_id, coalesce_key)
      WHERE status = 'queued' AND attempts = 0 AND slice_count = 0 AND coalesce_key IS NOT NULL;
    CREATE INDEX automation_job_runs_serial_queue_idx
      ON automation_job_runs(tenant_id, automation_job_id, concurrency_key, id)
      WHERE status IN ('queued', 'running');

    CREATE TABLE automation_job_states (
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      automation_job_id bigint NOT NULL,
      scope_key text NOT NULL DEFAULT 'default' CHECK (char_length(scope_key) BETWEEN 1 AND 255),
      state_key text NOT NULL CHECK (char_length(state_key) BETWEEN 1 AND 255),
      value jsonb CHECK (octet_length(value::text) <= 65536),
      updated_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (tenant_id, automation_job_id, scope_key, state_key),
      FOREIGN KEY (tenant_id, automation_job_id) REFERENCES automation_jobs(tenant_id, id) ON DELETE CASCADE
    );

    ALTER TABLE signal_bindings
      DROP CONSTRAINT signal_bindings_routing_target,
      ADD COLUMN automation_job_id bigint,
      ADD COLUMN watched_field_ids text[],
      ADD CONSTRAINT signal_bindings_job_fkey FOREIGN KEY (tenant_id, automation_job_id)
        REFERENCES automation_jobs(tenant_id, id) ON DELETE CASCADE,
      ADD CONSTRAINT signal_bindings_routing_target CHECK (
        (routing_mode = 'ai_colleague' AND agent_uid IS NOT NULL AND automation_job_id IS NULL) OR
        (routing_mode = 'sender_personal_assistant' AND agent_uid IS NULL AND automation_job_id IS NULL
          AND adapter IN ('lark', 'slack') AND unmatched_sender_policy = 'manual_review') OR
        (routing_mode = 'action' AND automation_job_id IS NOT NULL AND agent_uid IS NULL)
      );
    CREATE TABLE signal_binding_receipts (
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      binding_id uuid NOT NULL,
      source text NOT NULL,
      source_event_id text NOT NULL,
      signal_id text NOT NULL,
      automation_job_run_id bigint,
      delivered_signal_id text,
      received_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (tenant_id, binding_id, source, source_event_id),
      FOREIGN KEY (tenant_id, binding_id) REFERENCES signal_bindings(tenant_id, id) ON DELETE CASCADE
    );
    CREATE INDEX signal_binding_receipts_signal_idx ON signal_binding_receipts(tenant_id, signal_id);
    CREATE INDEX signal_binding_receipts_received_idx ON signal_binding_receipts(received_at);

    ALTER TABLE base_tables
      ADD COLUMN emit_changes boolean NOT NULL DEFAULT false,
      ADD COLUMN unique_field_ids uuid[] NOT NULL DEFAULT '{}';
    CREATE TABLE base_change_outbox (
      id uuid PRIMARY KEY,
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      page_id uuid NOT NULL,
      table_id uuid NOT NULL,
      data_version bigint NOT NULL,
      actor_ref text NOT NULL,
      changes jsonb NOT NULL CHECK (jsonb_typeof(changes) = 'array'),
      inserted_at timestamptz NOT NULL DEFAULT now()
    );
    CREATE INDEX base_change_outbox_drain_idx ON base_change_outbox(inserted_at, id);
    """

    sql |> String.split(";", trim: true) |> Enum.each(&execute/1)
  end

  def down, do: raise("Signal/Action state requires a forward migration")
end
