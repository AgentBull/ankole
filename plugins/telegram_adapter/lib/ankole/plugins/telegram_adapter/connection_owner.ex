defmodule Ankole.Plugins.TelegramAdapter.ConnectionOwner do
  @moduledoc false

  use GenServer

  alias Ankole.Logging
  alias Ankole.Plugins.TelegramAdapter.{Client, Config, Dispatcher}

  @registry Ankole.Plugins.TelegramAdapter.ConnectionRegistry
  @task_supervisor Ankole.Plugins.TelegramAdapter.PollTaskSupervisor
  @poll_timeout_seconds 30
  @retry_ms 1_000
  @blocked_retry_ms 60_000

  defstruct [
    :key,
    :secret_fingerprint,
    :consumer_fingerprint,
    :client,
    :consumer,
    :bot,
    :task,
    :task_kind,
    :offset,
    :blocked_reason,
    :last_error
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    key = Keyword.fetch!(opts, :key)
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {@registry, key}})
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :key)},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @spec ensure_configuration(GenServer.server(), map(), map()) ::
          {:ok, pid()} | {:error, :configuration_changed}
  def ensure_configuration(server, config, consumer) do
    GenServer.call(server, {:ensure_configuration, config, consumer})
  end

  @spec status(GenServer.server()) :: map()
  def status(server), do: GenServer.call(server, :status)

  @impl true
  def format_status(%{state: %__MODULE__{} = state} = status) do
    %{status | state: public_status(state)}
  end

  def format_status(status), do: status

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    consumer = Keyword.fetch!(opts, :consumer)

    {:ok,
     %__MODULE__{
       key: Keyword.fetch!(opts, :key),
       secret_fingerprint: Config.secret_fingerprint(config),
       consumer_fingerprint: fingerprint(consumer),
       client: Config.client(config),
       consumer: consumer
     }, {:continue, :preflight}}
  end

  @impl true
  def handle_continue(:preflight, state), do: {:noreply, start_preflight(state)}

  @impl true
  def handle_call({:ensure_configuration, config, consumer}, _from, state) do
    unchanged? =
      Config.secret_fingerprint(config) == state.secret_fingerprint and
        fingerprint(consumer) == state.consumer_fingerprint

    reply = if unchanged?, do: {:ok, self()}, else: {:error, :configuration_changed}
    {:reply, reply, state}
  end

  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  @impl true
  def handle_info(:preflight, %{task: nil} = state), do: {:noreply, start_preflight(state)}

  def handle_info(:poll, %{task: nil, blocked_reason: nil} = state),
    do: {:noreply, start_poll(state)}

  def handle_info(:poll, state), do: {:noreply, state}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | task: nil, task_kind: nil}
    {:noreply, handle_task_result(result, state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logging.warning(
      "telegram_adapter.connection_owner.task_failed",
      "Telegram polling task failed",
      %{connection_key: inspect(state.key), reason: sanitize_reason(reason)}
    )

    state = %{state | task: nil, task_kind: nil, last_error: :poll_task_failed}
    Process.send_after(self(), retry_message(state), @retry_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{task: %Task{} = task}) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp start_preflight(state) do
    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        with {:ok, %{"id" => bot_id, "is_bot" => true} = bot} <-
               Client.call(state.client, "getMe"),
             {:ok, webhook} when is_map(webhook) <-
               Client.call(state.client, "getWebhookInfo") do
          if present?(Map.get(webhook, "url")) do
            {:blocked, :webhook_configured, normalize_bot(bot_id, bot)}
          else
            {:ready, normalize_bot(bot_id, bot)}
          end
        else
          {:ok, _invalid} -> {:error, :invalid_bot_identity}
          {:error, %Client.Error{} = error} -> {:error, error}
        end
      end)

    %{state | task: task, task_kind: :preflight}
  end

  defp start_poll(state) do
    client = state.client
    consumer = state.consumer
    bot = state.bot
    offset = state.offset

    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        with {:ok, updates} <- Client.get_updates(client, offset, @poll_timeout_seconds) do
          Dispatcher.process_updates(updates, consumer, bot, offset, client: client)
        end
      end)

    %{state | task: task, task_kind: :poll}
  end

  defp handle_task_result({:ready, bot}, state) do
    send(self(), :poll)
    %{state | bot: bot, blocked_reason: nil, last_error: nil}
  end

  defp handle_task_result({:blocked, :webhook_configured, bot}, state) do
    Process.send_after(self(), :preflight, @blocked_retry_ms)
    %{state | bot: bot, blocked_reason: :webhook_configured, last_error: nil}
  end

  defp handle_task_result({:ok, next_offset}, state) do
    send(self(), :poll)
    %{state | offset: next_offset, last_error: nil}
  end

  defp handle_task_result({:error, reason, next_offset}, state) do
    Process.send_after(self(), :poll, @retry_ms)
    %{state | offset: next_offset, last_error: sanitize_reason(reason)}
  end

  defp handle_task_result(
         {:error, %Client.Error{error_code: code} = error},
         state
       )
       when code in [401, 403] do
    Process.send_after(self(), :preflight, @blocked_retry_ms)

    %{
      state
      | blocked_reason: operator_block_reason(code),
        last_error: safe_error(error)
    }
  end

  defp handle_task_result({:error, %Client.Error{} = error}, state) do
    Process.send_after(self(), retry_message(state), retry_delay_ms(error))
    %{state | last_error: safe_error(error)}
  end

  defp handle_task_result({:error, reason}, state) do
    Process.send_after(self(), retry_message(state), @retry_ms)
    %{state | last_error: sanitize_reason(reason)}
  end

  defp handle_task_result(_other, state) do
    Process.send_after(self(), retry_message(state), @retry_ms)
    %{state | last_error: :invalid_task_result}
  end

  defp retry_message(%{blocked_reason: reason}) when not is_nil(reason), do: :preflight
  defp retry_message(%{bot: nil}), do: :preflight
  defp retry_message(_state), do: :poll

  defp retry_delay_ms(%Client.Error{error_code: 429, retry_after: seconds})
       when is_integer(seconds) and seconds > 0,
       do: max(seconds * 1_000, @retry_ms)

  defp retry_delay_ms(%Client.Error{}), do: @retry_ms

  defp operator_block_reason(401), do: :authentication_failed
  defp operator_block_reason(403), do: :permission_denied

  defp public_status(state) do
    %{
      key: state.key,
      bot_id: state.bot && state.bot.id,
      bot_username: state.bot && state.bot.username,
      offset: state.offset,
      state: connection_state(state),
      blocked_reason: state.blocked_reason,
      last_error: state.last_error,
      polling?: state.task_kind == :poll
    }
  end

  defp connection_state(%{blocked_reason: reason}) when not is_nil(reason), do: :blocked
  defp connection_state(%{bot: nil}), do: :starting
  defp connection_state(_state), do: :running

  defp normalize_bot(bot_id, bot) do
    %{id: to_string(bot_id), username: Map.get(bot, "username")}
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp fingerprint(value) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(value))
    |> Base.encode16(case: :lower)
  end

  defp safe_error(%Client.Error{} = error) do
    %{
      kind: error.kind,
      error_code: error.error_code,
      retry_after: error.retry_after
    }
  end

  defp sanitize_reason(reason) when is_atom(reason), do: reason
  defp sanitize_reason(%Client.Error{} = error), do: safe_error(error)
  defp sanitize_reason(_reason), do: :telegram_ingress_failed
end
