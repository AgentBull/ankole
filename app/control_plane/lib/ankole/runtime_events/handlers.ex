defmodule Ankole.RuntimeEvents.Handlers do
  @moduledoc false

  alias Ankole.ActorRuntime
  alias Ankole.ActorRuntime.SessionController
  alias Ankole.Logging
  alias Ankole.SignalsGateway

  @actor_session_ready "ankole_actor_session_ready"
  @outbox_due "ankole_outbox_due"
  @inbound_batch_due "ankole_inbound_batch_due"
  @activation_deadline "ankole_activation_deadline"
  @ai_message_deadline "ankole_ai_message_deadline"

  @spec snapshot_events() :: [{String.t(), map()}]
  def snapshot_events do
    []
    |> Kernel.++(ActorRuntime.runtime_event_snapshot())
    |> Kernel.++(SignalsGateway.runtime_event_snapshot())
  end

  @spec handle(String.t(), map()) :: :ok
  def handle(channel, payload) when channel == @actor_session_ready do
    with {:ok, actor_key} <- actor_key(payload) do
      case SessionController.process_ready(actor_key) do
        {:ok, _result} -> :ok
        {:error, :no_ready_actor_event} -> :ok
        {:error, reason} -> log_handler_error(channel, payload, reason)
      end
    else
      {:error, reason} -> log_handler_error(channel, payload, reason)
    end
  end

  def handle(channel, payload) when channel == @outbox_due do
    with {:ok, key} <- outbox_key(payload) do
      case SignalsGateway.dispatch_outbox_by_key(
             key.agent_uid,
             key.binding_name,
             key.outbound_key
           ) do
        {:ok, _outbox} -> :ok
        {:error, :outbox_not_dispatchable} -> :ok
        {:error, :outbox_not_due} -> :ok
        {:error, :outbox_send_in_progress} -> :ok
        {:error, :outbox_not_found} -> :ok
        {:error, reason} -> log_handler_error(channel, payload, reason)
      end
    else
      {:error, reason} -> log_handler_error(channel, payload, reason)
    end
  end

  def handle(channel, payload) when channel == @inbound_batch_due do
    with {:ok, batch_id} <- fetch_text(payload, "batch_id"),
         {:ok, revision} <- fetch_integer(payload, "batch_revision") do
      case SignalsGateway.finalize_inbound_batch_by_id(batch_id, revision) do
        {:ok, _result} -> :ok
        {:error, :inbound_batch_not_due} -> :ok
        {:error, :inbound_batch_revision_stale} -> :ok
        {:error, :inbound_batch_not_found} -> :ok
        {:error, reason} -> log_handler_error(channel, payload, reason)
      end
    else
      {:error, reason} -> log_handler_error(channel, payload, reason)
    end
  end

  def handle("ankole_worker_deadline:stale" = channel, payload) do
    with {:ok, worker_id} <- fetch_text(payload, "worker_id") do
      case ActorRuntime.mark_worker_stale_if_due(worker_id) do
        {:ok, _result} -> :ok
        {:error, :worker_not_due} -> :ok
        {:error, :worker_not_found} -> :ok
        {:error, reason} -> log_handler_error(channel, payload, reason)
      end
    else
      {:error, reason} -> log_handler_error(channel, payload, reason)
    end
  end

  def handle("ankole_worker_deadline:delete" = channel, payload) do
    with {:ok, worker_id} <- fetch_text(payload, "worker_id") do
      case ActorRuntime.delete_worker_if_due(worker_id) do
        {:ok, _result} -> :ok
        {:error, :worker_not_due} -> :ok
        {:error, :worker_not_found} -> :ok
        {:error, reason} -> log_handler_error(channel, payload, reason)
      end
    else
      {:error, reason} -> log_handler_error(channel, payload, reason)
    end
  end

  def handle(channel, payload) when channel == @activation_deadline do
    with {:ok, activation_uid} <- fetch_text(payload, "activation_uid") do
      case ActorRuntime.fail_activation_if_expired(activation_uid) do
        {:ok, _result} -> :ok
        {:error, :activation_not_due} -> :ok
        {:error, :activation_not_found} -> :ok
        {:error, reason} -> log_handler_error(channel, payload, reason)
      end
    else
      {:error, reason} -> log_handler_error(channel, payload, reason)
    end
  end

  def handle(channel, payload) when channel == @ai_message_deadline do
    with {:ok, message_id} <- fetch_text(payload, "message_id") do
      case ActorRuntime.reconcile_projection_lost_started_turn(message_id) do
        {:ok, _result} -> :ok
        {:error, :message_not_due} -> :ok
        {:error, :message_not_found} -> :ok
        {:error, reason} -> log_handler_error(channel, payload, reason)
      end
    else
      {:error, reason} -> log_handler_error(channel, payload, reason)
    end
  end

  def handle(channel, payload) do
    Logging.warning(
      "runtime_events.handlers.unknown_channel",
      "runtime event ignored unknown channel",
      %{
        channel: channel,
        payload: payload
      }
    )

    :ok
  end

  defp actor_key(payload) do
    with {:ok, agent_uid} <- fetch_text(payload, "agent_uid"),
         {:ok, session_id} <- fetch_text(payload, "session_id") do
      {:ok, %{agent_uid: agent_uid, session_id: session_id}}
    end
  end

  defp outbox_key(payload) do
    with {:ok, agent_uid} <- fetch_text(payload, "agent_uid"),
         {:ok, binding_name} <- fetch_text(payload, "binding_name"),
         {:ok, outbound_key} <- fetch_text(payload, "outbound_key") do
      {:ok, %{agent_uid: agent_uid, binding_name: binding_name, outbound_key: outbound_key}}
    end
  end

  defp fetch_text(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing_text, key}}
    end
  end

  defp fetch_integer(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_integer(value) -> {:ok, value}
      _value -> {:error, {:missing_integer, key}}
    end
  end

  defp log_handler_error(channel, payload, reason) do
    Logging.warning("runtime_events.handlers.handler_failed", "runtime event handler failed", %{
      channel: channel,
      payload: inspect(payload, limit: 10),
      reason: inspect(reason, limit: 20)
    })

    :ok
  end
end
