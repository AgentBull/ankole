defmodule Ankole.Plugins.EmailAdapter.ConnectionOwner do
  @moduledoc """
  Owns the mailbox session of one enabled binding.

  The session task holds the IMAP socket. The owner starts it, records its
  status, and starts the next one after a failure with a bounded backoff. An
  authentication failure blocks the owner until the next slow retry, so a
  wrong password does not hammer the mail server.
  """

  use GenServer

  alias Ankole.Logging
  alias Ankole.Plugins.EmailAdapter.{Config, Inbound, MailboxSession}

  @registry Ankole.Plugins.EmailAdapter.ConnectionRegistry
  @task_supervisor Ankole.Plugins.EmailAdapter.SessionTaskSupervisor
  @retry_ms 5_000
  @max_retry_ms 60_000
  @blocked_retry_ms 60_000

  defstruct [
    :key,
    :config,
    :secret_fingerprint,
    :consumer_fingerprint,
    :consumer,
    :task,
    :uidvalidity,
    :blocked_reason,
    :last_error,
    idle: false,
    ready: false,
    failures: 0
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
    # The session task is not linked, so a supervisor shutdown must reach
    # `terminate/2` to kill it; otherwise the old IMAP session outlives its
    # owner and a second one starts on the same mailbox.
    Process.flag(:trap_exit, true)
    config = Config.runtime(Keyword.fetch!(opts, :config))
    consumer = Keyword.fetch!(opts, :consumer)

    {:ok,
     %__MODULE__{
       key: Keyword.fetch!(opts, :key),
       config: config,
       secret_fingerprint: Config.secret_fingerprint(config),
       consumer_fingerprint: fingerprint(consumer),
       consumer: consumer
     }, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, start_session(state)}

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
  def handle_info(:connect, %{task: nil} = state), do: {:noreply, start_session(state)}
  def handle_info(:connect, state), do: {:noreply, state}

  def handle_info({:mailbox_session, pid, {:ready, info}}, %{task: %Task{pid: pid}} = state) do
    {:noreply,
     %{
       state
       | ready: true,
         failures: 0,
         blocked_reason: nil,
         last_error: nil,
         uidvalidity: info.uidvalidity,
         idle: info.idle
     }}
  end

  def handle_info({:mailbox_session, _pid, _event}, state), do: {:noreply, state}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, handle_session_end(result, %{state | task: nil, ready: false})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logging.warning(
      "email_adapter.connection_owner.session_failed",
      "email mailbox session failed",
      %{connection_key: inspect(state.key), reason: sanitize_reason(reason)}
    )

    {:noreply, handle_session_end({:error, :session_crashed}, %{state | task: nil, ready: false})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{task: %Task{} = task}) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp start_session(state) do
    owner = self()
    config = state.config
    consumer = state.consumer

    handler = fn event ->
      case Inbound.handle_message_receive("message", event, [consumer]) do
        {:ok, [result]} -> {:ok, result}
        {:ok, results} -> {:ok, results}
        {:error, _reason} = error -> error
      end
    end

    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        MailboxSession.run(config, handler, owner: owner)
      end)

    %{state | task: task, blocked_reason: nil}
  end

  defp handle_session_end({:blocked, reason}, state) do
    Process.send_after(self(), :connect, @blocked_retry_ms)
    %{state | blocked_reason: reason, last_error: nil}
  end

  defp handle_session_end({:error, reason}, state) do
    failures = state.failures + 1
    delay = min(@retry_ms * Integer.pow(2, failures - 1), @max_retry_ms)
    Process.send_after(self(), :connect, delay)
    %{state | failures: failures, last_error: sanitize_reason(reason)}
  end

  defp handle_session_end(_other, state) do
    Process.send_after(self(), :connect, @retry_ms)
    %{state | last_error: :invalid_session_result}
  end

  defp public_status(state) do
    %{
      key: state.key,
      address: state.config.address,
      state: connection_state(state),
      blocked_reason: state.blocked_reason,
      last_error: state.last_error,
      uidvalidity: state.uidvalidity,
      idle?: state.idle
    }
  end

  defp connection_state(%{blocked_reason: reason}) when not is_nil(reason), do: :blocked
  defp connection_state(%{ready: true}), do: :running
  defp connection_state(_state), do: :starting

  defp fingerprint(value) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(value))
    |> Base.encode16(case: :lower)
  end

  defp sanitize_reason(reason) when is_atom(reason), do: reason
  defp sanitize_reason({kind, detail}) when is_atom(kind) and is_atom(detail), do: {kind, detail}
  defp sanitize_reason({kind, _detail}) when is_atom(kind), do: kind
  defp sanitize_reason(_reason), do: :email_session_failed
end
