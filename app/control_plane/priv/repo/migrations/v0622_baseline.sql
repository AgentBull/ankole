-- Generated from the schema of a fresh v0.62.2 database.
-- Keep this frozen baseline self-contained; later changes belong in later migrations.
SET LOCAL check_function_bodies = false;

CREATE SCHEMA paradedb;

CREATE EXTENSION IF NOT EXISTS pg_search WITH SCHEMA paradedb;

COMMENT ON EXTENSION pg_search IS 'pg_search: Full text search for PostgreSQL using BM25';

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;

COMMENT ON EXTENSION vector IS 'vector data type and ivfflat and hnsw access methods';

CREATE TYPE public.agent_type AS ENUM (
    'ai_colleague'
);

CREATE TYPE public.brain_author_kind AS ENUM (
    'human',
    'agent',
    'dreaming'
);

CREATE TYPE public.brain_cursor_scope_kind AS ENUM (
    'channel',
    'principal'
);

CREATE TYPE public.brain_embedding_state AS ENUM (
    'pending',
    'synced',
    'failed'
);

CREATE TYPE public.oban_job_state AS ENUM (
    'available',
    'suspended',
    'scheduled',
    'executing',
    'retryable',
    'completed',
    'discarded',
    'cancelled'
);

CREATE TYPE public.principal_external_identity_kind AS ENUM (
    'platform_subject',
    'channel_actor',
    'login_subject',
    'outbound_actor'
);

CREATE TYPE public.principal_group_domain AS ENUM (
    'operator',
    'directory',
    'im_group'
);

CREATE TYPE public.principal_group_external_kind AS ENUM (
    'directory_department',
    'im_group'
);

CREATE TYPE public.principal_group_kind AS ENUM (
    'static',
    'computed'
);

CREATE TYPE public.principal_status AS ENUM (
    'active',
    'disabled'
);

CREATE TYPE public.principal_type AS ENUM (
    'human',
    'agent',
    'system'
);

CREATE TYPE public.signal_channel_kind AS ENUM (
    'im_dm',
    'im_group',
    'webhook_endpoint',
    'issue',
    'alert_stream',
    'unknown'
);

CREATE TYPE public.signal_gateway_outbox_operation AS ENUM (
    'post',
    'reply',
    'edit',
    'delete',
    'reaction_add',
    'reaction_remove',
    'divider',
    'card'
);

CREATE TYPE public.signal_gateway_outbox_status AS ENUM (
    'created',
    'unsupported',
    'sending',
    'succeeded',
    'failed',
    'unknown_after_send'
);

CREATE TYPE public.signal_group_message_policy AS ENUM (
    'ignore',
    'record_only',
    'may_intervene'
);

CREATE TYPE public.signal_reply_mode AS ENUM (
    'none',
    'channel',
    'entry'
);

CREATE FUNCTION public.brain_validate_entry_relation_scope() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  source_owner text;
  source_store text;
  target_owner text;
  target_store text;
BEGIN
  SELECT owner_uid, store_key INTO source_owner, source_store
  FROM brain_entries WHERE id = NEW.source_entry_id;

  SELECT owner_uid, store_key INTO target_owner, target_store
  FROM brain_entries WHERE id = NEW.target_entry_id;

  IF source_owner IS NULL OR target_owner IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'foreign_key_violation',
      MESSAGE = 'long-term memory relation endpoint does not exist';
  END IF;

  IF NEW.owner_uid <> source_owner OR NEW.store_key <> source_store THEN
    RAISE EXCEPTION USING ERRCODE = 'check_violation',
      MESSAGE = 'long-term memory relation scope must match its source entry';
  END IF;

  IF source_store = 'shared' AND
     (source_owner <> 'brain-shared' OR target_owner <> 'brain-shared' OR target_store <> 'shared') THEN
    RAISE EXCEPTION USING ERRCODE = 'check_violation',
      MESSAGE = 'shared entries can reference only shared entries';
  END IF;

  IF source_store <> 'shared' AND NOT (
    (target_owner = source_owner AND target_store = source_store) OR
    (target_owner = 'brain-shared' AND target_store = 'shared')
  ) THEN
    RAISE EXCEPTION USING ERRCODE = 'check_violation',
      MESSAGE = 'private entries can reference only their own store or shared entries';
  END IF;

  RETURN NEW;
END;
$$;

CREATE FUNCTION public.guard_brain_retained_source_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.capture_method = 'file' OR
     NEW.id <> OLD.id OR NEW.document_id <> OLD.document_id OR
     NEW.owner_uid <> OLD.owner_uid OR NEW.store_key <> OLD.store_key OR
     NEW.capture_method <> OLD.capture_method OR NEW.connector_id <> OLD.connector_id OR
     NEW.origin_locator IS DISTINCT FROM OLD.origin_locator OR
     NEW.learning_agent_uid IS DISTINCT FROM OLD.learning_agent_uid OR
     NEW.captured_by_uid IS DISTINCT FROM OLD.captured_by_uid OR
     NEW.inserted_at <> OLD.inserted_at THEN
    RAISE EXCEPTION 'retained source identity and manual source bytes are immutable';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TABLE public.actor_cron_schedules (
    id uuid NOT NULL,
    status text NOT NULL,
    agent_uid text NOT NULL,
    session_id text NOT NULL,
    binding_name text NOT NULL,
    name text NOT NULL,
    schedule jsonb NOT NULL,
    timezone text NOT NULL,
    payload jsonb NOT NULL,
    delivery jsonb,
    next_fire_at timestamp without time zone,
    last_fire_at timestamp without time zone,
    idempotency_key text NOT NULL,
    created_by jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    automation_job_id bigint,
    CONSTRAINT actor_cron_schedules_created_by_object CHECK ((jsonb_typeof(created_by) = 'object'::text)),
    CONSTRAINT actor_cron_schedules_delivery_object CHECK (((delivery IS NULL) OR (jsonb_typeof(delivery) = 'object'::text))),
    CONSTRAINT actor_cron_schedules_idempotency_key_present CHECK ((length(btrim(idempotency_key)) > 0)),
    CONSTRAINT actor_cron_schedules_name_present CHECK ((length(btrim(name)) > 0)),
    CONSTRAINT actor_cron_schedules_payload_object CHECK ((jsonb_typeof(payload) = 'object'::text)),
    CONSTRAINT actor_cron_schedules_schedule_object CHECK ((jsonb_typeof(schedule) = 'object'::text)),
    CONSTRAINT actor_cron_schedules_status_check CHECK ((status = ANY (ARRAY['active'::text, 'paused'::text, 'deleted'::text, 'failed'::text, 'completed'::text]))),
    CONSTRAINT actor_cron_schedules_timezone_present CHECK ((length(btrim(timezone)) > 0))
);

COMMENT ON TABLE public.actor_cron_schedules IS 'Recurring actor schedule definitions owned by Ankole.';

CREATE UNLOGGED TABLE public.actor_event_deliveries (
    id uuid NOT NULL,
    actor_event_id uuid NOT NULL,
    agent_uid text NOT NULL,
    session_id text NOT NULL,
    queue_sequence bigint NOT NULL,
    attempt_no integer NOT NULL,
    actor_lane_message_id text NOT NULL,
    correlation_id text,
    activation_uid text NOT NULL,
    actor_epoch bigint NOT NULL,
    actor_event_id_fence uuid NOT NULL,
    revision integer NOT NULL,
    worker_id text,
    transport_route text,
    state text DEFAULT 'created'::text NOT NULL,
    send_outcome text,
    sent_at timestamp(6) without time zone,
    accepted_at timestamp(6) without time zone,
    failed_at timestamp(6) without time zone,
    superseded_at timestamp(6) without time zone,
    error jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT actor_event_deliveries_attempt_positive CHECK ((attempt_no > 0)),
    CONSTRAINT actor_event_deliveries_error_object CHECK ((jsonb_typeof(error) = 'object'::text)),
    CONSTRAINT actor_event_deliveries_send_outcome_check CHECK (((send_outcome IS NULL) OR (send_outcome = ANY (ARRAY['sent_or_queued'::text, 'unknown_route'::text, 'backpressure'::text, 'timeout'::text, 'socket_closed'::text])))),
    CONSTRAINT actor_event_deliveries_state_check CHECK ((state = ANY (ARRAY['created'::text, 'sent'::text, 'send_failed'::text, 'accepted'::text, 'superseded'::text])))
);

COMMENT ON TABLE public.actor_event_deliveries IS 'Volatile delivery attempts from actor events to workers.';

COMMENT ON COLUMN public.actor_event_deliveries.actor_event_id IS 'Actor event row being delivered.';

COMMENT ON COLUMN public.actor_event_deliveries.agent_uid IS 'Agent principal that owns the event.';

COMMENT ON COLUMN public.actor_event_deliveries.session_id IS 'Actor session queue for the delivery.';

COMMENT ON COLUMN public.actor_event_deliveries.queue_sequence IS 'Per-session event sequence copied from actor_events.';

COMMENT ON COLUMN public.actor_event_deliveries.attempt_no IS 'Delivery attempt number for this actor event.';

COMMENT ON COLUMN public.actor_event_deliveries.actor_lane_message_id IS 'Transport message id sent over the actor lane.';

COMMENT ON COLUMN public.actor_event_deliveries.correlation_id IS 'Optional transport correlation id.';

COMMENT ON COLUMN public.actor_event_deliveries.activation_uid IS 'Runtime activation targeted by the delivery.';

COMMENT ON COLUMN public.actor_event_deliveries.actor_epoch IS 'Actor epoch fence used by the targeted activation.';

COMMENT ON COLUMN public.actor_event_deliveries.actor_event_id_fence IS 'Actor event fence this delivery is bound to.';

COMMENT ON COLUMN public.actor_event_deliveries.revision IS 'Runtime revision fence used by the targeted activation.';

COMMENT ON COLUMN public.actor_event_deliveries.worker_id IS 'Worker selected for the delivery.';

COMMENT ON COLUMN public.actor_event_deliveries.transport_route IS 'Actor transport route used for the delivery.';

COMMENT ON COLUMN public.actor_event_deliveries.state IS 'Delivery state from creation through send, acceptance, or supersession.';

COMMENT ON COLUMN public.actor_event_deliveries.send_outcome IS 'Transport outcome when the send did not cleanly succeed.';

COMMENT ON COLUMN public.actor_event_deliveries.sent_at IS 'Time the actor lane send was attempted.';

COMMENT ON COLUMN public.actor_event_deliveries.accepted_at IS 'Time the worker accepted the event.';

COMMENT ON COLUMN public.actor_event_deliveries.failed_at IS 'Time the delivery failed before acceptance.';

COMMENT ON COLUMN public.actor_event_deliveries.superseded_at IS 'Time a newer delivery replaced this attempt.';

COMMENT ON COLUMN public.actor_event_deliveries.error IS 'Structured delivery error for diagnostics.';

CREATE TABLE public.actor_events (
    id uuid NOT NULL,
    agent_uid text NOT NULL,
    binding_name text NOT NULL,
    session_id text NOT NULL,
    source_event_id text NOT NULL,
    signal_channel_id text,
    provider_thread_id text,
    source_entry_id text,
    reply_preview_source_entry_id text,
    type text NOT NULL,
    available_at timestamp without time zone NOT NULL,
    queue_sequence bigint NOT NULL,
    input_state text DEFAULT 'open'::text NOT NULL,
    completed_at timestamp without time zone,
    sender_key text,
    payload jsonb NOT NULL,
    dead_letter_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    reply_preview_checkpoint jsonb,
    reply_preview_sequence_high_water bigint DEFAULT 0 NOT NULL,
    reply_preview_cleanup_at timestamp without time zone,
    final_response_id text,
    turn_outcome text,
    ambient_asked_source_entry_id text,
    CONSTRAINT actor_events_completion_anchor_check CHECK ((((final_response_id IS NULL) AND (turn_outcome IS NULL)) OR ((final_response_id IS NOT NULL) AND (final_response_id ~~ 'resp_%'::text) AND (turn_outcome IS NOT NULL) AND (completed_at IS NOT NULL)))),
    CONSTRAINT actor_events_input_state_check CHECK ((input_state = ANY (ARRAY['open'::text, 'dead_letter'::text]))),
    CONSTRAINT actor_events_payload_object CHECK ((jsonb_typeof(payload) = 'object'::text)),
    CONSTRAINT actor_events_reply_preview_checkpoint_object CHECK (((reply_preview_checkpoint IS NULL) OR (jsonb_typeof(reply_preview_checkpoint) = 'object'::text))),
    CONSTRAINT actor_events_reply_preview_sequence_non_negative CHECK ((reply_preview_sequence_high_water >= 0)),
    CONSTRAINT actor_events_turn_outcome_check CHECK (((turn_outcome IS NULL) OR (turn_outcome = ANY (ARRAY['loop_finished'::text, 'iteration_exhausted'::text]))))
);

COMMENT ON TABLE public.actor_events IS 'Durable actor-facing events waiting for one agent session.';

COMMENT ON COLUMN public.actor_events.agent_uid IS 'Agent principal that should process the event.';

COMMENT ON COLUMN public.actor_events.binding_name IS 'Ingress binding or internal source that produced the event.';

COMMENT ON COLUMN public.actor_events.session_id IS 'Actor session queue that owns ordering for this event.';

COMMENT ON COLUMN public.actor_events.source_event_id IS 'Idempotency key for the source event (layer-1 identity).';

COMMENT ON COLUMN public.actor_events.signal_channel_id IS 'Provider channel tied to this event when it came from SignalsGateway.';

COMMENT ON COLUMN public.actor_events.provider_thread_id IS 'Provider thread key used for batching and reply context.';

COMMENT ON COLUMN public.actor_events.source_entry_id IS 'Provider entry that produced this event when applicable (layer-2 identity).';

COMMENT ON COLUMN public.actor_events.reply_preview_source_entry_id IS 'Provider entry created for the live AI reply preview; SignalsGateway uses it as the final edit target.';

COMMENT ON COLUMN public.actor_events.type IS 'Actor event type such as command, signal entry, or session lifecycle.';

COMMENT ON COLUMN public.actor_events.available_at IS 'Earliest time this event may be delivered to the actor runtime.';

COMMENT ON COLUMN public.actor_events.queue_sequence IS 'Per-session sequence for ordering currently open actor events.';

COMMENT ON COLUMN public.actor_events.input_state IS 'Queue state for open or dead-lettered events.';

COMMENT ON COLUMN public.actor_events.completed_at IS 'Time this event finished normal processing.';

COMMENT ON COLUMN public.actor_events.sender_key IS 'Provider sender key used by same-sender batching policy.';

COMMENT ON COLUMN public.actor_events.payload IS 'CloudEvents-style actor event envelope consumed by the worker.';

COMMENT ON COLUMN public.actor_events.dead_letter_at IS 'Time this event was marked undeliverable.';

CREATE TABLE public.actor_scheduled_events (
    id bigint NOT NULL,
    kind text NOT NULL,
    status text NOT NULL,
    agent_uid text NOT NULL,
    session_id text NOT NULL,
    binding_name text NOT NULL,
    due_at timestamp without time zone NOT NULL,
    timezone text NOT NULL,
    requested_at timestamp without time zone NOT NULL,
    idempotency_key text NOT NULL,
    cron_schedule_id uuid,
    cron_fire_slot_at timestamp without time zone,
    tool_call_id text,
    source_actor_event_id uuid,
    signal_channel_id text,
    provider_thread_id text,
    source_entry_id text,
    source_provenance jsonb DEFAULT '{}'::jsonb NOT NULL,
    wake_payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    oban_job_id bigint,
    actor_event_id uuid,
    origin_ai_message_id uuid,
    fire_attempts integer DEFAULT 0 NOT NULL,
    fire_claimed_at timestamp without time zone,
    fired_at timestamp without time zone,
    cancelled_at timestamp without time zone,
    last_fire_error jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    automation_job_id bigint,
    automation_job_run_id bigint,
    CONSTRAINT actor_scheduled_events_id_range CHECK (((id >= 1000) AND (id <= '9007199254740991'::bigint))),
    CONSTRAINT actor_scheduled_events_idempotency_key_present CHECK ((length(btrim(idempotency_key)) > 0)),
    CONSTRAINT actor_scheduled_events_kind_check CHECK ((kind = ANY (ARRAY['check_back_later'::text, 'cron_fire'::text]))),
    CONSTRAINT actor_scheduled_events_last_fire_error_object CHECK ((jsonb_typeof(last_fire_error) = 'object'::text)),
    CONSTRAINT actor_scheduled_events_source_provenance_object CHECK ((jsonb_typeof(source_provenance) = 'object'::text)),
    CONSTRAINT actor_scheduled_events_status_check CHECK ((status = ANY (ARRAY['scheduled'::text, 'firing'::text, 'fired'::text, 'cancelled'::text, 'failed'::text]))),
    CONSTRAINT actor_scheduled_events_timezone_present CHECK ((length(btrim(timezone)) > 0)),
    CONSTRAINT actor_scheduled_events_wake_payload_object CHECK ((jsonb_typeof(wake_payload) = 'object'::text))
);

COMMENT ON TABLE public.actor_scheduled_events IS 'Concrete pending or terminal actor schedule fires.';

ALTER TABLE public.actor_scheduled_events ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.actor_scheduled_events_id_seq
    START WITH 1000
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE UNLOGGED TABLE public.actor_session_activations (
    id uuid NOT NULL,
    activation_uid text NOT NULL,
    agent_uid text NOT NULL,
    session_id text NOT NULL,
    actor_epoch bigint NOT NULL,
    status text NOT NULL,
    controller_node text,
    lease_id text NOT NULL,
    lease_expires_at timestamp(6) without time zone NOT NULL,
    last_actor_heartbeat_at timestamp(6) without time zone,
    assigned_worker_id text,
    current_actor_event_id uuid,
    revision integer DEFAULT 0 NOT NULL,
    started_at timestamp(6) without time zone NOT NULL,
    stopped_at timestamp(6) without time zone,
    stop_reason text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT actor_session_activations_metadata_object CHECK ((jsonb_typeof(metadata) = 'object'::text)),
    CONSTRAINT actor_session_activations_status_check CHECK ((status = ANY (ARRAY['starting'::text, 'active'::text, 'draining'::text, 'stopped'::text, 'failed'::text])))
);

COMMENT ON TABLE public.actor_session_activations IS 'Volatile activation leases for live actor sessions.';

COMMENT ON COLUMN public.actor_session_activations.activation_uid IS 'Stable activation identifier carried across worker messages.';

COMMENT ON COLUMN public.actor_session_activations.agent_uid IS 'Agent principal that owns the activation.';

COMMENT ON COLUMN public.actor_session_activations.session_id IS 'Actor session protected by the activation.';

COMMENT ON COLUMN public.actor_session_activations.actor_epoch IS 'Monotonic actor epoch fence for this session activation.';

COMMENT ON COLUMN public.actor_session_activations.status IS 'Activation lifecycle state.';

COMMENT ON COLUMN public.actor_session_activations.controller_node IS 'Control-plane node that owns the activation lease.';

COMMENT ON COLUMN public.actor_session_activations.lease_id IS 'Lease id proving current activation ownership.';

COMMENT ON COLUMN public.actor_session_activations.lease_expires_at IS 'Time the activation lease expires without renewal.';

COMMENT ON COLUMN public.actor_session_activations.last_actor_heartbeat_at IS 'Most recent actor heartbeat observed for the activation.';

COMMENT ON COLUMN public.actor_session_activations.assigned_worker_id IS 'Worker assigned to the activation.';

COMMENT ON COLUMN public.actor_session_activations.current_actor_event_id IS 'Actor event currently controlled by the activation.';

COMMENT ON COLUMN public.actor_session_activations.revision IS 'Revision fence advanced by activation state changes.';

COMMENT ON COLUMN public.actor_session_activations.started_at IS 'Time the activation started.';

COMMENT ON COLUMN public.actor_session_activations.stopped_at IS 'Time the activation stopped.';

COMMENT ON COLUMN public.actor_session_activations.stop_reason IS 'Operator-visible reason the activation stopped.';

COMMENT ON COLUMN public.actor_session_activations.metadata IS 'Activation metadata outside the runtime fencing contract.';

CREATE UNLOGGED TABLE public.actor_session_worker_assignments (
    id uuid NOT NULL,
    agent_uid text NOT NULL,
    session_id text NOT NULL,
    worker_id text NOT NULL,
    transport_route text,
    status text NOT NULL,
    assigned_at timestamp(6) without time zone NOT NULL,
    last_used_at timestamp(6) without time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT actor_session_worker_assignments_metadata_object CHECK ((jsonb_typeof(metadata) = 'object'::text)),
    CONSTRAINT actor_session_worker_assignments_status_check CHECK ((status = ANY (ARRAY['assigned'::text, 'draining'::text, 'released'::text])))
);

COMMENT ON TABLE public.actor_session_worker_assignments IS 'Volatile mapping from actor sessions to assigned workers.';

COMMENT ON COLUMN public.actor_session_worker_assignments.agent_uid IS 'Agent principal that owns the session.';

COMMENT ON COLUMN public.actor_session_worker_assignments.session_id IS 'Actor session assigned to the worker.';

COMMENT ON COLUMN public.actor_session_worker_assignments.worker_id IS 'Worker selected for the session.';

COMMENT ON COLUMN public.actor_session_worker_assignments.transport_route IS 'Actor transport route used for the session.';

COMMENT ON COLUMN public.actor_session_worker_assignments.status IS 'Assignment lifecycle state.';

COMMENT ON COLUMN public.actor_session_worker_assignments.assigned_at IS 'Time the assignment was created.';

COMMENT ON COLUMN public.actor_session_worker_assignments.last_used_at IS 'Most recent time the assignment handled work.';

COMMENT ON COLUMN public.actor_session_worker_assignments.metadata IS 'Assignment metadata outside the scheduler contract.';

CREATE TABLE public.actor_session_workspaces (
    id bigint NOT NULL,
    agent_uid text NOT NULL,
    session_id text NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT actor_session_workspaces_id_range CHECK (((id >= 10000) AND (id <= '9007199254740991'::bigint))),
    CONSTRAINT actor_session_workspaces_session_id_present CHECK ((length(btrim(session_id)) > 0))
);

ALTER TABLE public.actor_session_workspaces ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.actor_session_workspaces_id_seq
    START WITH 10000
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE public.agent_computer_worker_envs (
    scope text NOT NULL,
    name text NOT NULL,
    secret boolean NOT NULL,
    value text NOT NULL,
    description text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT agent_computer_worker_envs_name_check CHECK ((name ~ '^[A-Za-z_][A-Za-z0-9_]*$'::text)),
    CONSTRAINT agent_computer_worker_envs_scope_check CHECK (((scope = 'global'::text) OR (scope ~ '^agent:.+$'::text)))
);

COMMENT ON TABLE public.agent_computer_worker_envs IS 'Operator-defined environment variables for Agent Computer shells.';

COMMENT ON COLUMN public.agent_computer_worker_envs.scope IS 'Variable owner, either global or a concrete agent scope.';

COMMENT ON COLUMN public.agent_computer_worker_envs.name IS 'POSIX environment variable name within the scope.';

COMMENT ON COLUMN public.agent_computer_worker_envs.secret IS 'Whether value is stored as an AEAD ciphertext.';

COMMENT ON COLUMN public.agent_computer_worker_envs.value IS 'Plaintext value, or the ciphertext when secret.';

COMMENT ON COLUMN public.agent_computer_worker_envs.description IS 'Optional operator note shown in the console.';

CREATE UNLOGGED TABLE public.agent_computer_workers (
    id uuid NOT NULL,
    worker_id text NOT NULL,
    status text NOT NULL,
    version text,
    capacity jsonb DEFAULT '{}'::jsonb NOT NULL,
    load jsonb DEFAULT '{}'::jsonb NOT NULL,
    transport_route text,
    last_worker_heartbeat_at timestamp(6) without time zone,
    started_at timestamp(6) without time zone,
    stopped_at timestamp(6) without time zone,
    stop_reason text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    incarnation_id text NOT NULL,
    CONSTRAINT agent_computer_workers_capacity_object CHECK ((jsonb_typeof(capacity) = 'object'::text)),
    CONSTRAINT agent_computer_workers_load_object CHECK ((jsonb_typeof(load) = 'object'::text)),
    CONSTRAINT agent_computer_workers_metadata_object CHECK ((jsonb_typeof(metadata) = 'object'::text)),
    CONSTRAINT agent_computer_workers_status_check CHECK ((status = ANY (ARRAY['ready'::text, 'stale'::text, 'draining'::text, 'stopped'::text])))
);

COMMENT ON TABLE public.agent_computer_workers IS 'Volatile registry of connected Agent Computer workers.';

COMMENT ON COLUMN public.agent_computer_workers.worker_id IS 'Worker process id authenticated by the control plane.';

COMMENT ON COLUMN public.agent_computer_workers.status IS 'Worker availability state used by assignment policy.';

COMMENT ON COLUMN public.agent_computer_workers.version IS 'Worker software version reported at admission.';

COMMENT ON COLUMN public.agent_computer_workers.capacity IS 'Worker capacity advertisement.';

COMMENT ON COLUMN public.agent_computer_workers.load IS 'Current worker load advertisement.';

COMMENT ON COLUMN public.agent_computer_workers.transport_route IS 'Actor transport route proven for this worker connection.';

COMMENT ON COLUMN public.agent_computer_workers.last_worker_heartbeat_at IS 'Most recent heartbeat time observed from the worker.';

COMMENT ON COLUMN public.agent_computer_workers.started_at IS 'Worker-reported start time.';

COMMENT ON COLUMN public.agent_computer_workers.stopped_at IS 'Time the worker was marked stopped.';

COMMENT ON COLUMN public.agent_computer_workers.stop_reason IS 'Operator-visible reason for the stopped state.';

COMMENT ON COLUMN public.agent_computer_workers.metadata IS 'Worker metadata outside the scheduler contract.';

COMMENT ON COLUMN public.agent_computer_workers.incarnation_id IS 'One concrete process lifetime behind the stable worker id.';

CREATE TABLE public.agent_library_container_entries (
    id uuid NOT NULL,
    agent_uid text NOT NULL,
    path text NOT NULL,
    source_kind text NOT NULL,
    content text,
    content_hash text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    deleted_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT agent_library_container_entries_metadata_object CHECK ((jsonb_typeof(metadata) = 'object'::text)),
    CONSTRAINT agent_library_container_entries_path_present CHECK ((length(btrim(path)) > 0)),
    CONSTRAINT agent_library_container_entries_source_kind_check CHECK ((source_kind = ANY (ARRAY['soul'::text, 'mission'::text, 'design'::text])))
);

COMMENT ON TABLE public.agent_library_container_entries IS 'Per-agent runtime documents for SOUL.md, MISSION.md, and DESIGN.md.';

COMMENT ON COLUMN public.agent_library_container_entries.agent_uid IS 'Agent principal that owns the library entry.';

COMMENT ON COLUMN public.agent_library_container_entries.path IS 'Agent-local library path exposed to the worker.';

COMMENT ON COLUMN public.agent_library_container_entries.source_kind IS 'Agent document kind: soul, mission, or design.';

COMMENT ON COLUMN public.agent_library_container_entries.content IS 'Text content stored for file-backed library entries.';

COMMENT ON COLUMN public.agent_library_container_entries.content_hash IS 'Hash of the stored content projection.';

COMMENT ON COLUMN public.agent_library_container_entries.metadata IS 'Library entry metadata outside the file content contract.';

COMMENT ON COLUMN public.agent_library_container_entries.deleted_at IS 'Soft-delete marker that removes the path from the active library view.';

CREATE TABLE public.agent_plugin_overrides (
    id uuid NOT NULL,
    agent_uid text NOT NULL,
    agent_plugin_id text NOT NULL,
    enabled boolean NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT agent_plugin_overrides_agent_plugin_id_format CHECK ((agent_plugin_id ~ '^[a-z][a-z0-9_-]{0,63}$'::text))
);

CREATE TABLE public.agent_skill_overlays (
    id uuid NOT NULL,
    agent_uid text NOT NULL,
    skill_name text NOT NULL,
    overlay_json jsonb DEFAULT '{}'::jsonb NOT NULL,
    content_hash text NOT NULL,
    deleted_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT agent_skill_overlays_content_hash_present CHECK ((length(btrim(content_hash)) > 0)),
    CONSTRAINT agent_skill_overlays_overlay_object CHECK ((jsonb_typeof(overlay_json) = 'object'::text)),
    CONSTRAINT agent_skill_overlays_skill_name_format CHECK ((skill_name ~ '^[a-z][a-z0-9_-]{0,63}$'::text))
);

COMMENT ON TABLE public.agent_skill_overlays IS 'Per-agent skill overlay documents authored after built-in sync.';

COMMENT ON COLUMN public.agent_skill_overlays.agent_uid IS 'Agent principal that owns the overlay.';

COMMENT ON COLUMN public.agent_skill_overlays.skill_name IS 'Skill whose overlay is being customized.';

COMMENT ON COLUMN public.agent_skill_overlays.overlay_json IS 'Structured overlay content applied on top of the base skill.';

COMMENT ON COLUMN public.agent_skill_overlays.content_hash IS 'Hash of the overlay JSON projection.';

COMMENT ON COLUMN public.agent_skill_overlays.deleted_at IS 'Soft-delete marker that removes the overlay from the active skill view.';

CREATE TABLE public.agent_skills (
    id uuid NOT NULL,
    agent_uid text NOT NULL,
    skill_name text NOT NULL,
    source_kind text NOT NULL,
    relative_path text NOT NULL,
    enabled_override boolean,
    default_enabled boolean NOT NULL,
    description text NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    content_hash text NOT NULL,
    synced_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    agent_plugin_id text,
    CONSTRAINT agent_skills_agent_plugin_id_format CHECK (((agent_plugin_id IS NULL) OR (agent_plugin_id ~ '^[a-z][a-z0-9_-]{0,63}$'::text))),
    CONSTRAINT agent_skills_content_hash_present CHECK ((length(btrim(content_hash)) > 0)),
    CONSTRAINT agent_skills_description_present CHECK ((length(btrim(description)) > 0)),
    CONSTRAINT agent_skills_metadata_object CHECK ((jsonb_typeof(metadata) = 'object'::text)),
    CONSTRAINT agent_skills_relative_path_present CHECK ((length(btrim(relative_path)) > 0)),
    CONSTRAINT agent_skills_skill_name_format CHECK ((skill_name ~ '^[a-z][a-z0-9_-]{0,63}$'::text)),
    CONSTRAINT agent_skills_source_kind_check CHECK ((source_kind = ANY (ARRAY['builtin'::text, 'installed'::text])))
);

COMMENT ON TABLE public.agent_skills IS 'Per-agent skill registry used by runtime skill discovery.';

COMMENT ON COLUMN public.agent_skills.agent_uid IS 'Agent principal that owns the skill registry row.';

COMMENT ON COLUMN public.agent_skills.skill_name IS 'Agent-visible skill name.';

COMMENT ON COLUMN public.agent_skills.source_kind IS 'Whether the skill comes from built-in repository content or installed files.';

COMMENT ON COLUMN public.agent_skills.relative_path IS 'Path to the skill entrypoint relative to its source root.';

COMMENT ON COLUMN public.agent_skills.enabled_override IS 'Whether the skill is currently enabled for the agent.';

COMMENT ON COLUMN public.agent_skills.default_enabled IS 'Default enablement from the source before agent overrides.';

COMMENT ON COLUMN public.agent_skills.description IS 'Short skill description shown to operators and workers.';

COMMENT ON COLUMN public.agent_skills.metadata IS 'Skill metadata outside the discovery contract.';

COMMENT ON COLUMN public.agent_skills.content_hash IS 'Hash of the skill entrypoint or synchronized source projection.';

COMMENT ON COLUMN public.agent_skills.synced_at IS 'Time this registry row was last synchronized from its source.';

CREATE TABLE public.agents (
    uid text NOT NULL,
    type public.agent_type DEFAULT 'ai_colleague'::public.agent_type NOT NULL,
    role text NOT NULL,
    options jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_by_principal_uid text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT agents_options_object CHECK ((jsonb_typeof(options) = 'object'::text)),
    CONSTRAINT agents_role_present CHECK ((length(btrim(role)) > 0))
);

COMMENT ON TABLE public.agents IS 'Agent-only profile fields for principals that run work.';

COMMENT ON COLUMN public.agents.uid IS 'Principal uid this agent profile extends.';

COMMENT ON COLUMN public.agents.type IS 'Agent subtype; currently all runtime agents are AI colleagues.';

COMMENT ON COLUMN public.agents.role IS 'Human-authored role statement used to frame the agent identity.';

COMMENT ON COLUMN public.agents.options IS 'Agent profile options that are not modeled as first-class columns.';

COMMENT ON COLUMN public.agents.created_by_principal_uid IS 'Human or agent principal that created this agent.';

CREATE TABLE public.ai_gateway_artifacts (
    id uuid NOT NULL,
    subject_uid text NOT NULL,
    message_id uuid,
    kind text NOT NULL,
    filename text,
    purpose text,
    mime_type text NOT NULL,
    byte_size bigint NOT NULL,
    sha256 bytea NOT NULL,
    payload bytea NOT NULL,
    expires_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT ai_gateway_artifacts_generated_image_contract CHECK (((kind <> 'generated_image'::text) OR (purpose IS NULL))),
    CONSTRAINT ai_gateway_artifacts_kind_check CHECK ((kind = ANY (ARRAY['uploaded_file'::text, 'generated_image'::text]))),
    CONSTRAINT ai_gateway_artifacts_payload_size_check CHECK (((byte_size >= 0) AND (byte_size = octet_length(payload)))),
    CONSTRAINT ai_gateway_artifacts_sha256_size_check CHECK ((octet_length(sha256) = 32)),
    CONSTRAINT ai_gateway_artifacts_uploaded_file_contract CHECK (((kind <> 'uploaded_file'::text) OR ((message_id IS NULL) AND (filename IS NOT NULL) AND (purpose = 'vision'::text))))
);

COMMENT ON TABLE public.ai_gateway_artifacts IS 'Principal-scoped uploaded files and generated images for AIGateway hosted tools.';

CREATE TABLE public.ai_gateway_compaction_artifacts (
    id uuid NOT NULL,
    subject_uid text NOT NULL,
    conversation_id uuid,
    content jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT ai_gateway_compaction_artifacts_content_object CHECK ((jsonb_typeof(content) = 'object'::text))
);

COMMENT ON TABLE public.ai_gateway_compaction_artifacts IS 'Immutable compaction artifacts owned by an AIGateway subject.';

COMMENT ON COLUMN public.ai_gateway_compaction_artifacts.subject_uid IS 'Principal that owns the compaction artifact.';

COMMENT ON COLUMN public.ai_gateway_compaction_artifacts.conversation_id IS 'Optional conversation associated with stateful/checkpoint compaction.';

COMMENT ON COLUMN public.ai_gateway_compaction_artifacts.content IS 'Versioned compaction artifact JSON body including summary, output, retention, and usage.';

CREATE TABLE public.ai_gateway_conversations (
    id uuid NOT NULL,
    subject_uid text NOT NULL,
    conversation_key text NOT NULL,
    ended_at timestamp without time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT ai_gateway_conversations_metadata_object CHECK ((jsonb_typeof(metadata) = 'object'::text))
);

COMMENT ON TABLE public.ai_gateway_conversations IS 'Durable AIGateway conversation threads per Principal subject.';

COMMENT ON COLUMN public.ai_gateway_conversations.subject_uid IS 'Principal that owns the conversation.';

COMMENT ON COLUMN public.ai_gateway_conversations.conversation_key IS 'Subject-local key used to identify an active conversation.';

COMMENT ON COLUMN public.ai_gateway_conversations.ended_at IS 'Time the conversation was closed and excluded from active-key uniqueness.';

COMMENT ON COLUMN public.ai_gateway_conversations.metadata IS 'Conversation metadata outside the stable message contract.';

CREATE TABLE public.ai_gateway_messages (
    id uuid NOT NULL,
    subject_uid text NOT NULL,
    conversation_id uuid NOT NULL,
    type text NOT NULL,
    role text,
    status text NOT NULL,
    previous_message_id uuid,
    content jsonb DEFAULT '[]'::jsonb NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT ai_gateway_messages_checkpoint_content_ref CHECK (((type <> 'checkpoint'::text) OR ((jsonb_array_length(content) = 1) AND (((content -> 0) ->> 'type'::text) = 'compaction_artifact'::text) AND (((content -> 0) ->> 'id'::text) ~ '^cmp_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'::text)))),
    CONSTRAINT ai_gateway_messages_content_array CHECK ((jsonb_typeof(content) = 'array'::text)),
    CONSTRAINT ai_gateway_messages_message_content_no_compaction_refs CHECK (((type <> 'message'::text) OR (NOT jsonb_path_exists(content, '$[*]?(@."type" == "compaction" || @."type" == "compaction_artifact")'::jsonpath)))),
    CONSTRAINT ai_gateway_messages_metadata_object CHECK ((jsonb_typeof(metadata) = 'object'::text)),
    CONSTRAINT ai_gateway_messages_role_check CHECK (((role IS NULL) OR (role = ANY (ARRAY['user'::text, 'assistant'::text, 'tool'::text, 'im_ambient'::text])))),
    CONSTRAINT ai_gateway_messages_status_check CHECK ((status = ANY (ARRAY['generating'::text, 'complete'::text, 'error'::text, 'retracted'::text]))),
    CONSTRAINT ai_gateway_messages_type_check CHECK ((type = ANY (ARRAY['message'::text, 'checkpoint'::text])))
);

COMMENT ON TABLE public.ai_gateway_messages IS 'Stored Response, journal, and checkpoint facts owned by AIGateway.';

COMMENT ON COLUMN public.ai_gateway_messages.subject_uid IS 'Principal that owns the response message.';

COMMENT ON COLUMN public.ai_gateway_messages.conversation_id IS 'Conversation containing the message.';

COMMENT ON COLUMN public.ai_gateway_messages.type IS 'Row-level semantic: message (normal) or checkpoint (compaction continuation).';

COMMENT ON COLUMN public.ai_gateway_messages.role IS 'Legacy transcript/UI role hint; not the authoritative Response item role.';

COMMENT ON COLUMN public.ai_gateway_messages.status IS 'Lifecycle: generating, complete, error, or retracted.';

COMMENT ON COLUMN public.ai_gateway_messages.previous_message_id IS 'Self-reference continuation anchor; renders as previous_response_id on the API.';

COMMENT ON COLUMN public.ai_gateway_messages.content IS 'OpenResponses ResponseItem[] for message rows, or one compaction_artifact ref for checkpoint rows.';

COMMENT ON COLUMN public.ai_gateway_messages.metadata IS 'Opaque caller metadata plus AIGateway response facts.';

CREATE TABLE public.ai_gateway_providers (
    id uuid NOT NULL,
    provider_id text NOT NULL,
    provider_kind text NOT NULL,
    base_url text,
    connection_options jsonb DEFAULT '{}'::jsonb NOT NULL,
    disabled_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    credential_pool jsonb DEFAULT '{"entries": [], "strategy": "fill_first"}'::jsonb NOT NULL,
    CONSTRAINT ai_gateway_providers_base_url_present CHECK (((base_url IS NULL) OR (base_url <> ''::text))),
    CONSTRAINT ai_gateway_providers_connection_options_object CHECK ((jsonb_typeof(connection_options) = 'object'::text)),
    CONSTRAINT ai_gateway_providers_credential_pool_object CHECK ((jsonb_typeof(credential_pool) = 'object'::text)),
    CONSTRAINT ai_gateway_providers_provider_id_format CHECK ((provider_id ~ '^[a-z][a-z0-9_-]{0,62}$'::text)),
    CONSTRAINT ai_gateway_providers_provider_kind_format CHECK ((provider_kind ~ '^[a-z][a-z0-9_]{0,62}$'::text))
);

COMMENT ON TABLE public.ai_gateway_providers IS 'Operator-managed AIGateway provider connections.';

COMMENT ON COLUMN public.ai_gateway_providers.id IS 'Opaque UUIDv7 row id used as the provider encrypted option context.';

COMMENT ON COLUMN public.ai_gateway_providers.provider_id IS 'Stable operator-facing provider id referenced by model profiles.';

COMMENT ON COLUMN public.ai_gateway_providers.provider_kind IS 'Provider kind module id such as OpenRouter, OpenAI, Claude, or Jina.';

COMMENT ON COLUMN public.ai_gateway_providers.base_url IS 'Optional provider API base URL override.';

COMMENT ON COLUMN public.ai_gateway_providers.connection_options IS 'Provider-kind-specific connection options used during runtime resolution.';

COMMENT ON COLUMN public.ai_gateway_providers.disabled_at IS 'Time the provider was disabled and excluded from runtime resolution.';

CREATE TABLE public.app_configurations (
    scope text NOT NULL,
    key text NOT NULL,
    value jsonb NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT app_configurations_scope_check CHECK (((scope = 'global'::text) OR (scope ~ '^agent:.+$'::text))),
    CONSTRAINT app_configurations_value_envelope_check CHECK (((jsonb_typeof(value) = 'object'::text) AND (value ? 'type'::text) AND (value ? 'value'::text)))
);

COMMENT ON TABLE public.app_configurations IS 'Typed installation and agent configuration values.';

COMMENT ON COLUMN public.app_configurations.scope IS 'Configuration owner, either global or a concrete agent scope.';

COMMENT ON COLUMN public.app_configurations.key IS 'Registered configuration key within the scope.';

COMMENT ON COLUMN public.app_configurations.value IS 'Typed configuration envelope with type and value members.';

CREATE TABLE public.automation_job_runs (
    id bigint NOT NULL,
    automation_job_id bigint NOT NULL,
    event jsonb NOT NULL,
    status text DEFAULT 'queued'::text NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    attempt_id uuid,
    oban_job_id bigint,
    started_at timestamp without time zone,
    last_attempt_at timestamp without time zone,
    finished_at timestamp without time zone,
    exit_code integer,
    error text,
    stdout text DEFAULT ''::text NOT NULL,
    stderr text DEFAULT ''::text NOT NULL,
    stdout_truncated boolean DEFAULT false NOT NULL,
    stderr_truncated boolean DEFAULT false NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT automation_job_runs_attempts_nonnegative CHECK ((attempts >= 0)),
    CONSTRAINT automation_job_runs_event_object CHECK (((jsonb_typeof(event) = 'object'::text) AND (octet_length((event)::text) <= 1048576))),
    CONSTRAINT automation_job_runs_id_range CHECK (((id >= 1000) AND (id <= '9007199254740991'::bigint))),
    CONSTRAINT automation_job_runs_lifecycle_check CHECK ((((status = 'queued'::text) AND (finished_at IS NULL) AND (attempt_id IS NULL)) OR ((status = 'running'::text) AND (started_at IS NOT NULL) AND (finished_at IS NULL) AND (attempt_id IS NOT NULL)) OR ((status = ANY (ARRAY['succeeded'::text, 'failed'::text, 'cancelled'::text])) AND (finished_at IS NOT NULL) AND (attempt_id IS NULL)))),
    CONSTRAINT automation_job_runs_logs_bounded CHECK (((octet_length(stdout) <= 65536) AND (octet_length(stderr) <= 65536) AND (octet_length(COALESCE(error, ''::text)) <= 65536))),
    CONSTRAINT automation_job_runs_status_check CHECK ((status = ANY (ARRAY['queued'::text, 'running'::text, 'succeeded'::text, 'failed'::text, 'cancelled'::text])))
);

ALTER TABLE public.automation_job_runs ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.automation_job_runs_id_seq
    START WITH 1000
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE public.automation_jobs (
    id bigint NOT NULL,
    agent_uid text NOT NULL,
    owner_session_id text NOT NULL,
    source_actor_event_id uuid,
    source_entry_id text,
    source_provenance jsonb DEFAULT '{}'::jsonb NOT NULL,
    reply_route jsonb DEFAULT '{}'::jsonb NOT NULL,
    directory_path text NOT NULL,
    label text NOT NULL,
    wake_on_failure boolean DEFAULT false NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    expires_at timestamp without time zone,
    cancelled_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT automation_jobs_directory_path_present CHECK (((length(btrim(directory_path)) > 0) AND (length(directory_path) <= 4096))),
    CONSTRAINT automation_jobs_id_range CHECK (((id >= 1000) AND (id <= '9007199254740991'::bigint))),
    CONSTRAINT automation_jobs_label_present CHECK (((length(btrim(label)) > 0) AND (length(label) <= 500))),
    CONSTRAINT automation_jobs_owner_session_present CHECK ((length(btrim(owner_session_id)) > 0)),
    CONSTRAINT automation_jobs_reply_route_object CHECK ((jsonb_typeof(reply_route) = 'object'::text)),
    CONSTRAINT automation_jobs_source_provenance_object CHECK ((jsonb_typeof(source_provenance) = 'object'::text)),
    CONSTRAINT automation_jobs_status_check CHECK ((status = ANY (ARRAY['active'::text, 'cancelled'::text, 'expired'::text]))),
    CONSTRAINT automation_jobs_terminal_time_check CHECK ((((status = 'active'::text) AND (cancelled_at IS NULL)) OR ((status = 'cancelled'::text) AND (cancelled_at IS NOT NULL)) OR (status = 'expired'::text)))
);

ALTER TABLE public.automation_jobs ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.automation_jobs_id_seq
    START WITH 1000
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE public.background_agent_job_turn_trajectory_groups (
    turn_id uuid NOT NULL,
    "position" integer NOT NULL,
    revision integer NOT NULL,
    item_key text NOT NULL,
    content jsonb NOT NULL,
    inserted_at timestamp without time zone CONSTRAINT background_agent_job_turn_trajectory_group_inserted_at_not_null NOT NULL,
    CONSTRAINT baj_turn_trajectory_groups_content_check CHECK (((jsonb_typeof(content) = 'object'::text) AND (jsonb_typeof((content -> 'messages'::text)) = 'array'::text) AND (jsonb_array_length((content -> 'messages'::text)) > 0) AND (jsonb_array_length(jsonb_path_query_array(content, '$."messages"[*]."role"'::jsonpath)) = jsonb_array_length((content -> 'messages'::text))) AND (jsonb_path_query_array(content, '$."messages"[*]."role"'::jsonpath) <@ '["user", "developer", "assistant", "tool"]'::jsonb))),
    CONSTRAINT baj_turn_trajectory_groups_item_key_present CHECK ((length(btrim(item_key)) > 0)),
    CONSTRAINT baj_turn_trajectory_groups_position_nonnegative CHECK (("position" >= 0)),
    CONSTRAINT baj_turn_trajectory_groups_revision_nonnegative CHECK ((revision >= 0))
);

CREATE TABLE public.background_agent_job_turns (
    id uuid CONSTRAINT subagent_delegation_turns_id_not_null NOT NULL,
    job_id bigint CONSTRAINT subagent_delegation_turns_delegation_id_not_null NOT NULL,
    attempt integer CONSTRAINT subagent_delegation_turns_attempt_not_null NOT NULL,
    runtime_thread_id text CONSTRAINT subagent_delegation_turns_runtime_thread_id_not_null NOT NULL,
    runtime_turn_id text CONSTRAINT subagent_delegation_turns_runtime_turn_id_not_null NOT NULL,
    kind text DEFAULT 'agent'::text CONSTRAINT subagent_delegation_turns_kind_not_null NOT NULL,
    status text CONSTRAINT subagent_delegation_turns_status_not_null NOT NULL,
    revision bigint CONSTRAINT subagent_delegation_turns_revision_not_null NOT NULL,
    trajectory jsonb CONSTRAINT subagent_delegation_turns_trajectory_not_null NOT NULL,
    usage jsonb,
    error jsonb DEFAULT '{}'::jsonb CONSTRAINT subagent_delegation_turns_error_not_null NOT NULL,
    started_at timestamp without time zone CONSTRAINT subagent_delegation_turns_started_at_not_null NOT NULL,
    completed_at timestamp without time zone,
    inserted_at timestamp without time zone CONSTRAINT subagent_delegation_turns_inserted_at_not_null NOT NULL,
    updated_at timestamp without time zone CONSTRAINT subagent_delegation_turns_updated_at_not_null NOT NULL,
    progress jsonb DEFAULT '{"tool_calls": 0, "tools_used": [], "files_changed": [], "completed_items": 0}'::jsonb CONSTRAINT subagent_delegation_turns_progress_not_null NOT NULL,
    CONSTRAINT background_agent_job_turns_attempt_positive CHECK ((attempt > 0)),
    CONSTRAINT background_agent_job_turns_completion_check CHECK ((((status = 'in_progress'::text) AND (completed_at IS NULL)) OR ((status = ANY (ARRAY['completed'::text, 'failed'::text, 'interrupted'::text])) AND (completed_at IS NOT NULL)))),
    CONSTRAINT background_agent_job_turns_error_object CHECK ((jsonb_typeof(error) = 'object'::text)),
    CONSTRAINT background_agent_job_turns_kind_check CHECK ((kind = ANY (ARRAY['agent'::text, 'compaction'::text]))),
    CONSTRAINT background_agent_job_turns_progress_object CHECK ((jsonb_typeof(progress) = 'object'::text)),
    CONSTRAINT background_agent_job_turns_revision_nonnegative CHECK ((revision >= 0)),
    CONSTRAINT background_agent_job_turns_status_check CHECK ((status = ANY (ARRAY['in_progress'::text, 'completed'::text, 'failed'::text, 'interrupted'::text]))),
    CONSTRAINT background_agent_job_turns_trajectory_check CHECK (((jsonb_typeof(trajectory) = 'object'::text) AND (trajectory @> '{"format": "ankole_chatml", "version": 1}'::jsonb) AND (NOT (trajectory ? 'messages'::text)))),
    CONSTRAINT background_agent_job_turns_usage_object CHECK ((jsonb_typeof(usage) = 'object'::text))
);

CREATE TABLE public.background_agent_jobs (
    id bigint CONSTRAINT subagent_delegations_id_not_null NOT NULL,
    agent_uid text CONSTRAINT subagent_delegations_agent_uid_not_null NOT NULL,
    owner_session_id text CONSTRAINT subagent_delegations_session_id_not_null NOT NULL,
    source_actor_event_id uuid,
    source_tool_call_id text,
    runtime_thread_id text,
    status text CONSTRAINT subagent_delegations_status_not_null NOT NULL,
    queued_at timestamp without time zone,
    started_at timestamp without time zone,
    completed_at timestamp without time zone,
    result jsonb DEFAULT '{}'::jsonb CONSTRAINT subagent_delegations_result_not_null NOT NULL,
    error jsonb DEFAULT '{}'::jsonb CONSTRAINT subagent_delegations_error_not_null NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb CONSTRAINT subagent_delegations_metadata_not_null NOT NULL,
    title text CONSTRAINT subagent_delegations_title_not_null NOT NULL,
    task text CONSTRAINT subagent_delegations_task_not_null NOT NULL,
    reply_route jsonb DEFAULT '{}'::jsonb CONSTRAINT subagent_delegations_reply_route_not_null NOT NULL,
    attempts integer DEFAULT 0 CONSTRAINT subagent_delegations_attempts_not_null NOT NULL,
    inserted_at timestamp without time zone CONSTRAINT subagent_delegations_inserted_at_not_null NOT NULL,
    updated_at timestamp without time zone CONSTRAINT subagent_delegations_updated_at_not_null NOT NULL,
    workspace_mounts jsonb DEFAULT '[]'::jsonb NOT NULL,
    workspace_template_id text,
    continued_from_job_id bigint,
    workspace_owner_job_id bigint NOT NULL,
    runtime_projection jsonb,
    model_profile text DEFAULT 'coding'::text NOT NULL,
    CONSTRAINT background_agent_jobs_attempts_nonnegative CHECK ((attempts >= 0)),
    CONSTRAINT background_agent_jobs_continued_from_not_self CHECK (((continued_from_job_id IS NULL) OR (continued_from_job_id <> id))),
    CONSTRAINT background_agent_jobs_error_object CHECK ((jsonb_typeof(error) = 'object'::text)),
    CONSTRAINT background_agent_jobs_id_range CHECK (((id >= 1000) AND (id <= '9007199254740991'::bigint))),
    CONSTRAINT background_agent_jobs_metadata_object CHECK ((jsonb_typeof(metadata) = 'object'::text)),
    CONSTRAINT background_agent_jobs_model_profile_valid CHECK ((model_profile ~ '^[a-z][a-z0-9_-]{0,63}$'::text)),
    CONSTRAINT background_agent_jobs_reply_route_object CHECK ((jsonb_typeof(reply_route) = 'object'::text)),
    CONSTRAINT background_agent_jobs_result_object CHECK ((jsonb_typeof(result) = 'object'::text)),
    CONSTRAINT background_agent_jobs_runtime_projection_object CHECK (((runtime_projection IS NULL) OR (jsonb_typeof(runtime_projection) = 'object'::text))),
    CONSTRAINT background_agent_jobs_status_check CHECK ((status = ANY (ARRAY['queued'::text, 'running'::text, 'waiting_on_user'::text, 'succeeded'::text, 'failed'::text, 'stopped'::text]))),
    CONSTRAINT background_agent_jobs_workspace_template_id_valid CHECK (((workspace_template_id IS NULL) OR (workspace_template_id ~ '^[a-z][a-z0-9_-]{0,63}$'::text)))
);

CREATE TABLE public.brain_audit_log (
    id uuid NOT NULL,
    owner_uid text NOT NULL,
    store_key text NOT NULL,
    actor_kind public.brain_author_kind,
    actor_uid text,
    action text NOT NULL,
    entry_id uuid,
    block_id uuid,
    relation_id uuid,
    before jsonb,
    after jsonb,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT brain_audit_log_action_present CHECK ((length(btrim(action)) > 0)),
    CONSTRAINT brain_audit_log_after_object CHECK (((after IS NULL) OR (jsonb_typeof(after) = 'object'::text))),
    CONSTRAINT brain_audit_log_before_object CHECK (((before IS NULL) OR (jsonb_typeof(before) = 'object'::text))),
    CONSTRAINT brain_audit_log_metadata_object CHECK ((jsonb_typeof(metadata) = 'object'::text)),
    CONSTRAINT brain_audit_log_store_key_check CHECK (((store_key = ANY (ARRAY['shared'::text, 'self'::text])) OR ((store_key ~~ 'dm:%'::text) AND (length(store_key) > 3)) OR ((store_key ~~ 'channel:%'::text) AND (length(store_key) > 8))))
);

CREATE TABLE public.brain_block_citations (
    block_id uuid NOT NULL,
    document_id text NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT brain_block_citations_document_id_check CHECK (((document_id ~~ 'signal-gateway-entry:%'::text) OR (document_id ~~ 'brain-source:%'::text)))
);

CREATE TABLE public.brain_cursors (
    scope_kind public.brain_cursor_scope_kind NOT NULL,
    scope_key text NOT NULL,
    cursor_provider_time timestamp without time zone,
    cursor_source_entry_id text,
    cursor_entry_observed_at timestamp without time zone,
    unavailable_reason text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT brain_cursors_metadata_object CHECK ((jsonb_typeof(metadata) = 'object'::text)),
    CONSTRAINT brain_cursors_scope_key_present CHECK ((length(btrim(scope_key)) > 0))
);

CREATE TABLE public.brain_entries (
    id uuid NOT NULL,
    owner_uid text NOT NULL,
    store_key text NOT NULL,
    name text NOT NULL,
    type text NOT NULL,
    summary text DEFAULT ''::text NOT NULL,
    aliases text[] DEFAULT ARRAY[]::text[] NOT NULL,
    properties jsonb DEFAULT '{}'::jsonb NOT NULL,
    search_text text NOT NULL,
    lock_version integer DEFAULT 1 NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT brain_entries_lock_version_positive CHECK ((lock_version > 0)),
    CONSTRAINT brain_entries_name_present CHECK ((length(btrim(name)) > 0)),
    CONSTRAINT brain_entries_properties_object CHECK ((jsonb_typeof(properties) = 'object'::text)),
    CONSTRAINT brain_entries_search_text_present CHECK ((length(btrim(search_text)) > 0)),
    CONSTRAINT brain_entries_store_key_check CHECK (((store_key = ANY (ARRAY['shared'::text, 'self'::text])) OR ((store_key ~~ 'dm:%'::text) AND (length(store_key) > 3)) OR ((store_key ~~ 'channel:%'::text) AND (length(store_key) > 8)))),
    CONSTRAINT brain_entries_type_present CHECK ((length(btrim(type)) > 0))
);

CREATE TABLE public.brain_entry_blocks (
    id uuid NOT NULL,
    entry_id uuid NOT NULL,
    owner_uid text NOT NULL,
    store_key text NOT NULL,
    "position" integer NOT NULL,
    body text NOT NULL,
    author_kind public.brain_author_kind NOT NULL,
    author_uid text,
    embedding public.vector(4096),
    embedding_dimensions integer,
    embedding_state public.brain_embedding_state DEFAULT 'pending'::public.brain_embedding_state NOT NULL,
    embedding_error text,
    lock_version integer DEFAULT 1 NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    embedding_model_agent_uid text,
    CONSTRAINT brain_entry_blocks_body_present CHECK ((length(btrim(body)) > 0)),
    CONSTRAINT brain_entry_blocks_embedding_dimensions_positive CHECK (((embedding_dimensions IS NULL) OR (embedding_dimensions > 0))),
    CONSTRAINT brain_entry_blocks_embedding_state_consistent CHECK ((((embedding_state = 'pending'::public.brain_embedding_state) AND (embedding IS NULL) AND (embedding_dimensions IS NULL) AND (embedding_model_agent_uid IS NULL) AND (embedding_error IS NULL)) OR ((embedding_state = 'synced'::public.brain_embedding_state) AND (embedding IS NOT NULL) AND (embedding_dimensions IS NOT NULL) AND (embedding_model_agent_uid IS NOT NULL) AND (embedding_error IS NULL)) OR ((embedding_state = 'failed'::public.brain_embedding_state) AND (embedding IS NULL) AND (embedding_dimensions IS NULL) AND (embedding_model_agent_uid IS NULL) AND (length(btrim(embedding_error)) > 0)))),
    CONSTRAINT brain_entry_blocks_lock_version_positive CHECK ((lock_version > 0)),
    CONSTRAINT brain_entry_blocks_position_nonnegative CHECK (("position" >= 0)),
    CONSTRAINT brain_entry_blocks_store_key_check CHECK (((store_key = ANY (ARRAY['shared'::text, 'self'::text])) OR ((store_key ~~ 'dm:%'::text) AND (length(store_key) > 3)) OR ((store_key ~~ 'channel:%'::text) AND (length(store_key) > 8))))
);

CREATE TABLE public.brain_entry_relations (
    id uuid NOT NULL,
    owner_uid text NOT NULL,
    store_key text NOT NULL,
    source_entry_id uuid NOT NULL,
    predicate text NOT NULL,
    target_entry_id uuid NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT brain_entry_relations_no_self_edge CHECK ((source_entry_id <> target_entry_id)),
    CONSTRAINT brain_entry_relations_predicate_present CHECK ((length(btrim(predicate)) > 0)),
    CONSTRAINT brain_entry_relations_store_key_check CHECK (((store_key = ANY (ARRAY['shared'::text, 'self'::text])) OR ((store_key ~~ 'dm:%'::text) AND (length(store_key) > 3)) OR ((store_key ~~ 'channel:%'::text) AND (length(store_key) > 8))))
);

CREATE TABLE public.brain_episodes (
    id uuid NOT NULL,
    signal_channel_id text NOT NULL,
    topic text NOT NULL,
    summary text NOT NULL,
    source_entry_ids text[] DEFAULT ARRAY[]::text[] NOT NULL,
    started_at timestamp without time zone NOT NULL,
    ended_at timestamp without time zone NOT NULL,
    embedding public.vector(4096),
    embedding_dimensions integer,
    embedding_state public.brain_embedding_state DEFAULT 'pending'::public.brain_embedding_state NOT NULL,
    embedding_error text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    embedding_model_agent_uid text,
    CONSTRAINT brain_episodes_embedding_dimensions_positive CHECK (((embedding_dimensions IS NULL) OR (embedding_dimensions > 0))),
    CONSTRAINT brain_episodes_embedding_state_consistent CHECK ((((embedding_state = 'pending'::public.brain_embedding_state) AND (embedding IS NULL) AND (embedding_dimensions IS NULL) AND (embedding_model_agent_uid IS NULL) AND (embedding_error IS NULL)) OR ((embedding_state = 'synced'::public.brain_embedding_state) AND (embedding IS NOT NULL) AND (embedding_dimensions IS NOT NULL) AND (embedding_model_agent_uid IS NOT NULL) AND (embedding_error IS NULL)) OR ((embedding_state = 'failed'::public.brain_embedding_state) AND (embedding IS NULL) AND (embedding_dimensions IS NULL) AND (embedding_model_agent_uid IS NULL) AND (length(btrim(embedding_error)) > 0)))),
    CONSTRAINT brain_episodes_metadata_object CHECK ((jsonb_typeof(metadata) = 'object'::text)),
    CONSTRAINT brain_episodes_summary_present CHECK ((length(btrim(summary)) > 0)),
    CONSTRAINT brain_episodes_topic_present CHECK ((length(btrim(topic)) > 0))
);

CREATE TABLE public.brain_retained_sources (
    id uuid NOT NULL,
    document_id text NOT NULL,
    owner_uid text NOT NULL,
    store_key text NOT NULL,
    capture_method text NOT NULL,
    title text NOT NULL,
    origin_locator text,
    original_name text,
    media_type text NOT NULL,
    byte_size bigint NOT NULL,
    sha256 text NOT NULL,
    raw_content bytea NOT NULL,
    captured_by_uid text,
    inserted_at timestamp without time zone NOT NULL,
    connector_id text,
    revision text,
    source_url text,
    learning_agent_uid text,
    sync_state text DEFAULT 'current'::text NOT NULL,
    last_synced_at timestamp without time zone,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    lock_version integer DEFAULT 1 NOT NULL,
    CONSTRAINT brain_retained_sources_capture_method_check CHECK ((capture_method ~ '^[a-z][a-z0-9_]{0,63}$'::text)),
    CONSTRAINT brain_retained_sources_connector_check CHECK ((((capture_method <> 'file'::text) = ((connector_id IS NOT NULL) AND (revision IS NOT NULL))) AND ((capture_method = 'file'::text) OR (capture_method = connector_id)))),
    CONSTRAINT brain_retained_sources_content_consistent CHECK (((byte_size > 0) AND (byte_size = octet_length(raw_content)) AND (sha256 ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT brain_retained_sources_document_id_check CHECK ((document_id = ('brain-source:'::text || (id)::text))),
    CONSTRAINT brain_retained_sources_learning_agent_check CHECK (((capture_method <> 'file'::text) OR (learning_agent_uid IS NOT NULL))),
    CONSTRAINT brain_retained_sources_media_type_present CHECK ((length(btrim(media_type)) > 0)),
    CONSTRAINT brain_retained_sources_store_key_check CHECK (((store_key = ANY (ARRAY['shared'::text, 'self'::text])) OR ((store_key ~~ 'dm:%'::text) AND (length(store_key) > 3)) OR ((store_key ~~ 'channel:%'::text) AND (length(store_key) > 8)))),
    CONSTRAINT brain_retained_sources_sync_state_check CHECK ((sync_state = ANY (ARRAY['current'::text, 'deleted'::text, 'access_lost'::text, 'failed'::text]))),
    CONSTRAINT brain_retained_sources_title_present CHECK ((length(btrim(title)) > 0))
);

CREATE TABLE public.human_users (
    principal_uid text NOT NULL,
    email text,
    mobile text,
    job_title text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);

COMMENT ON TABLE public.human_users IS 'Human-only profile fields for principals of type human.';

COMMENT ON COLUMN public.human_users.principal_uid IS 'Principal uid this human profile extends.';

COMMENT ON COLUMN public.human_users.email IS 'Optional human email address used for contact and login binding.';

COMMENT ON COLUMN public.human_users.mobile IS 'Optional phone number used for contact and external identity binding.';

COMMENT ON COLUMN public.human_users.job_title IS 'Operator-visible role or title for the human.';

CREATE TABLE public.library_builtin_sync_states (
    name text NOT NULL,
    content_hash text NOT NULL,
    synced_at timestamp without time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT library_builtin_sync_states_content_hash_present CHECK ((length(btrim(content_hash)) > 0)),
    CONSTRAINT library_builtin_sync_states_metadata_object CHECK ((jsonb_typeof(metadata) = 'object'::text)),
    CONSTRAINT library_builtin_sync_states_name_present CHECK ((length(btrim(name)) > 0))
);

COMMENT ON TABLE public.library_builtin_sync_states IS 'Sync checkpoints for built-in library content.';

COMMENT ON COLUMN public.library_builtin_sync_states.name IS 'Built-in content bundle or source name.';

COMMENT ON COLUMN public.library_builtin_sync_states.content_hash IS 'Hash last observed for the built-in content source.';

COMMENT ON COLUMN public.library_builtin_sync_states.synced_at IS 'Time the built-in content source was last synchronized.';

COMMENT ON COLUMN public.library_builtin_sync_states.metadata IS 'Sync metadata outside the content hash contract.';

CREATE TABLE public.oban_jobs (
    id bigint NOT NULL,
    state public.oban_job_state DEFAULT 'available'::public.oban_job_state NOT NULL,
    queue text DEFAULT 'default'::text NOT NULL,
    worker text NOT NULL,
    args jsonb DEFAULT '{}'::jsonb NOT NULL,
    errors jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    attempt integer DEFAULT 0 NOT NULL,
    max_attempts integer DEFAULT 20 NOT NULL,
    inserted_at timestamp without time zone DEFAULT timezone('UTC'::text, now()) NOT NULL,
    scheduled_at timestamp without time zone DEFAULT timezone('UTC'::text, now()) NOT NULL,
    attempted_at timestamp without time zone,
    completed_at timestamp without time zone,
    attempted_by text[],
    discarded_at timestamp without time zone,
    priority integer DEFAULT 0 NOT NULL,
    tags text[] DEFAULT ARRAY[]::text[],
    meta jsonb DEFAULT '{}'::jsonb,
    cancelled_at timestamp without time zone,
    CONSTRAINT attempt_range CHECK (((attempt >= 0) AND (attempt <= max_attempts))),
    CONSTRAINT positive_max_attempts CHECK ((max_attempts > 0)),
    CONSTRAINT queue_length CHECK (((char_length(queue) > 0) AND (char_length(queue) < 128))),
    CONSTRAINT worker_length CHECK (((char_length(worker) > 0) AND (char_length(worker) < 128)))
);

COMMENT ON TABLE public.oban_jobs IS '14';

CREATE SEQUENCE public.oban_jobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

ALTER SEQUENCE public.oban_jobs_id_seq OWNED BY public.oban_jobs.id;

CREATE UNLOGGED TABLE public.oban_peers (
    name text NOT NULL,
    node text NOT NULL,
    started_at timestamp without time zone NOT NULL,
    expires_at timestamp without time zone NOT NULL
);

CREATE TABLE public.permission_grants (
    id uuid NOT NULL,
    principal_uid text,
    group_id uuid,
    resource_pattern text NOT NULL,
    action text NOT NULL,
    condition text DEFAULT 'true'::text NOT NULL,
    description text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT permission_grants_action_no_colon CHECK ((POSITION((':'::text) IN (action)) = 0)),
    CONSTRAINT permission_grants_action_present CHECK ((length(btrim(action)) > 0)),
    CONSTRAINT permission_grants_condition_present CHECK ((length(btrim(condition)) > 0)),
    CONSTRAINT permission_grants_metadata_object CHECK ((jsonb_typeof(metadata) = 'object'::text)),
    CONSTRAINT permission_grants_owner_shape CHECK ((((principal_uid IS NOT NULL) AND (group_id IS NULL)) OR ((principal_uid IS NULL) AND (group_id IS NOT NULL)))),
    CONSTRAINT permission_grants_resource_pattern_present CHECK ((length(btrim(resource_pattern)) > 0))
);

COMMENT ON TABLE public.permission_grants IS 'Principal or group grants over resource patterns.';

COMMENT ON COLUMN public.permission_grants.principal_uid IS 'Direct principal owner of the grant when the grant is not group-based.';

COMMENT ON COLUMN public.permission_grants.group_id IS 'Group owner of the grant when the grant is not direct to a principal.';

COMMENT ON COLUMN public.permission_grants.resource_pattern IS 'Resource pattern matched by the authorization engine.';

COMMENT ON COLUMN public.permission_grants.action IS 'Action name allowed by this grant.';

COMMENT ON COLUMN public.permission_grants.condition IS 'Condition expression that must evaluate true for the grant to apply.';

COMMENT ON COLUMN public.permission_grants.description IS 'Operator-facing explanation of why the grant exists.';

COMMENT ON COLUMN public.permission_grants.metadata IS 'Grant metadata that is not evaluated by the authorization engine.';

CREATE TABLE public.principal_external_identities (
    id uuid NOT NULL,
    principal_uid text NOT NULL,
    kind public.principal_external_identity_kind NOT NULL,
    provider text,
    adapter text,
    channel_id text,
    external_id text,
    verified_at timestamp without time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT principal_external_identities_metadata_object CHECK ((jsonb_typeof(metadata) = 'object'::text)),
    CONSTRAINT principal_external_identities_provider_format CHECK (((provider IS NULL) OR (provider ~ '^[a-z][a-z0-9_-]*$'::text))),
    CONSTRAINT principal_external_identities_shape CHECK ((((kind = 'channel_actor'::public.principal_external_identity_kind) AND (provider IS NULL) AND (adapter IS NOT NULL) AND (channel_id IS NOT NULL) AND (external_id IS NOT NULL)) OR ((kind <> 'channel_actor'::public.principal_external_identity_kind) AND (provider IS NOT NULL) AND (adapter IS NULL) AND (channel_id IS NULL) AND (external_id IS NOT NULL))))
);

COMMENT ON TABLE public.principal_external_identities IS 'External identity bindings that connect principals to providers, channels, and login subjects.';

COMMENT ON COLUMN public.principal_external_identities.principal_uid IS 'Principal represented by this external identity.';

COMMENT ON COLUMN public.principal_external_identities.kind IS 'Identity shape: platform subject, channel actor, login subject, or outbound actor.';

COMMENT ON COLUMN public.principal_external_identities.provider IS 'Provider namespace for non-channel identities.';

COMMENT ON COLUMN public.principal_external_identities.adapter IS 'SignalsGateway adapter namespace for channel actor identities.';

COMMENT ON COLUMN public.principal_external_identities.channel_id IS 'Provider channel id when the identity belongs to a channel actor.';

COMMENT ON COLUMN public.principal_external_identities.external_id IS 'Provider supplied subject or actor identifier.';

COMMENT ON COLUMN public.principal_external_identities.verified_at IS 'Time this identity binding was last proven by the provider.';

COMMENT ON COLUMN public.principal_external_identities.metadata IS 'Provider-specific identity facts kept outside the stable contract.';

CREATE TABLE public.principal_group_external_bindings (
    provider text NOT NULL,
    external_kind public.principal_group_external_kind NOT NULL,
    external_id text NOT NULL,
    group_id uuid NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT principal_group_external_bindings_external_id_present CHECK ((length(btrim(external_id)) > 0)),
    CONSTRAINT principal_group_external_bindings_metadata_object CHECK ((jsonb_typeof(metadata) = 'object'::text)),
    CONSTRAINT principal_group_external_bindings_provider_format CHECK ((provider ~ '^[a-z][a-z0-9_-]*$'::text)),
    CONSTRAINT principal_group_external_bindings_provider_present CHECK ((length(btrim(provider)) > 0))
);

COMMENT ON TABLE public.principal_group_external_bindings IS 'Provider group bindings that synchronize or imply Ankole group membership.';

COMMENT ON COLUMN public.principal_group_external_bindings.provider IS 'External provider namespace for the group binding.';

COMMENT ON COLUMN public.principal_group_external_bindings.external_kind IS 'External group identity kind within the provider namespace.';

COMMENT ON COLUMN public.principal_group_external_bindings.external_id IS 'Provider supplied group identifier.';

COMMENT ON COLUMN public.principal_group_external_bindings.group_id IS 'Ankole authorization group represented by the external group.';

COMMENT ON COLUMN public.principal_group_external_bindings.metadata IS 'Provider-specific binding facts kept outside the stable contract.';

CREATE TABLE public.principal_group_memberships (
    principal_uid text NOT NULL,
    group_id uuid NOT NULL,
    inserted_at timestamp without time zone NOT NULL
);

COMMENT ON TABLE public.principal_group_memberships IS 'Explicit static group memberships.';

COMMENT ON COLUMN public.principal_group_memberships.principal_uid IS 'Principal that belongs to the group.';

COMMENT ON COLUMN public.principal_group_memberships.group_id IS 'Group receiving the principal membership.';

CREATE TABLE public.principal_groups (
    id uuid NOT NULL,
    name text NOT NULL,
    display_name text NOT NULL,
    domain public.principal_group_domain DEFAULT 'operator'::public.principal_group_domain NOT NULL,
    kind public.principal_group_kind DEFAULT 'static'::public.principal_group_kind NOT NULL,
    built_in boolean DEFAULT false NOT NULL,
    computed_condition text,
    description text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT principal_groups_computed_condition_by_kind CHECK ((((kind = 'static'::public.principal_group_kind) AND (computed_condition IS NULL)) OR ((kind = 'computed'::public.principal_group_kind) AND (computed_condition IS NOT NULL) AND (length(btrim(computed_condition)) > 0)))),
    CONSTRAINT principal_groups_computed_domain CHECK (((kind <> 'computed'::public.principal_group_kind) OR (domain = 'operator'::public.principal_group_domain))),
    CONSTRAINT principal_groups_display_name_present CHECK ((length(btrim(display_name)) > 0)),
    CONSTRAINT principal_groups_metadata_object CHECK ((jsonb_typeof(metadata) = 'object'::text)),
    CONSTRAINT principal_groups_name_lowercase CHECK ((name = lower(name))),
    CONSTRAINT principal_groups_name_present CHECK ((length(btrim(name)) > 0))
);

COMMENT ON TABLE public.principal_groups IS 'Principal groups that collect principals for grants, directories, or IM rooms.';

COMMENT ON COLUMN public.principal_groups.name IS 'Stable lowercase group name used by policy code and operators.';

COMMENT ON COLUMN public.principal_groups.display_name IS 'Human-readable group name for console and audit views.';

COMMENT ON COLUMN public.principal_groups.domain IS 'Product domain that owns the group membership semantics.';

COMMENT ON COLUMN public.principal_groups.kind IS 'Whether membership is explicitly stored or computed from a condition.';

COMMENT ON COLUMN public.principal_groups.built_in IS 'Marks groups created by Ankole rather than by an operator.';

COMMENT ON COLUMN public.principal_groups.computed_condition IS 'Condition expression that defines computed membership.';

COMMENT ON COLUMN public.principal_groups.description IS 'Operator-facing explanation of the group purpose.';

COMMENT ON COLUMN public.principal_groups.metadata IS 'Group metadata that is useful but not part of authorization matching.';

CREATE TABLE public.principals (
    uid text NOT NULL,
    type public.principal_type NOT NULL,
    status public.principal_status DEFAULT 'active'::public.principal_status NOT NULL,
    display_name text,
    avatar_url text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT principals_uid_lowercase CHECK ((uid = lower(uid))),
    CONSTRAINT principals_uid_present CHECK ((length(btrim(uid)) > 0))
);

COMMENT ON TABLE public.principals IS 'Canonical actors that can own state or receive authorization.';

COMMENT ON COLUMN public.principals.uid IS 'Stable lowercase principal identifier shared by humans and agents.';

COMMENT ON COLUMN public.principals.type IS 'Principal subtype used to route to the matching profile table.';

COMMENT ON COLUMN public.principals.status IS 'Lifecycle state used to disable access without deleting history.';

COMMENT ON COLUMN public.principals.display_name IS 'Operator-visible name for UI and audit surfaces.';

COMMENT ON COLUMN public.principals.avatar_url IS 'Optional avatar image URL for UI rendering.';

CREATE TABLE public.signal_gateway_ambient_judgments (
    actor_event_id uuid NOT NULL,
    agent_uid text NOT NULL,
    signal_channel_id text NOT NULL,
    decision text NOT NULL,
    reason text DEFAULT ''::text NOT NULL,
    asked_by_source_entry_id text,
    asked_by_state text,
    judged_until timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT signal_gateway_ambient_judgments_asked_by_state_check CHECK (((asked_by_state IS NULL) OR (asked_by_state = ANY (ARRAY['accepted'::text, 'degraded'::text])))),
    CONSTRAINT signal_gateway_ambient_judgments_decision_check CHECK ((decision = ANY (ARRAY['intervene'::text, 'silent'::text])))
);

CREATE SEQUENCE public.signal_gateway_attachment_id_seq
    START WITH 10000
    INCREMENT BY 1
    MINVALUE 10000
    MAXVALUE 9007199254740991
    CACHE 1;

CREATE TABLE public.signal_gateway_bindings (
    agent_uid text NOT NULL,
    name text NOT NULL,
    adapter text NOT NULL,
    config_ref text NOT NULL,
    filters jsonb DEFAULT '{}'::jsonb NOT NULL,
    unaddressed_group_message_policy public.signal_group_message_policy DEFAULT 'record_only'::public.signal_group_message_policy CONSTRAINT signal_gateway_bindings_unaddressed_group_message_poli_not_null NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    unavailable_reason text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    confidential_memory boolean DEFAULT false NOT NULL,
    CONSTRAINT signal_gateway_bindings_adapter_present CHECK ((length(btrim(adapter)) > 0)),
    CONSTRAINT signal_gateway_bindings_config_ref_present CHECK ((length(btrim(config_ref)) > 0)),
    CONSTRAINT signal_gateway_bindings_filters_object CHECK ((jsonb_typeof(filters) = 'object'::text)),
    CONSTRAINT signal_gateway_bindings_name_present CHECK ((length(btrim(name)) > 0))
);

COMMENT ON TABLE public.signal_gateway_bindings IS 'Per-agent SignalsGateway bindings to external input and output adapters.';

COMMENT ON COLUMN public.signal_gateway_bindings.agent_uid IS 'Agent principal that owns the binding.';

COMMENT ON COLUMN public.signal_gateway_bindings.name IS 'Agent-local binding name used in actor event and outbox keys.';

COMMENT ON COLUMN public.signal_gateway_bindings.adapter IS 'SignalsGateway adapter that knows how to read and write the provider.';

COMMENT ON COLUMN public.signal_gateway_bindings.config_ref IS 'Configuration reference used by the adapter at runtime.';

COMMENT ON COLUMN public.signal_gateway_bindings.filters IS 'Adapter-neutral binding filters applied before actor delivery.';

COMMENT ON COLUMN public.signal_gateway_bindings.unaddressed_group_message_policy IS 'Policy for group messages that do not directly address the agent.';

COMMENT ON COLUMN public.signal_gateway_bindings.enabled IS 'Whether this binding may accept or dispatch provider traffic.';

COMMENT ON COLUMN public.signal_gateway_bindings.unavailable_reason IS 'Operator-visible reason why an enabled binding cannot currently run.';

CREATE TABLE public.signal_gateway_channels (
    id text NOT NULL,
    kind public.signal_channel_kind DEFAULT 'unknown'::public.signal_channel_kind NOT NULL,
    reply_mode public.signal_reply_mode DEFAULT 'none'::public.signal_reply_mode NOT NULL,
    name text,
    visibility text,
    principal_group_id uuid,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    raw_payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    first_seen_at timestamp without time zone NOT NULL,
    last_seen_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    ambient_standing_orders text,
    ambient_standing_orders_set_by text,
    ambient_standing_orders_updated_at timestamp without time zone,
    ambient_judged_until timestamp without time zone,
    CONSTRAINT signal_gateway_channels_id_present CHECK ((length(btrim(id)) > 0)),
    CONSTRAINT signal_gateway_channels_metadata_object CHECK ((jsonb_typeof(metadata) = 'object'::text)),
    CONSTRAINT signal_gateway_channels_principal_group_kind CHECK (((principal_group_id IS NULL) OR (kind = 'im_group'::public.signal_channel_kind))),
    CONSTRAINT signal_gateway_channels_raw_payload_object CHECK ((jsonb_typeof(raw_payload) = 'object'::text))
);

COMMENT ON TABLE public.signal_gateway_channels IS 'Provider channels observed by SignalsGateway.';

COMMENT ON COLUMN public.signal_gateway_channels.id IS 'Stable Ankole channel id derived from provider channel identity.';

COMMENT ON COLUMN public.signal_gateway_channels.kind IS 'Channel category used for policy and rendering.';

COMMENT ON COLUMN public.signal_gateway_channels.reply_mode IS 'Whether replies target the whole channel or a specific entry.';

COMMENT ON COLUMN public.signal_gateway_channels.name IS 'Provider or operator supplied channel name.';

COMMENT ON COLUMN public.signal_gateway_channels.visibility IS 'Provider visibility hint such as private, public, or shared.';

COMMENT ON COLUMN public.signal_gateway_channels.principal_group_id IS 'Principal group that represents IM group membership when this channel is an IM group.';

COMMENT ON COLUMN public.signal_gateway_channels.metadata IS 'Normalized provider channel facts outside the stable contract.';

COMMENT ON COLUMN public.signal_gateway_channels.raw_payload IS 'Last provider payload kept for recovery and adapter diagnostics.';

COMMENT ON COLUMN public.signal_gateway_channels.first_seen_at IS 'Time this channel was first observed by the gateway.';

COMMENT ON COLUMN public.signal_gateway_channels.last_seen_at IS 'Time this channel was most recently observed by the gateway.';

CREATE TABLE public.signal_gateway_entries (
    document_id text NOT NULL,
    signal_channel_id text,
    source_entry_id text NOT NULL,
    provider_thread_id text,
    text text,
    rich_content jsonb,
    attachments jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    links jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    author jsonb DEFAULT '{}'::jsonb NOT NULL,
    mentions jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    raw_payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    provider_time timestamp without time zone,
    reactions jsonb DEFAULT '{}'::jsonb NOT NULL,
    raw_reaction_keys jsonb DEFAULT '{}'::jsonb NOT NULL,
    content_hash text,
    first_seen_at timestamp without time zone NOT NULL,
    last_seen_at timestamp without time zone NOT NULL,
    ai_message_id uuid,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    reply_to_source_entry_id text,
    CONSTRAINT signal_gateway_entries_document_id_present CHECK ((length(btrim(document_id)) > 0)),
    CONSTRAINT signal_gateway_entries_source_entry_id_present CHECK ((length(btrim(source_entry_id)) > 0))
);

COMMENT ON TABLE public.signal_gateway_entries IS 'Provider entries mirrored for gateway policy, recall, and reply targeting.';

COMMENT ON COLUMN public.signal_gateway_entries.document_id IS 'Search and recall document id for this entry.';

COMMENT ON COLUMN public.signal_gateway_entries.signal_channel_id IS 'Channel that contains this provider entry.';

COMMENT ON COLUMN public.signal_gateway_entries.source_entry_id IS 'Provider supplied entry or message identifier within the channel.';

COMMENT ON COLUMN public.signal_gateway_entries.provider_thread_id IS 'Provider thread that contains this entry, when applicable.';

COMMENT ON COLUMN public.signal_gateway_entries.text IS 'Plain text extracted from the provider entry when available.';

COMMENT ON COLUMN public.signal_gateway_entries.rich_content IS 'Structured content that carries information beyond plain text.';

COMMENT ON COLUMN public.signal_gateway_entries.attachments IS 'Provider attachments normalized for storage and worker handoff.';

COMMENT ON COLUMN public.signal_gateway_entries.links IS 'Links extracted or normalized from the entry.';

COMMENT ON COLUMN public.signal_gateway_entries.author IS 'Provider author facts for the entry.';

COMMENT ON COLUMN public.signal_gateway_entries.mentions IS 'Mention facts normalized from the entry.';

COMMENT ON COLUMN public.signal_gateway_entries.metadata IS 'Gateway-owned metadata outside the durable content contract.';

COMMENT ON COLUMN public.signal_gateway_entries.raw_payload IS 'Provider payload kept for adapter diagnostics and recovery.';

COMMENT ON COLUMN public.signal_gateway_entries.provider_time IS 'Timestamp assigned by the provider for the entry.';

COMMENT ON COLUMN public.signal_gateway_entries.reactions IS 'Normalized reaction counts and actors.';

COMMENT ON COLUMN public.signal_gateway_entries.raw_reaction_keys IS 'Provider reaction keys retained before normalization.';

COMMENT ON COLUMN public.signal_gateway_entries.content_hash IS 'Hash of the durable content projection.';

COMMENT ON COLUMN public.signal_gateway_entries.first_seen_at IS 'Time this entry was first observed by the gateway.';

COMMENT ON COLUMN public.signal_gateway_entries.last_seen_at IS 'Time this entry was most recently observed by the gateway.';

COMMENT ON COLUMN public.signal_gateway_entries.ai_message_id IS 'Stored ai_gateway_messages.id when this entry mirrors an outbound final AI reply.';

CREATE TABLE public.signal_gateway_inbound_batches (
    id uuid NOT NULL,
    agent_uid text NOT NULL,
    binding_name text NOT NULL,
    session_id text NOT NULL,
    signal_channel_id text NOT NULL,
    provider_thread_id text DEFAULT ''::text NOT NULL,
    batch_state text DEFAULT 'open'::text NOT NULL,
    mode text DEFAULT 'neutral'::text NOT NULL,
    policy text NOT NULL,
    requester_sender_key text,
    entries jsonb DEFAULT '[]'::jsonb NOT NULL,
    available_at timestamp without time zone NOT NULL,
    hard_cap_at timestamp without time zone,
    batch_revision integer DEFAULT 0 NOT NULL,
    outcome text,
    finalized_at timestamp without time zone,
    actor_event_id uuid,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    reply_to_source_entry_id text,
    CONSTRAINT inbound_batches_entries_array CHECK ((jsonb_typeof(entries) = 'array'::text)),
    CONSTRAINT inbound_batches_mode_check CHECK ((mode = ANY (ARRAY['neutral'::text, 'addressed'::text]))),
    CONSTRAINT inbound_batches_outcome_check CHECK (((outcome IS NULL) OR (outcome = ANY (ARRAY['addressed'::text, 'ambient'::text, 'no_actor_event'::text, 'canceled'::text])))),
    CONSTRAINT inbound_batches_policy_check CHECK ((policy = ANY (ARRAY['ignore'::text, 'record_only'::text, 'may_intervene'::text]))),
    CONSTRAINT inbound_batches_state_check CHECK ((batch_state = ANY (ARRAY['open'::text, 'finalized'::text, 'canceled'::text])))
);

CREATE TABLE public.signal_gateway_input_tombstones (
    agent_uid text NOT NULL,
    binding_name text NOT NULL,
    signal_channel_id text NOT NULL,
    source_entry_id text NOT NULL,
    tombstoned_until timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);

COMMENT ON TABLE public.signal_gateway_input_tombstones IS 'Temporary receive-side tombstones that suppress already-handled or deleted provider entries.';

COMMENT ON COLUMN public.signal_gateway_input_tombstones.agent_uid IS 'Agent principal protected by the tombstone.';

COMMENT ON COLUMN public.signal_gateway_input_tombstones.binding_name IS 'Binding where the provider entry was observed.';

COMMENT ON COLUMN public.signal_gateway_input_tombstones.signal_channel_id IS 'Channel containing the tombstoned provider entry.';

COMMENT ON COLUMN public.signal_gateway_input_tombstones.source_entry_id IS 'Provider entry suppressed until the tombstone expires.';

COMMENT ON COLUMN public.signal_gateway_input_tombstones.tombstoned_until IS 'Time after which this tombstone can be removed.';

CREATE TABLE public.signal_gateway_outbox_entries (
    agent_uid text NOT NULL,
    binding_name text NOT NULL,
    outbound_key text NOT NULL,
    operation public.signal_gateway_outbox_operation NOT NULL,
    status public.signal_gateway_outbox_status DEFAULT 'created'::public.signal_gateway_outbox_status NOT NULL,
    signal_channel_id text,
    provider_thread_id text,
    reply_to_source_entry_id text,
    target_source_entry_id text,
    created_source_entry_id text,
    source_actor_event_id uuid,
    ai_message_id uuid,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    fallback_visible_text text,
    idempotency_key text,
    attempt_count integer DEFAULT 0 NOT NULL,
    max_attempts integer DEFAULT 10 NOT NULL,
    last_attempted_at timestamp without time zone,
    last_error jsonb DEFAULT '{}'::jsonb NOT NULL,
    platform_send_started_at timestamp without time zone,
    next_attempt_at timestamp without time zone,
    recovery_state jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    delivery_class text DEFAULT 'generic'::text NOT NULL,
    CONSTRAINT signal_gateway_outbox_entries_attempts_non_negative CHECK (((attempt_count >= 0) AND (max_attempts > 0))),
    CONSTRAINT signal_gateway_outbox_entries_delivery_class_check CHECK ((delivery_class = ANY (ARRAY['generic'::text, 'durable_ai_reply'::text]))),
    CONSTRAINT signal_gateway_outbox_entries_last_error_object CHECK ((jsonb_typeof(last_error) = 'object'::text)),
    CONSTRAINT signal_gateway_outbox_entries_payload_object CHECK ((jsonb_typeof(payload) = 'object'::text)),
    CONSTRAINT signal_gateway_outbox_entries_recovery_state_object CHECK ((jsonb_typeof(recovery_state) = 'object'::text))
);

COMMENT ON TABLE public.signal_gateway_outbox_entries IS 'Durable provider-visible side-effect intents committed by actor events.';

COMMENT ON COLUMN public.signal_gateway_outbox_entries.agent_uid IS 'Agent principal that owns the outbound side effect.';

COMMENT ON COLUMN public.signal_gateway_outbox_entries.binding_name IS 'Output binding that should dispatch the side effect.';

COMMENT ON COLUMN public.signal_gateway_outbox_entries.outbound_key IS 'Agent-provided idempotency key for the side effect.';

COMMENT ON COLUMN public.signal_gateway_outbox_entries.operation IS 'Provider-visible operation requested by the actor.';

COMMENT ON COLUMN public.signal_gateway_outbox_entries.status IS 'Dispatch state for retry and recovery.';

COMMENT ON COLUMN public.signal_gateway_outbox_entries.signal_channel_id IS 'Provider channel targeted by the side effect.';

COMMENT ON COLUMN public.signal_gateway_outbox_entries.provider_thread_id IS 'Provider thread targeted by the side effect.';

COMMENT ON COLUMN public.signal_gateway_outbox_entries.reply_to_source_entry_id IS 'Provider entry that the side effect replies from.';

COMMENT ON COLUMN public.signal_gateway_outbox_entries.target_source_entry_id IS 'Provider entry targeted by edit, delete, or reaction operations.';

COMMENT ON COLUMN public.signal_gateway_outbox_entries.created_source_entry_id IS 'Provider id assigned to a successfully created outbound entry.';

COMMENT ON COLUMN public.signal_gateway_outbox_entries.source_actor_event_id IS 'Actor event that caused this side effect.';

COMMENT ON COLUMN public.signal_gateway_outbox_entries.ai_message_id IS 'Stored ai_gateway_messages.id represented by this side effect.';

COMMENT ON COLUMN public.signal_gateway_outbox_entries.payload IS 'Operation-specific payload to send through the adapter.';

COMMENT ON COLUMN public.signal_gateway_outbox_entries.fallback_visible_text IS 'Plain text rendering used when rich content needs a fallback.';

COMMENT ON COLUMN public.signal_gateway_outbox_entries.idempotency_key IS 'Provider-facing idempotency token when the adapter supports one.';

COMMENT ON COLUMN public.signal_gateway_outbox_entries.attempt_count IS 'Number of dispatch attempts already made.';

COMMENT ON COLUMN public.signal_gateway_outbox_entries.max_attempts IS 'Retry ceiling before the row stops scheduling attempts.';

COMMENT ON COLUMN public.signal_gateway_outbox_entries.last_attempted_at IS 'Time of the most recent dispatch attempt.';

COMMENT ON COLUMN public.signal_gateway_outbox_entries.last_error IS 'Last adapter or provider error captured for operators.';

COMMENT ON COLUMN public.signal_gateway_outbox_entries.platform_send_started_at IS 'Time the provider send call started for in-flight recovery.';

COMMENT ON COLUMN public.signal_gateway_outbox_entries.next_attempt_at IS 'Next time the dispatcher may retry a failed send.';

COMMENT ON COLUMN public.signal_gateway_outbox_entries.recovery_state IS 'Adapter breadcrumbs used to reconcile unknown send outcomes.';

CREATE TABLE public.signal_gateway_webhook_endpoints (
    id uuid NOT NULL,
    token_digest text NOT NULL,
    agent_uid text NOT NULL,
    binding_name text NOT NULL,
    session_id text NOT NULL,
    signal_channel_id text,
    provider_thread_id text,
    source_actor_event_id uuid,
    source_entry_id text,
    source_provenance jsonb DEFAULT '{}'::jsonb NOT NULL,
    label text NOT NULL,
    mode text NOT NULL,
    status text NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    fired_at timestamp without time zone,
    cancelled_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    automation_job_id bigint,
    CONSTRAINT signal_gateway_webhook_endpoints_binding_name_present CHECK ((length(btrim(binding_name)) > 0)),
    CONSTRAINT signal_gateway_webhook_endpoints_label_present CHECK ((length(btrim(label)) > 0)),
    CONSTRAINT signal_gateway_webhook_endpoints_mode_check CHECK ((mode = ANY (ARRAY['one_shot'::text, 'standing'::text]))),
    CONSTRAINT signal_gateway_webhook_endpoints_session_id_present CHECK ((length(btrim(session_id)) > 0)),
    CONSTRAINT signal_gateway_webhook_endpoints_source_provenance_object CHECK ((jsonb_typeof(source_provenance) = 'object'::text)),
    CONSTRAINT signal_gateway_webhook_endpoints_status_check CHECK ((((mode = 'one_shot'::text) AND (status = ANY (ARRAY['armed'::text, 'fired'::text, 'expired'::text, 'cancelled'::text]))) OR ((mode = 'standing'::text) AND (status = ANY (ARRAY['active'::text, 'expired'::text, 'cancelled'::text]))))),
    CONSTRAINT signal_gateway_webhook_endpoints_token_digest_length CHECK ((length(token_digest) = 43))
);

COMMENT ON TABLE public.signal_gateway_webhook_endpoints IS 'Capability URLs that route external task receipts to one Agent session.';

ALTER TABLE public.background_agent_jobs ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.subagent_delegations_id_seq
    START WITH 1000
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY public.oban_jobs ALTER COLUMN id SET DEFAULT nextval('public.oban_jobs_id_seq'::regclass);

ALTER TABLE ONLY public.actor_cron_schedules
    ADD CONSTRAINT actor_cron_schedules_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.actor_event_deliveries
    ADD CONSTRAINT actor_event_deliveries_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.actor_events
    ADD CONSTRAINT actor_events_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.actor_scheduled_events
    ADD CONSTRAINT actor_scheduled_events_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.actor_session_activations
    ADD CONSTRAINT actor_session_activations_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.actor_session_worker_assignments
    ADD CONSTRAINT actor_session_worker_assignments_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.actor_session_workspaces
    ADD CONSTRAINT actor_session_workspaces_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.agent_computer_workers
    ADD CONSTRAINT agent_computer_workers_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.agent_library_container_entries
    ADD CONSTRAINT agent_library_container_entries_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.agent_plugin_overrides
    ADD CONSTRAINT agent_plugin_overrides_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.agent_skill_overlays
    ADD CONSTRAINT agent_skill_overlays_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.agent_skills
    ADD CONSTRAINT agent_skills_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT agents_pkey PRIMARY KEY (uid);

ALTER TABLE public.agents
    ADD CONSTRAINT agents_uid_agent_home_safe CHECK ((uid ~ '^[a-z0-9][a-z0-9._-]{0,95}$'::text)) NOT VALID;

ALTER TABLE ONLY public.ai_gateway_artifacts
    ADD CONSTRAINT ai_gateway_artifacts_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.ai_gateway_compaction_artifacts
    ADD CONSTRAINT ai_gateway_compaction_artifacts_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.ai_gateway_conversations
    ADD CONSTRAINT ai_gateway_conversations_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.ai_gateway_messages
    ADD CONSTRAINT ai_gateway_messages_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.ai_gateway_providers
    ADD CONSTRAINT ai_gateway_providers_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.automation_job_runs
    ADD CONSTRAINT automation_job_runs_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.automation_jobs
    ADD CONSTRAINT automation_jobs_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.background_agent_job_turn_trajectory_groups
    ADD CONSTRAINT background_agent_job_turn_trajectory_groups_pkey PRIMARY KEY (turn_id, "position");

ALTER TABLE ONLY public.background_agent_job_turns
    ADD CONSTRAINT background_agent_job_turns_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.background_agent_jobs
    ADD CONSTRAINT background_agent_jobs_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.brain_audit_log
    ADD CONSTRAINT brain_audit_log_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.brain_block_citations
    ADD CONSTRAINT brain_block_citations_pkey PRIMARY KEY (block_id, document_id);

ALTER TABLE ONLY public.brain_cursors
    ADD CONSTRAINT brain_cursors_pkey PRIMARY KEY (scope_kind, scope_key);

ALTER TABLE ONLY public.brain_entries
    ADD CONSTRAINT brain_entries_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.brain_entry_blocks
    ADD CONSTRAINT brain_entry_blocks_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.brain_entry_relations
    ADD CONSTRAINT brain_entry_relations_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.brain_episodes
    ADD CONSTRAINT brain_episodes_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.brain_retained_sources
    ADD CONSTRAINT brain_retained_sources_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.human_users
    ADD CONSTRAINT human_users_pkey PRIMARY KEY (principal_uid);

ALTER TABLE ONLY public.library_builtin_sync_states
    ADD CONSTRAINT library_builtin_sync_states_pkey PRIMARY KEY (name);

ALTER TABLE public.oban_jobs
    ADD CONSTRAINT non_negative_priority CHECK ((priority >= 0)) NOT VALID;

ALTER TABLE ONLY public.oban_jobs
    ADD CONSTRAINT oban_jobs_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.oban_peers
    ADD CONSTRAINT oban_peers_pkey PRIMARY KEY (name);

ALTER TABLE ONLY public.permission_grants
    ADD CONSTRAINT permission_grants_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.principal_external_identities
    ADD CONSTRAINT principal_external_identities_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.principal_group_external_bindings
    ADD CONSTRAINT principal_group_external_bindings_pkey PRIMARY KEY (provider, external_kind, external_id);

ALTER TABLE ONLY public.principal_group_memberships
    ADD CONSTRAINT principal_group_memberships_pkey PRIMARY KEY (principal_uid, group_id);

ALTER TABLE ONLY public.principal_groups
    ADD CONSTRAINT principal_groups_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.principals
    ADD CONSTRAINT principals_pkey PRIMARY KEY (uid);

ALTER TABLE ONLY public.signal_gateway_ambient_judgments
    ADD CONSTRAINT signal_gateway_ambient_judgments_pkey PRIMARY KEY (actor_event_id);

ALTER TABLE ONLY public.signal_gateway_bindings
    ADD CONSTRAINT signal_gateway_bindings_pkey PRIMARY KEY (agent_uid, name);

ALTER TABLE ONLY public.signal_gateway_channels
    ADD CONSTRAINT signal_gateway_channels_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.signal_gateway_entries
    ADD CONSTRAINT signal_gateway_entries_pkey PRIMARY KEY (document_id);

ALTER TABLE ONLY public.signal_gateway_inbound_batches
    ADD CONSTRAINT signal_gateway_inbound_batches_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.signal_gateway_input_tombstones
    ADD CONSTRAINT signal_gateway_input_tombstones_pkey PRIMARY KEY (agent_uid, binding_name, signal_channel_id, source_entry_id);

ALTER TABLE ONLY public.signal_gateway_outbox_entries
    ADD CONSTRAINT signal_gateway_outbox_entries_pkey PRIMARY KEY (agent_uid, binding_name, outbound_key);

ALTER TABLE ONLY public.signal_gateway_webhook_endpoints
    ADD CONSTRAINT signal_gateway_webhook_endpoints_pkey PRIMARY KEY (id);

CREATE INDEX actor_cron_schedules_actor_status_index ON public.actor_cron_schedules USING btree (agent_uid, session_id, status);

CREATE UNIQUE INDEX actor_cron_schedules_agent_name_index ON public.actor_cron_schedules USING btree (agent_uid, session_id, name) WHERE (status <> 'deleted'::text);

CREATE INDEX actor_cron_schedules_automation_job_index ON public.actor_cron_schedules USING btree (automation_job_id) WHERE (automation_job_id IS NOT NULL);

CREATE INDEX actor_cron_schedules_due_index ON public.actor_cron_schedules USING btree (status, next_fire_at);

CREATE UNIQUE INDEX actor_cron_schedules_idempotency_index ON public.actor_cron_schedules USING btree (agent_uid, session_id, idempotency_key);

CREATE UNIQUE INDEX actor_event_deliveries_event_attempt_index ON public.actor_event_deliveries USING btree (actor_event_id, attempt_no);

CREATE UNIQUE INDEX actor_event_deliveries_live_event_index ON public.actor_event_deliveries USING btree (actor_event_id) WHERE (state = ANY (ARRAY['created'::text, 'sent'::text, 'accepted'::text]));

CREATE INDEX actor_event_deliveries_state_index ON public.actor_event_deliveries USING btree (agent_uid, session_id, state, queue_sequence);

CREATE INDEX actor_event_deliveries_worker_state_index ON public.actor_event_deliveries USING btree (worker_id, state);

CREATE UNIQUE INDEX actor_events_queue_sequence_index ON public.actor_events USING btree (agent_uid, session_id, queue_sequence);

CREATE INDEX actor_events_ready_index ON public.actor_events USING btree (agent_uid, session_id, available_at, queue_sequence) WHERE ((input_state = 'open'::text) AND (completed_at IS NULL));

CREATE INDEX actor_events_recoverable_reply_preview_index ON public.actor_events USING btree (completed_at) WHERE (reply_preview_checkpoint IS NOT NULL);

CREATE INDEX actor_events_reply_preview_cleanup_at_index ON public.actor_events USING btree (reply_preview_cleanup_at) WHERE (reply_preview_cleanup_at IS NOT NULL);

CREATE INDEX actor_events_signal_entry_index ON public.actor_events USING btree (agent_uid, binding_name, signal_channel_id, source_entry_id);

CREATE UNIQUE INDEX actor_events_signal_idempotency_index ON public.actor_events USING btree (agent_uid, binding_name, source_event_id);

CREATE INDEX actor_scheduled_events_actor_due_index ON public.actor_scheduled_events USING btree (agent_uid, session_id, status, due_at);

CREATE INDEX actor_scheduled_events_actor_event_index ON public.actor_scheduled_events USING btree (actor_event_id);

CREATE INDEX actor_scheduled_events_automation_job_index ON public.actor_scheduled_events USING btree (automation_job_id) WHERE (automation_job_id IS NOT NULL);

CREATE INDEX actor_scheduled_events_automation_job_run_index ON public.actor_scheduled_events USING btree (automation_job_run_id) WHERE (automation_job_run_id IS NOT NULL);

CREATE UNIQUE INDEX actor_scheduled_events_cron_slot_index ON public.actor_scheduled_events USING btree (cron_schedule_id, cron_fire_slot_at) WHERE ((cron_schedule_id IS NOT NULL) AND (kind = 'cron_fire'::text) AND (COALESCE((wake_payload ->> 'trigger'::text), 'scheduled'::text) = 'scheduled'::text) AND (status <> 'cancelled'::text));

CREATE INDEX actor_scheduled_events_due_index ON public.actor_scheduled_events USING btree (status, due_at);

CREATE UNIQUE INDEX actor_scheduled_events_idempotency_index ON public.actor_scheduled_events USING btree (kind, agent_uid, session_id, idempotency_key);

CREATE INDEX actor_scheduled_events_oban_job_index ON public.actor_scheduled_events USING btree (oban_job_id);

CREATE UNIQUE INDEX actor_scheduled_events_one_live_recurring_index ON public.actor_scheduled_events USING btree (cron_schedule_id) WHERE ((cron_schedule_id IS NOT NULL) AND (kind = 'cron_fire'::text) AND (COALESCE((wake_payload ->> 'trigger'::text), 'scheduled'::text) = 'scheduled'::text) AND (status = ANY (ARRAY['scheduled'::text, 'firing'::text])));

CREATE INDEX actor_scheduled_events_origin_ai_message_index ON public.actor_scheduled_events USING btree (origin_ai_message_id) WHERE (origin_ai_message_id IS NOT NULL);

CREATE INDEX actor_scheduled_events_source_actor_event_index ON public.actor_scheduled_events USING btree (source_actor_event_id) WHERE (source_actor_event_id IS NOT NULL);

CREATE UNIQUE INDEX actor_session_activations_activation_uid_index ON public.actor_session_activations USING btree (activation_uid);

CREATE UNIQUE INDEX actor_session_activations_live_actor_index ON public.actor_session_activations USING btree (agent_uid, session_id) WHERE (status = ANY (ARRAY['starting'::text, 'active'::text, 'draining'::text]));

CREATE INDEX actor_session_activations_status_lease_deadline_index ON public.actor_session_activations USING btree (status, lease_expires_at) WHERE (status = ANY (ARRAY['starting'::text, 'active'::text, 'draining'::text]));

CREATE UNIQUE INDEX actor_session_worker_assignments_live_actor_index ON public.actor_session_worker_assignments USING btree (agent_uid, session_id) WHERE (status = ANY (ARRAY['assigned'::text, 'draining'::text]));

CREATE INDEX actor_session_worker_assignments_worker_index ON public.actor_session_worker_assignments USING btree (worker_id, status);

CREATE UNIQUE INDEX actor_session_workspaces_actor_index ON public.actor_session_workspaces USING btree (agent_uid, session_id);

CREATE UNIQUE INDEX agent_computer_worker_envs_scope_name_unique ON public.agent_computer_worker_envs USING btree (scope, name);

CREATE INDEX agent_computer_workers_status_heartbeat_deadline_index ON public.agent_computer_workers USING btree (status, last_worker_heartbeat_at) WHERE (status = ANY (ARRAY['ready'::text, 'draining'::text]));

CREATE INDEX agent_computer_workers_status_stopped_deadline_index ON public.agent_computer_workers USING btree (status, stopped_at) WHERE (status = ANY (ARRAY['stale'::text, 'stopped'::text]));

CREATE UNIQUE INDEX agent_computer_workers_transport_route_index ON public.agent_computer_workers USING btree (transport_route) WHERE (transport_route IS NOT NULL);

CREATE UNIQUE INDEX agent_computer_workers_worker_id_index ON public.agent_computer_workers USING btree (worker_id);

CREATE UNIQUE INDEX agent_library_container_entries_active_path_index ON public.agent_library_container_entries USING btree (agent_uid, path) WHERE (deleted_at IS NULL);

CREATE UNIQUE INDEX agent_plugin_overrides_agent_plugin_index ON public.agent_plugin_overrides USING btree (agent_uid, agent_plugin_id);

CREATE UNIQUE INDEX agent_skill_overlays_active_skill_index ON public.agent_skill_overlays USING btree (agent_uid, skill_name) WHERE (deleted_at IS NULL);

CREATE INDEX agent_skills_agent_enabled_override_index ON public.agent_skills USING btree (agent_uid, enabled_override) WHERE (enabled_override IS NOT NULL);

CREATE UNIQUE INDEX agent_skills_agent_skill_index ON public.agent_skills USING btree (agent_uid, skill_name);

CREATE INDEX agents_ai_agent_model_provider_ids_index ON public.agents USING gin (jsonb_path_query_array(options, '$."ai_agent"."models".*."provider_id"'::jsonpath) jsonb_path_ops);

CREATE INDEX agents_created_by_principal_uid_index ON public.agents USING btree (created_by_principal_uid);

CREATE INDEX ai_gateway_artifacts_expiry_index ON public.ai_gateway_artifacts USING btree (expires_at) WHERE (expires_at IS NOT NULL);

CREATE INDEX ai_gateway_artifacts_message_index ON public.ai_gateway_artifacts USING btree (message_id) WHERE (message_id IS NOT NULL);

CREATE INDEX ai_gateway_artifacts_owner_list_index ON public.ai_gateway_artifacts USING btree (subject_uid, kind, inserted_at, id);

CREATE INDEX ai_gateway_compaction_artifacts_owner_index ON public.ai_gateway_compaction_artifacts USING btree (subject_uid, conversation_id);

CREATE UNIQUE INDEX ai_gateway_conversations_active_key_index ON public.ai_gateway_conversations USING btree (subject_uid, conversation_key) WHERE (ended_at IS NULL);

CREATE INDEX ai_gateway_messages_conversation_index ON public.ai_gateway_messages USING btree (subject_uid, conversation_id);

CREATE INDEX ai_gateway_messages_generating_deadline_index ON public.ai_gateway_messages USING btree (status, type, updated_at) WHERE ((status = 'generating'::text) AND (type = 'message'::text));

CREATE INDEX ai_gateway_messages_previous_message_id_index ON public.ai_gateway_messages USING btree (previous_message_id) WHERE (previous_message_id IS NOT NULL);

CREATE UNIQUE INDEX ai_gateway_messages_tool_result_journal_key_index ON public.ai_gateway_messages USING btree (((metadata ->> 'tool_result_idempotency_key'::text))) WHERE (metadata ? 'tool_result_idempotency_key'::text);

CREATE INDEX ai_gateway_providers_active_index ON public.ai_gateway_providers USING btree (provider_id) WHERE (disabled_at IS NULL);

CREATE UNIQUE INDEX ai_gateway_providers_provider_id_index ON public.ai_gateway_providers USING btree (provider_id);

CREATE INDEX ai_gateway_providers_provider_kind_index ON public.ai_gateway_providers USING btree (provider_kind);

CREATE UNIQUE INDEX app_configurations_scope_key_unique ON public.app_configurations USING btree (scope, key);

CREATE INDEX automation_job_runs_status_index ON public.automation_job_runs USING btree (status, inserted_at) WHERE (status = ANY (ARRAY['queued'::text, 'running'::text]));

CREATE INDEX automation_job_runs_timeline_index ON public.automation_job_runs USING btree (automation_job_id, inserted_at, id);

CREATE INDEX automation_jobs_owner_status_index ON public.automation_jobs USING btree (agent_uid, owner_session_id, status, id);

CREATE UNIQUE INDEX background_agent_job_turn_trajectory_groups_item_index ON public.background_agent_job_turn_trajectory_groups USING btree (turn_id, item_key);

CREATE UNIQUE INDEX background_agent_job_turns_runtime_turn_index ON public.background_agent_job_turns USING btree (job_id, runtime_turn_id);

CREATE INDEX background_agent_job_turns_stuck_deadline_index ON public.background_agent_job_turns USING btree (status, updated_at) WHERE (status = 'in_progress'::text);

CREATE INDEX background_agent_job_turns_timeline_index ON public.background_agent_job_turns USING btree (job_id, attempt, started_at, id);

CREATE INDEX background_agent_jobs_agent_channel_queued_index ON public.background_agent_jobs USING btree (agent_uid, ((reply_route ->> 'signal_channel_id'::text)), queued_at DESC);

CREATE INDEX background_agent_jobs_agent_owner_session_index ON public.background_agent_jobs USING btree (agent_uid, owner_session_id);

CREATE INDEX background_agent_jobs_agent_status_index ON public.background_agent_jobs USING btree (agent_uid, status);

CREATE INDEX background_agent_jobs_agent_status_queued_index ON public.background_agent_jobs USING btree (agent_uid, status, queued_at DESC);

CREATE UNIQUE INDEX background_agent_jobs_continued_from_job_index ON public.background_agent_jobs USING btree (continued_from_job_id) WHERE (continued_from_job_id IS NOT NULL);

CREATE INDEX background_agent_jobs_running_worker_route_index ON public.background_agent_jobs USING btree (((metadata ->> 'worker_route'::text))) WHERE (status = ANY (ARRAY['running'::text, 'waiting_on_user'::text]));

CREATE UNIQUE INDEX background_agent_jobs_source_tool_call_index ON public.background_agent_jobs USING btree (agent_uid, owner_session_id, source_tool_call_id) WHERE (source_tool_call_id IS NOT NULL);

CREATE INDEX background_agent_jobs_workspace_owner_index ON public.background_agent_jobs USING btree (workspace_owner_job_id);

CREATE INDEX brain_audit_log_actor_time_index ON public.brain_audit_log USING btree (actor_kind, actor_uid, inserted_at);

CREATE INDEX brain_audit_log_entry_time_index ON public.brain_audit_log USING btree (entry_id, inserted_at);

CREATE INDEX brain_audit_log_owner_store_time_index ON public.brain_audit_log USING btree (owner_uid, store_key, inserted_at);

CREATE INDEX brain_block_citations_document_id_index ON public.brain_block_citations USING btree (document_id);

CREATE INDEX brain_entries_bm25_index ON public.brain_entries USING bm25 (id, ((search_text)::pdb.jieba)) WITH (key_field=id);

CREATE UNIQUE INDEX brain_entries_channel_identity_index ON public.brain_entries USING btree (owner_uid, store_key, ((properties ->> 'channel_id'::text))) WHERE ((properties ? 'channel_id'::text) AND (length(btrim((properties ->> 'channel_id'::text))) > 0));

CREATE UNIQUE INDEX brain_entries_owner_store_name_index ON public.brain_entries USING btree (owner_uid, store_key, name);

CREATE INDEX brain_entries_owner_store_type_index ON public.brain_entries USING btree (owner_uid, store_key, type);

CREATE UNIQUE INDEX brain_entries_scope_identity_index ON public.brain_entries USING btree (id, owner_uid, store_key);

CREATE UNIQUE INDEX brain_entries_self_curation_guide_index ON public.brain_entries USING btree (owner_uid) WHERE ((store_key = 'self'::text) AND (type = 'brain_curation_guide'::text));

CREATE UNIQUE INDEX brain_entries_self_pinned_memo_index ON public.brain_entries USING btree (owner_uid) WHERE ((store_key = 'self'::text) AND (type = 'agent_system_pinned_memo'::text));

CREATE UNIQUE INDEX brain_entries_source_mirror_document_index ON public.brain_entries USING btree (((properties ->> 'source_document_id'::text))) WHERE ((properties ->> 'source_mirror'::text) = 'true'::text);

CREATE INDEX brain_entry_blocks_author_kind_index ON public.brain_entry_blocks USING btree (author_kind);

CREATE INDEX brain_entry_blocks_bm25_index ON public.brain_entry_blocks USING bm25 (id, ((body)::pdb.jieba)) WITH (key_field=id);

CREATE INDEX brain_entry_blocks_embedding_hnsw_index ON public.brain_entry_blocks USING hnsw (((public.subvector(embedding, 1, 4000))::public.halfvec(4000)) public.halfvec_cosine_ops);

CREATE INDEX brain_entry_blocks_embedding_state_index ON public.brain_entry_blocks USING btree (embedding_state);

CREATE UNIQUE INDEX brain_entry_blocks_entry_position_index ON public.brain_entry_blocks USING btree (entry_id, "position");

CREATE INDEX brain_entry_blocks_owner_store_index ON public.brain_entry_blocks USING btree (owner_uid, store_key);

CREATE INDEX brain_entry_relations_owner_store_index ON public.brain_entry_relations USING btree (owner_uid, store_key);

CREATE INDEX brain_entry_relations_target_index ON public.brain_entry_relations USING btree (target_entry_id);

CREATE UNIQUE INDEX brain_entry_relations_unique_edge_index ON public.brain_entry_relations USING btree (source_entry_id, predicate, target_entry_id);

CREATE INDEX brain_episodes_channel_ended_at_index ON public.brain_episodes USING btree (signal_channel_id, ended_at);

CREATE INDEX brain_episodes_embedding_hnsw_index ON public.brain_episodes USING hnsw (((public.subvector(embedding, 1, 4000))::public.halfvec(4000)) public.halfvec_cosine_ops);

CREATE INDEX brain_episodes_embedding_state_index ON public.brain_episodes USING btree (embedding_state);

CREATE INDEX brain_episodes_source_entry_ids_gin_index ON public.brain_episodes USING gin (source_entry_ids);

CREATE UNIQUE INDEX brain_retained_sources_connector_locator_index ON public.brain_retained_sources USING btree (connector_id, origin_locator) WHERE (capture_method <> 'file'::text);

CREATE UNIQUE INDEX brain_retained_sources_document_id_index ON public.brain_retained_sources USING btree (document_id);

CREATE INDEX brain_retained_sources_owner_store_inserted_index ON public.brain_retained_sources USING btree (owner_uid, store_key, inserted_at);

CREATE UNIQUE INDEX human_users_email_index ON public.human_users USING btree (email) WHERE (email IS NOT NULL);

CREATE UNIQUE INDEX human_users_mobile_index ON public.human_users USING btree (mobile) WHERE (mobile IS NOT NULL);

CREATE INDEX oban_jobs_args_index ON public.oban_jobs USING gin (args);

CREATE INDEX oban_jobs_meta_index ON public.oban_jobs USING gin (meta);

CREATE INDEX oban_jobs_state_cancelled_at_index ON public.oban_jobs USING btree (state, cancelled_at);

CREATE INDEX oban_jobs_state_discarded_at_index ON public.oban_jobs USING btree (state, discarded_at);

CREATE INDEX oban_jobs_state_queue_priority_scheduled_at_id_index ON public.oban_jobs USING btree (state, queue, priority, scheduled_at, id);

CREATE INDEX permission_grants_group_id_action_index ON public.permission_grants USING btree (group_id, action);

CREATE UNIQUE INDEX permission_grants_group_natural_index ON public.permission_grants USING btree (group_id, resource_pattern, action, condition) WHERE (group_id IS NOT NULL);

CREATE UNIQUE INDEX permission_grants_principal_natural_index ON public.permission_grants USING btree (principal_uid, resource_pattern, action, condition) WHERE (principal_uid IS NOT NULL);

CREATE INDEX permission_grants_principal_uid_action_index ON public.permission_grants USING btree (principal_uid, action);

CREATE UNIQUE INDEX principal_external_identities_channel_actor_index ON public.principal_external_identities USING btree (adapter, channel_id, external_id) WHERE (kind = 'channel_actor'::public.principal_external_identity_kind);

CREATE INDEX principal_external_identities_principal_uid_index ON public.principal_external_identities USING btree (principal_uid);

CREATE UNIQUE INDEX principal_external_identities_provider_identity_index ON public.principal_external_identities USING btree (kind, provider, external_id) WHERE (kind <> 'channel_actor'::public.principal_external_identity_kind);

CREATE INDEX principal_group_external_bindings_group_id_index ON public.principal_group_external_bindings USING btree (group_id);

CREATE INDEX principal_group_memberships_group_id_index ON public.principal_group_memberships USING btree (group_id);

CREATE UNIQUE INDEX principal_groups_name_index ON public.principal_groups USING btree (name);

CREATE INDEX signal_gateway_ambient_judgments_channel_index ON public.signal_gateway_ambient_judgments USING btree (signal_channel_id, inserted_at);

CREATE INDEX signal_gateway_bindings_adapter_index ON public.signal_gateway_bindings USING btree (adapter);

CREATE INDEX signal_gateway_channels_principal_group_id_index ON public.signal_gateway_channels USING btree (principal_group_id) WHERE (principal_group_id IS NOT NULL);

CREATE INDEX signal_gateway_entries_ai_message_id_index ON public.signal_gateway_entries USING btree (ai_message_id) WHERE (ai_message_id IS NOT NULL);

CREATE INDEX signal_gateway_entries_brain_bm25_index ON public.signal_gateway_entries USING bm25 (document_id, ((text)::pdb.jieba), author, metadata, ((provider_thread_id)::pdb.jieba)) WITH (key_field=document_id);

CREATE INDEX signal_gateway_entries_last_seen_at_index ON public.signal_gateway_entries USING btree (last_seen_at);

CREATE UNIQUE INDEX signal_gateway_entries_source_identity_index ON public.signal_gateway_entries USING btree (signal_channel_id, source_entry_id);

CREATE INDEX signal_gateway_inbound_batches_due_index ON public.signal_gateway_inbound_batches USING btree (batch_state, available_at);

CREATE INDEX signal_gateway_inbound_batches_entry_lookup_index ON public.signal_gateway_inbound_batches USING btree (agent_uid, binding_name, signal_channel_id);

CREATE UNIQUE INDEX signal_gateway_inbound_batches_open_index ON public.signal_gateway_inbound_batches USING btree (agent_uid, binding_name, signal_channel_id, provider_thread_id) WHERE (batch_state = 'open'::text);

CREATE INDEX signal_gateway_input_tombstones_tombstoned_until_index ON public.signal_gateway_input_tombstones USING btree (tombstoned_until);

CREATE INDEX signal_gateway_outbox_entries_ai_message_id_index ON public.signal_gateway_outbox_entries USING btree (ai_message_id);

CREATE INDEX signal_gateway_outbox_entries_channel_created_entry_index ON public.signal_gateway_outbox_entries USING btree (signal_channel_id, created_source_entry_id);

CREATE INDEX signal_gateway_outbox_entries_delivery_class_status_next_attemp ON public.signal_gateway_outbox_entries USING btree (delivery_class, status, next_attempt_at);

CREATE INDEX signal_gateway_outbox_entries_source_actor_event_id_index ON public.signal_gateway_outbox_entries USING btree (source_actor_event_id);

CREATE INDEX signal_gateway_outbox_entries_status_next_attempt_at_index ON public.signal_gateway_outbox_entries USING btree (status, next_attempt_at);

CREATE INDEX signal_gateway_webhook_endpoints_actor_status_index ON public.signal_gateway_webhook_endpoints USING btree (agent_uid, session_id, status, expires_at);

CREATE INDEX signal_gateway_webhook_endpoints_automation_job_index ON public.signal_gateway_webhook_endpoints USING btree (automation_job_id) WHERE (automation_job_id IS NOT NULL);

CREATE INDEX signal_gateway_webhook_endpoints_expiry_index ON public.signal_gateway_webhook_endpoints USING btree (status, expires_at) WHERE (status = ANY (ARRAY['armed'::text, 'active'::text]));

CREATE INDEX signal_gateway_webhook_endpoints_source_event_index ON public.signal_gateway_webhook_endpoints USING btree (source_actor_event_id) WHERE (source_actor_event_id IS NOT NULL);

CREATE UNIQUE INDEX signal_gateway_webhook_endpoints_token_digest_index ON public.signal_gateway_webhook_endpoints USING btree (token_digest);

CREATE TRIGGER brain_entry_relations_scope_guard BEFORE INSERT OR UPDATE ON public.brain_entry_relations FOR EACH ROW EXECUTE FUNCTION public.brain_validate_entry_relation_scope();

CREATE TRIGGER brain_retained_sources_update_guard BEFORE UPDATE ON public.brain_retained_sources FOR EACH ROW EXECUTE FUNCTION public.guard_brain_retained_source_update();

ALTER TABLE ONLY public.actor_cron_schedules
    ADD CONSTRAINT actor_cron_schedules_agent_uid_fkey FOREIGN KEY (agent_uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.actor_cron_schedules
    ADD CONSTRAINT actor_cron_schedules_automation_job_id_fkey FOREIGN KEY (automation_job_id) REFERENCES public.automation_jobs(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.actor_events
    ADD CONSTRAINT actor_events_agent_uid_fkey FOREIGN KEY (agent_uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.actor_scheduled_events
    ADD CONSTRAINT actor_scheduled_events_actor_event_id_fkey FOREIGN KEY (actor_event_id) REFERENCES public.actor_events(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.actor_scheduled_events
    ADD CONSTRAINT actor_scheduled_events_agent_uid_fkey FOREIGN KEY (agent_uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.actor_scheduled_events
    ADD CONSTRAINT actor_scheduled_events_automation_job_id_fkey FOREIGN KEY (automation_job_id) REFERENCES public.automation_jobs(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.actor_scheduled_events
    ADD CONSTRAINT actor_scheduled_events_automation_job_run_id_fkey FOREIGN KEY (automation_job_run_id) REFERENCES public.automation_job_runs(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.actor_scheduled_events
    ADD CONSTRAINT actor_scheduled_events_cron_schedule_id_fkey FOREIGN KEY (cron_schedule_id) REFERENCES public.actor_cron_schedules(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.actor_scheduled_events
    ADD CONSTRAINT actor_scheduled_events_origin_ai_message_id_fkey FOREIGN KEY (origin_ai_message_id) REFERENCES public.ai_gateway_messages(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.actor_scheduled_events
    ADD CONSTRAINT actor_scheduled_events_source_actor_event_id_fkey FOREIGN KEY (source_actor_event_id) REFERENCES public.actor_events(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.actor_session_workspaces
    ADD CONSTRAINT actor_session_workspaces_agent_uid_fkey FOREIGN KEY (agent_uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.agent_library_container_entries
    ADD CONSTRAINT agent_library_container_entries_agent_uid_fkey FOREIGN KEY (agent_uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.agent_plugin_overrides
    ADD CONSTRAINT agent_plugin_overrides_agent_uid_fkey FOREIGN KEY (agent_uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.agent_skill_overlays
    ADD CONSTRAINT agent_skill_overlays_agent_uid_fkey FOREIGN KEY (agent_uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.agent_skills
    ADD CONSTRAINT agent_skills_agent_uid_fkey FOREIGN KEY (agent_uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT agents_created_by_principal_uid_fkey FOREIGN KEY (created_by_principal_uid) REFERENCES public.principals(uid) ON DELETE SET NULL;

ALTER TABLE ONLY public.agents
    ADD CONSTRAINT agents_uid_fkey FOREIGN KEY (uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.ai_gateway_artifacts
    ADD CONSTRAINT ai_gateway_artifacts_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.ai_gateway_messages(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.ai_gateway_artifacts
    ADD CONSTRAINT ai_gateway_artifacts_subject_uid_fkey FOREIGN KEY (subject_uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.ai_gateway_compaction_artifacts
    ADD CONSTRAINT ai_gateway_compaction_artifacts_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.ai_gateway_conversations(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.ai_gateway_compaction_artifacts
    ADD CONSTRAINT ai_gateway_compaction_artifacts_subject_uid_fkey FOREIGN KEY (subject_uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.ai_gateway_conversations
    ADD CONSTRAINT ai_gateway_conversations_subject_uid_fkey FOREIGN KEY (subject_uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.ai_gateway_messages
    ADD CONSTRAINT ai_gateway_messages_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.ai_gateway_conversations(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.ai_gateway_messages
    ADD CONSTRAINT ai_gateway_messages_previous_message_id_fkey FOREIGN KEY (previous_message_id) REFERENCES public.ai_gateway_messages(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.ai_gateway_messages
    ADD CONSTRAINT ai_gateway_messages_subject_uid_fkey FOREIGN KEY (subject_uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.automation_job_runs
    ADD CONSTRAINT automation_job_runs_automation_job_id_fkey FOREIGN KEY (automation_job_id) REFERENCES public.automation_jobs(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.automation_jobs
    ADD CONSTRAINT automation_jobs_agent_uid_fkey FOREIGN KEY (agent_uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.automation_jobs
    ADD CONSTRAINT automation_jobs_source_actor_event_id_fkey FOREIGN KEY (source_actor_event_id) REFERENCES public.actor_events(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.background_agent_job_turn_trajectory_groups
    ADD CONSTRAINT background_agent_job_turn_trajectory_groups_turn_id_fkey FOREIGN KEY (turn_id) REFERENCES public.background_agent_job_turns(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.background_agent_job_turns
    ADD CONSTRAINT background_agent_job_turns_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.background_agent_jobs(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.background_agent_jobs
    ADD CONSTRAINT background_agent_jobs_agent_uid_fkey FOREIGN KEY (agent_uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.background_agent_jobs
    ADD CONSTRAINT background_agent_jobs_continued_from_job_id_fkey FOREIGN KEY (continued_from_job_id) REFERENCES public.background_agent_jobs(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.background_agent_jobs
    ADD CONSTRAINT background_agent_jobs_source_actor_event_id_fkey FOREIGN KEY (source_actor_event_id) REFERENCES public.actor_events(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.background_agent_jobs
    ADD CONSTRAINT background_agent_jobs_workspace_owner_job_id_fkey FOREIGN KEY (workspace_owner_job_id) REFERENCES public.background_agent_jobs(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.brain_audit_log
    ADD CONSTRAINT brain_audit_log_actor_uid_fkey FOREIGN KEY (actor_uid) REFERENCES public.principals(uid) ON DELETE SET NULL;

ALTER TABLE ONLY public.brain_audit_log
    ADD CONSTRAINT brain_audit_log_owner_uid_fkey FOREIGN KEY (owner_uid) REFERENCES public.principals(uid);

ALTER TABLE ONLY public.brain_block_citations
    ADD CONSTRAINT brain_block_citations_block_id_fkey FOREIGN KEY (block_id) REFERENCES public.brain_entry_blocks(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.brain_entries
    ADD CONSTRAINT brain_entries_owner_uid_fkey FOREIGN KEY (owner_uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.brain_entry_blocks
    ADD CONSTRAINT brain_entry_blocks_author_uid_fkey FOREIGN KEY (author_uid) REFERENCES public.principals(uid) ON DELETE SET NULL;

ALTER TABLE ONLY public.brain_entry_blocks
    ADD CONSTRAINT brain_entry_blocks_entry_scope_fkey FOREIGN KEY (entry_id, owner_uid, store_key) REFERENCES public.brain_entries(id, owner_uid, store_key) ON DELETE CASCADE;

ALTER TABLE ONLY public.brain_entry_blocks
    ADD CONSTRAINT brain_entry_blocks_owner_uid_fkey FOREIGN KEY (owner_uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.brain_entry_relations
    ADD CONSTRAINT brain_entry_relations_owner_uid_fkey FOREIGN KEY (owner_uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.brain_entry_relations
    ADD CONSTRAINT brain_entry_relations_source_entry_id_fkey FOREIGN KEY (source_entry_id) REFERENCES public.brain_entries(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.brain_entry_relations
    ADD CONSTRAINT brain_entry_relations_target_entry_id_fkey FOREIGN KEY (target_entry_id) REFERENCES public.brain_entries(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.brain_episodes
    ADD CONSTRAINT brain_episodes_signal_channel_id_fkey FOREIGN KEY (signal_channel_id) REFERENCES public.signal_gateway_channels(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.brain_retained_sources
    ADD CONSTRAINT brain_retained_sources_learning_agent_uid_fkey FOREIGN KEY (learning_agent_uid) REFERENCES public.principals(uid) ON DELETE SET NULL;

ALTER TABLE ONLY public.brain_retained_sources
    ADD CONSTRAINT brain_retained_sources_owner_uid_fkey FOREIGN KEY (owner_uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.human_users
    ADD CONSTRAINT human_users_principal_uid_fkey FOREIGN KEY (principal_uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.permission_grants
    ADD CONSTRAINT permission_grants_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.principal_groups(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.permission_grants
    ADD CONSTRAINT permission_grants_principal_uid_fkey FOREIGN KEY (principal_uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.principal_external_identities
    ADD CONSTRAINT principal_external_identities_principal_uid_fkey FOREIGN KEY (principal_uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.principal_group_external_bindings
    ADD CONSTRAINT principal_group_external_bindings_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.principal_groups(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.principal_group_memberships
    ADD CONSTRAINT principal_group_memberships_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.principal_groups(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.principal_group_memberships
    ADD CONSTRAINT principal_group_memberships_principal_uid_fkey FOREIGN KEY (principal_uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.signal_gateway_ambient_judgments
    ADD CONSTRAINT signal_gateway_ambient_judgments_actor_event_id_fkey FOREIGN KEY (actor_event_id) REFERENCES public.actor_events(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.signal_gateway_ambient_judgments
    ADD CONSTRAINT signal_gateway_ambient_judgments_agent_uid_fkey FOREIGN KEY (agent_uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.signal_gateway_bindings
    ADD CONSTRAINT signal_gateway_bindings_agent_uid_fkey FOREIGN KEY (agent_uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.signal_gateway_channels
    ADD CONSTRAINT signal_gateway_channels_principal_group_id_fkey FOREIGN KEY (principal_group_id) REFERENCES public.principal_groups(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.signal_gateway_entries
    ADD CONSTRAINT signal_gateway_entries_signal_channel_id_fkey FOREIGN KEY (signal_channel_id) REFERENCES public.signal_gateway_channels(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.signal_gateway_inbound_batches
    ADD CONSTRAINT signal_gateway_inbound_batches_agent_uid_fkey FOREIGN KEY (agent_uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.signal_gateway_inbound_batches
    ADD CONSTRAINT signal_gateway_inbound_batches_signal_channel_id_fkey FOREIGN KEY (signal_channel_id) REFERENCES public.signal_gateway_channels(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.signal_gateway_input_tombstones
    ADD CONSTRAINT signal_gateway_input_tombstones_agent_uid_fkey FOREIGN KEY (agent_uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.signal_gateway_input_tombstones
    ADD CONSTRAINT signal_gateway_input_tombstones_signal_channel_id_fkey FOREIGN KEY (signal_channel_id) REFERENCES public.signal_gateway_channels(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.signal_gateway_outbox_entries
    ADD CONSTRAINT signal_gateway_outbox_entries_agent_uid_fkey FOREIGN KEY (agent_uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.signal_gateway_webhook_endpoints
    ADD CONSTRAINT signal_gateway_webhook_endpoints_agent_uid_fkey FOREIGN KEY (agent_uid) REFERENCES public.principals(uid) ON DELETE CASCADE;

ALTER TABLE ONLY public.signal_gateway_webhook_endpoints
    ADD CONSTRAINT signal_gateway_webhook_endpoints_automation_job_id_fkey FOREIGN KEY (automation_job_id) REFERENCES public.automation_jobs(id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.signal_gateway_webhook_endpoints
    ADD CONSTRAINT signal_gateway_webhook_endpoints_source_actor_event_id_fkey FOREIGN KEY (source_actor_event_id) REFERENCES public.actor_events(id) ON DELETE SET NULL;

-- Fresh v0.62.2 durable seed facts.
INSERT INTO public.app_configurations (scope, key, value, inserted_at, updated_at)
VALUES (
  'global',
  'plugins.enabled_ids',
  '{"type":"plaintext","value":["china-market-ai-providers","dingtalk-adapter","google-workspace-adapter","lark-adapter","microsoft365-adapter","slack-adapter"]}'::jsonb,
  CURRENT_TIMESTAMP,
  CURRENT_TIMESTAMP
);
INSERT INTO public.principals (uid, type, status, display_name, inserted_at, updated_at)
VALUES (
  'brain-shared',
  'system',
  'active',
  'Shared long-term memory',
  CURRENT_TIMESTAMP,
  CURRENT_TIMESTAMP
);
