defmodule Ankole.RuntimeEvents do
  @moduledoc """
  PG-backed wakeup surface for runtime state transitions.

  PostgreSQL rows remain the durable source of truth. RuntimeEvents only carries
  commit-after wakeups and per-row deadlines to the local BEAM owner.
  """

  alias Ankole.RuntimeEvents.Notifier

  @actor_session_ready "ankole_actor_session_ready"
  @outbox_due "ankole_outbox_due"
  @inbound_batch_due "ankole_inbound_batch_due"
  @worker_deadline "ankole_worker_deadline"
  @activation_deadline "ankole_activation_deadline"
  @ai_message_deadline "ankole_ai_message_deadline"

  @channels [
    @actor_session_ready,
    @outbox_due,
    @inbound_batch_due,
    @worker_deadline,
    @activation_deadline,
    @ai_message_deadline
  ]

  @spec channels() :: [String.t()]
  def channels, do: @channels

  @spec actor_session_ready_channel() :: String.t()
  def actor_session_ready_channel, do: @actor_session_ready

  @spec outbox_due_channel() :: String.t()
  def outbox_due_channel, do: @outbox_due

  @spec inbound_batch_due_channel() :: String.t()
  def inbound_batch_due_channel, do: @inbound_batch_due

  @spec worker_deadline_channel() :: String.t()
  def worker_deadline_channel, do: @worker_deadline

  @spec activation_deadline_channel() :: String.t()
  def activation_deadline_channel, do: @activation_deadline

  @spec ai_message_deadline_channel() :: String.t()
  def ai_message_deadline_channel, do: @ai_message_deadline

  @spec notify_actor_session_ready(module(), String.t(), String.t(), DateTime.t() | nil) ::
          :ok | {:error, term()}
  def notify_actor_session_ready(repo, agent_uid, session_id, due_at \\ nil) do
    Notifier.notify_in_tx(repo, @actor_session_ready, %{
      "agent_uid" => agent_uid,
      "session_id" => session_id,
      "due_at" => encode_datetime(due_at)
    })
  end

  @spec notify_outbox_due(module(), map(), DateTime.t() | nil) :: :ok | {:error, term()}
  def notify_outbox_due(repo, outbox, due_at \\ nil) do
    Notifier.notify_in_tx(repo, @outbox_due, %{
      "agent_uid" => outbox.agent_uid,
      "binding_name" => outbox.binding_name,
      "outbound_key" => outbox.outbound_key,
      "due_at" => encode_datetime(due_at)
    })
  end

  @spec notify_inbound_batch_due(module(), map(), DateTime.t() | nil) :: :ok | {:error, term()}
  def notify_inbound_batch_due(repo, batch, due_at \\ nil) do
    Notifier.notify_in_tx(repo, @inbound_batch_due, %{
      "batch_id" => batch.id,
      "batch_revision" => batch.batch_revision,
      "due_at" => encode_datetime(due_at || batch.available_at)
    })
  end

  @spec notify_worker_deadline(module(), map(), keyword()) :: :ok | {:error, term()}
  def notify_worker_deadline(repo, worker, opts) do
    Notifier.notify_in_tx(repo, @worker_deadline, %{
      "worker_id" => worker.worker_id,
      "transport_route" => worker.transport_route,
      "stale_at" => encode_datetime(Keyword.get(opts, :stale_at)),
      "delete_at" => encode_datetime(Keyword.get(opts, :delete_at))
    })
  end

  @spec notify_activation_deadline(module(), map()) :: :ok | {:error, term()}
  def notify_activation_deadline(repo, activation) do
    Notifier.notify_in_tx(repo, @activation_deadline, %{
      "activation_uid" => activation.activation_uid,
      "agent_uid" => activation.agent_uid,
      "session_id" => activation.session_id,
      "lease_expires_at" => encode_datetime(activation.lease_expires_at)
    })
  end

  @spec notify_ai_message_deadline(module(), map(), DateTime.t()) :: :ok | {:error, term()}
  def notify_ai_message_deadline(repo, message, orphan_at) do
    Notifier.notify_in_tx(repo, @ai_message_deadline, %{
      "message_id" => message.id,
      "orphan_at" => encode_datetime(orphan_at)
    })
  end

  @spec encode_datetime(DateTime.t() | nil) :: String.t() | nil
  def encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  def encode_datetime(nil), do: nil
end
