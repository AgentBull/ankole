defmodule Ankole.Repo.Migrations.CreateActorRuntime do
  # ActorRuntime 的 volatile（UNLOGGED）运行时表。
  #
  # Phase 1 重构（见 new-plan.md §2.3）：
  #   - actor_input_deliveries → actor_event_deliveries
  #   - delivery row: actor_input_id → actor_event_id, live_queue_sequence → queue_sequence,
  #     删除 delivery_batch_id 和 llm_turn_id（单事件化，不再批量/不再有 turn 概念）
  #   - worker 路由 fence 从 (activation_uid, actor_epoch, llm_turn_id, revision) 改为
  #     (activation_uid, actor_epoch, actor_event_id, revision)
  #
  # 这些表是 UNLOGGED 的：它们是进程可重建的运行时投影，不是 durable truth。
  # durable truth 在 PostgreSQL 的 actor_events + ai_gateway_messages。
  use Ecto.Migration

  def up do
    # ── actor_event_deliveries：delivery 尝试 ────────────────
    # 旧名 actor_input_deliveries。Phase 1 单事件化后：
    #   - 一次 worker execution 只处理一个 actor_event_id（§2.3）
    #   - 删除 delivery_batch_id（不再批量发送）
    #   - 删除 llm_turn_id（不再有 llm_turn 概念，改用 actor_event_id）
    execute("""
    CREATE UNLOGGED TABLE actor_event_deliveries (
      id uuid PRIMARY KEY,
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
      state text NOT NULL DEFAULT 'created',
      send_outcome text,
      sent_at timestamptz,
      accepted_at timestamptz,
      failed_at timestamptz,
      superseded_at timestamptz,
      error jsonb NOT NULL DEFAULT '{}',
      inserted_at timestamp(6) NOT NULL,
      updated_at timestamp(6) NOT NULL,
      CONSTRAINT actor_event_deliveries_attempt_positive CHECK (attempt_no > 0),
      CONSTRAINT actor_event_deliveries_state_check CHECK (
        state IN ('created', 'sent', 'send_failed', 'accepted', 'superseded')
      ),
      CONSTRAINT actor_event_deliveries_send_outcome_check CHECK (
        send_outcome IS NULL OR send_outcome IN (
          'sent_or_queued',
          'unknown_route',
          'backpressure',
          'timeout',
          'socket_closed'
        )
      ),
      CONSTRAINT actor_event_deliveries_error_object CHECK (jsonb_typeof(error) = 'object')
    )
    """)

    execute(
      "CREATE UNIQUE INDEX actor_event_deliveries_event_attempt_index ON actor_event_deliveries (actor_event_id, attempt_no)"
    )

    # 一个 actor event 至多一条 live delivery（created/sent/accepted）。
    # 这是 DB 级保证：一个 queued event 映射到至多一个 in-flight worker turn。
    execute(
      "CREATE UNIQUE INDEX actor_event_deliveries_live_event_index ON actor_event_deliveries (actor_event_id) WHERE state IN ('created', 'sent', 'accepted')"
    )

    execute(
      "CREATE INDEX actor_event_deliveries_state_index ON actor_event_deliveries (agent_uid, session_id, state, queue_sequence)"
    )

    execute(
      "CREATE INDEX actor_event_deliveries_worker_state_index ON actor_event_deliveries (worker_id, state)"
    )

    # ── agent_computer_workers：已连接 worker 注册表 ──────────
    execute("""
    CREATE UNLOGGED TABLE agent_computer_workers (
      id uuid PRIMARY KEY,
      worker_id text NOT NULL,
      status text NOT NULL,
      version text,
      capacity jsonb NOT NULL DEFAULT '{}',
      load jsonb NOT NULL DEFAULT '{}',
      transport_route text,
      last_worker_heartbeat_at timestamptz,
      started_at timestamptz,
      stopped_at timestamptz,
      stop_reason text,
      metadata jsonb NOT NULL DEFAULT '{}',
      inserted_at timestamp(6) NOT NULL,
      updated_at timestamp(6) NOT NULL,
      CONSTRAINT agent_computer_workers_status_check CHECK (
        status IN ('ready', 'stale', 'draining', 'stopped')
      ),
      CONSTRAINT agent_computer_workers_capacity_object CHECK (jsonb_typeof(capacity) = 'object'),
      CONSTRAINT agent_computer_workers_load_object CHECK (jsonb_typeof(load) = 'object'),
      CONSTRAINT agent_computer_workers_metadata_object CHECK (jsonb_typeof(metadata) = 'object')
    )
    """)

    execute(
      "CREATE UNIQUE INDEX agent_computer_workers_worker_id_index ON agent_computer_workers (worker_id)"
    )

    execute(
      "CREATE UNIQUE INDEX agent_computer_workers_transport_route_index ON agent_computer_workers (transport_route) WHERE transport_route IS NOT NULL"
    )

    # ── actor_session_worker_assignments：session → worker 映射
    execute("""
    CREATE UNLOGGED TABLE actor_session_worker_assignments (
      id uuid PRIMARY KEY,
      agent_uid text NOT NULL,
      session_id text NOT NULL,
      worker_id text NOT NULL,
      transport_route text,
      status text NOT NULL,
      workspace_mount text,
      assigned_at timestamptz NOT NULL,
      last_used_at timestamptz,
      metadata jsonb NOT NULL DEFAULT '{}',
      inserted_at timestamp(6) NOT NULL,
      updated_at timestamp(6) NOT NULL,
      CONSTRAINT actor_session_worker_assignments_status_check CHECK (
        status IN ('assigned', 'draining', 'released')
      ),
      CONSTRAINT actor_session_worker_assignments_metadata_object CHECK (jsonb_typeof(metadata) = 'object')
    )
    """)

    execute(
      "CREATE UNIQUE INDEX actor_session_worker_assignments_live_actor_index ON actor_session_worker_assignments (agent_uid, session_id) WHERE status IN ('assigned', 'draining')"
    )

    execute(
      "CREATE INDEX actor_session_worker_assignments_worker_index ON actor_session_worker_assignments (worker_id, status)"
    )

    # ── actor_session_activations：activation lease ──────────
    # Phase 1：current_llm_turn_id → current_actor_event_id。
    # lease/fence 仍由 activation 维护，但指向 actor event 而非 llm_turn。
    execute("""
    CREATE UNLOGGED TABLE actor_session_activations (
      id uuid PRIMARY KEY,
      activation_uid text NOT NULL,
      agent_uid text NOT NULL,
      session_id text NOT NULL,
      actor_epoch bigint NOT NULL,
      status text NOT NULL,
      controller_node text,
      lease_id text NOT NULL,
      lease_expires_at timestamptz NOT NULL,
      last_actor_heartbeat_at timestamptz,
      assigned_worker_id text,
      current_actor_event_id uuid,
      revision integer NOT NULL DEFAULT 0,
      started_at timestamptz NOT NULL,
      stopped_at timestamptz,
      stop_reason text,
      metadata jsonb NOT NULL DEFAULT '{}',
      inserted_at timestamp(6) NOT NULL,
      updated_at timestamp(6) NOT NULL,
      CONSTRAINT actor_session_activations_status_check CHECK (
        status IN ('starting', 'active', 'draining', 'stopped', 'failed')
      ),
      CONSTRAINT actor_session_activations_metadata_object CHECK (jsonb_typeof(metadata) = 'object')
    )
    """)

    execute(
      "CREATE UNIQUE INDEX actor_session_activations_activation_uid_index ON actor_session_activations (activation_uid)"
    )

    execute(
      "CREATE UNIQUE INDEX actor_session_activations_live_actor_index ON actor_session_activations (agent_uid, session_id) WHERE status IN ('starting', 'active', 'draining')"
    )

    comment_actor_runtime_tables()
  end

  def down do
    execute("DROP TABLE IF EXISTS actor_session_activations")
    execute("DROP TABLE IF EXISTS actor_session_worker_assignments")
    execute("DROP TABLE IF EXISTS agent_computer_workers")
    execute("DROP TABLE IF EXISTS actor_event_deliveries")
  end

  defp comment_actor_runtime_tables do
    comment_table(
      :actor_event_deliveries,
      "Volatile delivery attempts from actor events to workers."
    )

    comment_columns(:actor_event_deliveries, %{
      actor_event_id: "Actor event row being delivered.",
      agent_uid: "Agent principal that owns the event.",
      session_id: "Actor session queue for the delivery.",
      queue_sequence: "Per-session event sequence copied from actor_events.",
      attempt_no: "Delivery attempt number for this actor event.",
      actor_lane_message_id: "Transport message id sent over the actor lane.",
      correlation_id: "Optional transport correlation id.",
      activation_uid: "Runtime activation targeted by the delivery.",
      actor_epoch: "Actor epoch fence used by the targeted activation.",
      actor_event_id_fence: "Actor event fence this delivery is bound to.",
      revision: "Runtime revision fence used by the targeted activation.",
      worker_id: "Worker selected for the delivery.",
      transport_route: "Actor transport route used for the delivery.",
      state: "Delivery state from creation through send, acceptance, or supersession.",
      send_outcome: "Transport outcome when the send did not cleanly succeed.",
      sent_at: "Time the actor lane send was attempted.",
      accepted_at: "Time the worker accepted the event.",
      failed_at: "Time the delivery failed before acceptance.",
      superseded_at: "Time a newer delivery replaced this attempt.",
      error: "Structured delivery error for diagnostics."
    })

    comment_table(:agent_computer_workers, "Volatile registry of connected Agent Computer workers.")

    comment_columns(:agent_computer_workers, %{
      worker_id: "Worker process id authenticated by the control plane.",
      status: "Worker availability state used by assignment policy.",
      version: "Worker software version reported at admission.",
      capacity: "Worker capacity advertisement.",
      load: "Current worker load advertisement.",
      transport_route: "Actor transport route proven for this worker connection.",
      last_worker_heartbeat_at: "Most recent heartbeat time observed from the worker.",
      started_at: "Worker-reported start time.",
      stopped_at: "Time the worker was marked stopped.",
      stop_reason: "Operator-visible reason for the stopped state.",
      metadata: "Worker metadata outside the scheduler contract."
    })

    comment_table(
      :actor_session_worker_assignments,
      "Volatile mapping from actor sessions to assigned workers."
    )

    comment_columns(:actor_session_worker_assignments, %{
      agent_uid: "Agent principal that owns the session.",
      session_id: "Actor session assigned to the worker.",
      worker_id: "Worker selected for the session.",
      transport_route: "Actor transport route used for the session.",
      status: "Assignment lifecycle state.",
      workspace_mount: "Worker-visible workspace mount for the session.",
      assigned_at: "Time the assignment was created.",
      last_used_at: "Most recent time the assignment handled work.",
      metadata: "Assignment metadata outside the scheduler contract."
    })

    comment_table(:actor_session_activations, "Volatile activation leases for live actor sessions.")

    comment_columns(:actor_session_activations, %{
      activation_uid: "Stable activation identifier carried across worker messages.",
      agent_uid: "Agent principal that owns the activation.",
      session_id: "Actor session protected by the activation.",
      actor_epoch: "Monotonic actor epoch fence for this session activation.",
      status: "Activation lifecycle state.",
      controller_node: "Control-plane node that owns the activation lease.",
      lease_id: "Lease id proving current activation ownership.",
      lease_expires_at: "Time the activation lease expires without renewal.",
      last_actor_heartbeat_at: "Most recent actor heartbeat observed for the activation.",
      assigned_worker_id: "Worker assigned to the activation.",
      current_actor_event_id: "Actor event currently controlled by the activation.",
      revision: "Revision fence advanced by activation state changes.",
      started_at: "Time the activation started.",
      stopped_at: "Time the activation stopped.",
      stop_reason: "Operator-visible reason the activation stopped.",
      metadata: "Activation metadata outside the runtime fencing contract."
    })
  end

  defp comment_table(table, comment) do
    execute("COMMENT ON TABLE #{identifier(table)} IS #{literal(comment)}")
  end

  defp comment_columns(table, comments) do
    Enum.each(comments, fn {column, comment} -> comment_column(table, column, comment) end)
  end

  defp comment_column(table, column, comment) do
    execute("COMMENT ON COLUMN #{identifier(table)}.#{identifier(column)} IS #{literal(comment)}")
  end

  defp identifier(value), do: "\"" <> String.replace(to_string(value), "\"", "\"\"") <> "\""
  defp literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"
end
