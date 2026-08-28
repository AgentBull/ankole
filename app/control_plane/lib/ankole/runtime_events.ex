defmodule Ankole.RuntimeEvents.Event do
  @moduledoc false

  @type kind ::
          :actor_session_ready
          | :agent_home_projection
          | :reply_preview_checkpoint
          | :reply_preview_cleanup
          | :outbox_due
          | :inbound_batch_due
          | :worker_stale_deadline
          | :worker_delete_deadline
          | :activation_deadline
          | :ai_message_deadline
          | :job_turn_deadline
          | :workflow_run_ready
          | :unknown

  @enforce_keys [:kind, :channel, :payload, :timer_key]
  defstruct [:kind, :channel, :payload, :due_at, :timer_key]

  @type t :: %__MODULE__{
          kind: kind(),
          channel: String.t(),
          payload: map(),
          due_at: DateTime.t() | nil,
          timer_key: term()
        }
end

defmodule Ankole.RuntimeEvents do
  @moduledoc """
  PG-backed wakeup surface for runtime state transitions.

  PostgreSQL rows remain the durable source of truth. RuntimeEvents only carries
  commit-after wakeups and per-row deadlines to the local BEAM owner.
  """

  alias Ankole.RuntimeEvents.Event
  alias Ankole.RuntimeEvents.Notifier

  @actor_session_ready_channel "ankole_actor_session_ready"
  @agent_home_projection_channel "ankole_agent_home_projection"
  @reply_preview_checkpoint_channel "ankole_reply_preview_checkpoint"
  @reply_preview_cleanup_channel "ankole_reply_preview_cleanup"
  @outbox_due_channel "ankole_outbox_due"
  @inbound_batch_due_channel "ankole_inbound_batch_due"
  @worker_deadline_channel "ankole_worker_deadline"
  @activation_deadline_channel "ankole_activation_deadline"
  @ai_message_deadline_channel "ankole_ai_message_deadline"
  @job_turn_deadline_channel "ankole_job_turn_deadline"
  @workflow_run_ready_channel "ankole_workflow_run_ready"

  @actor_session_ready %{
    kind: :actor_session_ready,
    channel: @actor_session_ready_channel,
    due_at_field: "due_at",
    timer_key_fields: ["agent_uid", "session_id"]
  }

  @agent_home_projection %{
    kind: :agent_home_projection,
    channel: @agent_home_projection_channel,
    timer_key_fields: ["agent_uid"]
  }

  @reply_preview_checkpoint %{
    kind: :reply_preview_checkpoint,
    channel: @reply_preview_checkpoint_channel,
    timer_key_fields: ["actor_event_id"]
  }

  @reply_preview_cleanup %{
    kind: :reply_preview_cleanup,
    channel: @reply_preview_cleanup_channel,
    due_at_field: "due_at",
    timer_key_fields: ["actor_event_id"]
  }

  @outbox_due %{
    kind: :outbox_due,
    channel: @outbox_due_channel,
    due_at_field: "due_at",
    timer_key_fields: ["agent_uid", "binding_name", "outbound_key"]
  }

  @inbound_batch_due %{
    kind: :inbound_batch_due,
    channel: @inbound_batch_due_channel,
    due_at_field: "due_at",
    timer_key_fields: ["batch_id"]
  }

  @worker_stale_deadline %{
    kind: :worker_stale_deadline,
    channel: @worker_deadline_channel <> ":stale",
    source_due_field: "stale_at",
    due_at_field: "due_at",
    timer_key_fields: ["worker_id"]
  }

  @worker_delete_deadline %{
    kind: :worker_delete_deadline,
    channel: @worker_deadline_channel <> ":delete",
    source_due_field: "delete_at",
    due_at_field: "due_at",
    timer_key_fields: ["worker_id"]
  }

  @worker_deadline %{
    kind: :worker_deadline,
    channel: @worker_deadline_channel,
    derived_events: [@worker_delete_deadline, @worker_stale_deadline]
  }

  @activation_deadline %{
    kind: :activation_deadline,
    channel: @activation_deadline_channel,
    due_at_field: "due_at",
    timer_key_fields: ["activation_uid"]
  }

  @ai_message_deadline %{
    kind: :ai_message_deadline,
    channel: @ai_message_deadline_channel,
    due_at_field: "orphan_at",
    timer_key_fields: ["message_id"]
  }

  @job_turn_deadline %{
    kind: :job_turn_deadline,
    channel: @job_turn_deadline_channel,
    due_at_field: "stuck_at",
    timer_key_fields: ["job_id"]
  }

  @workflow_run_ready %{
    kind: :workflow_run_ready,
    channel: @workflow_run_ready_channel,
    timer_key_fields: ["run_id"]
  }

  @notification_events [
    @actor_session_ready,
    @agent_home_projection,
    @reply_preview_checkpoint,
    @reply_preview_cleanup,
    @outbox_due,
    @inbound_batch_due,
    @worker_deadline,
    @activation_deadline,
    @ai_message_deadline,
    @job_turn_deadline,
    @workflow_run_ready
  ]

  @handler_events [
    @actor_session_ready,
    @agent_home_projection,
    @reply_preview_checkpoint,
    @reply_preview_cleanup,
    @outbox_due,
    @inbound_batch_due,
    @worker_stale_deadline,
    @worker_delete_deadline,
    @activation_deadline,
    @ai_message_deadline,
    @job_turn_deadline,
    @workflow_run_ready
  ]

  @channels Enum.map(@notification_events, & &1.channel)
  @events_by_channel Map.new(@notification_events ++ @handler_events, &{&1.channel, &1})
  @events_by_kind Map.new(@notification_events ++ @handler_events, &{&1.kind, &1})

  @spec channels() :: [String.t()]
  def channels, do: @channels

  @spec actor_session_ready_channel() :: String.t()
  def actor_session_ready_channel, do: channel_for_kind!(:actor_session_ready)

  @spec agent_home_projection_channel() :: String.t()
  def agent_home_projection_channel, do: channel_for_kind!(:agent_home_projection)

  @spec reply_preview_checkpoint_channel() :: String.t()
  def reply_preview_checkpoint_channel, do: channel_for_kind!(:reply_preview_checkpoint)

  @spec reply_preview_cleanup_channel() :: String.t()
  def reply_preview_cleanup_channel, do: channel_for_kind!(:reply_preview_cleanup)

  @spec outbox_due_channel() :: String.t()
  def outbox_due_channel, do: channel_for_kind!(:outbox_due)

  @spec inbound_batch_due_channel() :: String.t()
  def inbound_batch_due_channel, do: channel_for_kind!(:inbound_batch_due)

  @spec worker_deadline_channel() :: String.t()
  def worker_deadline_channel, do: channel_for_kind!(:worker_deadline)

  @spec activation_deadline_channel() :: String.t()
  def activation_deadline_channel, do: channel_for_kind!(:activation_deadline)

  @spec ai_message_deadline_channel() :: String.t()
  def ai_message_deadline_channel, do: channel_for_kind!(:ai_message_deadline)

  @spec job_turn_deadline_channel() :: String.t()
  def job_turn_deadline_channel, do: channel_for_kind!(:job_turn_deadline)

  @doc false
  @spec workflow_run_ready_channel() :: String.t()
  def workflow_run_ready_channel, do: channel_for_kind!(:workflow_run_ready)

  @doc false
  @spec expand(String.t(), map()) :: [Event.t()]
  def expand(channel, payload) when is_binary(channel) and is_map(payload) do
    case Map.get(@events_by_channel, channel) do
      %{derived_events: derived_events} ->
        Enum.flat_map(derived_events, &derive_event(&1, payload))

      %{kind: _kind} = event ->
        [build_event(event, payload)]

      nil ->
        [unknown_event(channel, payload)]
    end
  end

  @spec notify_actor_session_ready(module(), String.t(), String.t(), DateTime.t() | nil) ::
          :ok | {:error, term()}
  def notify_actor_session_ready(repo, agent_uid, session_id, due_at \\ nil) do
    Notifier.notify_in_tx(repo, actor_session_ready_channel(), %{
      "agent_uid" => agent_uid,
      "session_id" => session_id,
      "due_at" => encode_datetime(due_at)
    })
  end

  @spec notify_agent_home_projection(module(), String.t()) :: :ok | {:error, term()}
  def notify_agent_home_projection(repo, agent_uid) do
    Notifier.notify_in_tx(repo, agent_home_projection_channel(), %{"agent_uid" => agent_uid})
  end

  @spec notify_reply_preview_checkpoint(module(), map()) :: :ok | {:error, term()}
  def notify_reply_preview_checkpoint(repo, actor_event) do
    with :ok <-
           Notifier.notify_in_tx(repo, reply_preview_checkpoint_channel(), %{
             "actor_event_id" => actor_event.id
           }) do
      notify_reply_preview_cleanup(repo, actor_event)
    end
  end

  defp notify_reply_preview_cleanup(
         repo,
         %{reply_preview_cleanup_at: %DateTime{} = due_at} = event
       ) do
    Notifier.notify_in_tx(repo, reply_preview_cleanup_channel(), %{
      "actor_event_id" => event.id,
      "due_at" => encode_datetime(due_at)
    })
  end

  defp notify_reply_preview_cleanup(_repo, _event), do: :ok

  @spec notify_outbox_due(module(), map(), DateTime.t() | nil) :: :ok | {:error, term()}
  def notify_outbox_due(repo, outbox, due_at \\ nil) do
    Notifier.notify_in_tx(repo, outbox_due_channel(), %{
      "agent_uid" => outbox.agent_uid,
      "binding_name" => outbox.binding_name,
      "outbound_key" => outbox.outbound_key,
      "due_at" => encode_datetime(due_at)
    })
  end

  @spec notify_inbound_batch_due(module(), map(), DateTime.t() | nil) :: :ok | {:error, term()}
  def notify_inbound_batch_due(repo, batch, due_at \\ nil) do
    Notifier.notify_in_tx(repo, inbound_batch_due_channel(), %{
      "batch_id" => batch.id,
      "batch_revision" => batch.batch_revision,
      "due_at" => encode_datetime(due_at || batch.available_at)
    })
  end

  @spec notify_worker_deadline(module(), map(), keyword()) :: :ok | {:error, term()}
  def notify_worker_deadline(repo, worker, opts) do
    Notifier.notify_in_tx(repo, worker_deadline_channel(), %{
      "worker_id" => worker.worker_id,
      "transport_route" => worker.transport_route,
      "stale_at" => encode_datetime(Keyword.get(opts, :stale_at)),
      "delete_at" => encode_datetime(Keyword.get(opts, :delete_at))
    })
  end

  @spec notify_activation_deadline(module(), map(), DateTime.t() | nil) :: :ok | {:error, term()}
  def notify_activation_deadline(repo, activation, due_at \\ nil) do
    Notifier.notify_in_tx(repo, activation_deadline_channel(), %{
      "activation_uid" => activation.activation_uid,
      "agent_uid" => activation.agent_uid,
      "session_id" => activation.session_id,
      "lease_expires_at" => encode_datetime(activation.lease_expires_at),
      "due_at" => encode_datetime(due_at || activation.lease_expires_at)
    })
  end

  @spec notify_ai_message_deadline(module(), map(), DateTime.t()) :: :ok | {:error, term()}
  def notify_ai_message_deadline(repo, message, orphan_at) do
    Notifier.notify_in_tx(repo, ai_message_deadline_channel(), %{
      "message_id" => message.id,
      "orphan_at" => encode_datetime(orphan_at)
    })
  end

  @spec notify_job_turn_deadline(module(), pos_integer(), DateTime.t()) :: :ok | {:error, term()}
  def notify_job_turn_deadline(repo, job_id, %DateTime{} = stuck_at) when is_integer(job_id) do
    Notifier.notify_in_tx(repo, job_turn_deadline_channel(), %{
      "job_id" => job_id,
      "stuck_at" => encode_datetime(stuck_at)
    })
  end

  @doc false
  @spec notify_workflow_run_ready(module(), pos_integer()) :: :ok | {:error, term()}
  def notify_workflow_run_ready(repo, run_id) when is_integer(run_id) and run_id > 0 do
    Notifier.notify_in_tx(repo, workflow_run_ready_channel(), %{"run_id" => run_id})
  end

  @spec encode_datetime(DateTime.t() | nil) :: String.t() | nil
  def encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  def encode_datetime(nil), do: nil

  defp channel_for_kind!(kind) do
    @events_by_kind
    |> Map.fetch!(kind)
    |> Map.fetch!(:channel)
  end

  defp derive_event(%{source_due_field: field} = event, payload) do
    case Map.get(payload, field) do
      value when is_binary(value) -> [build_event(event, Map.put(payload, "due_at", value))]
      _value -> []
    end
  end

  defp build_event(event, payload) do
    %Event{
      kind: event.kind,
      channel: event.channel,
      payload: payload,
      due_at: due_at(event, payload),
      timer_key: timer_key(event, payload)
    }
  end

  defp unknown_event(channel, payload) do
    %Event{
      kind: :unknown,
      channel: channel,
      payload: payload,
      due_at: nil,
      timer_key: {channel, payload}
    }
  end

  defp due_at(%{due_at_field: field}, payload), do: decode_datetime(Map.get(payload, field))
  defp due_at(_event, _payload), do: nil

  defp timer_key(%{channel: channel, timer_key_fields: fields}, payload) do
    values = Enum.map(fields, &Map.get(payload, &1))

    if Enum.all?(values, &(not is_nil(&1))) do
      List.to_tuple([channel | values])
    else
      {channel, payload}
    end
  end

  defp timer_key(%{channel: channel}, payload), do: {channel, payload}

  defp decode_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp decode_datetime(_value), do: nil
end
