defmodule Ankole.Plugins.LarkAdapter.CardKit.WriteLimiter do
  @moduledoc """
  Sets a minimum interval between CardKit writes for each Lark application.

  The server keeps a separate queue for each application and does not sleep in
  a call handler. Thus, one application does not block a different application.
  """

  use GenServer

  @default_interval_ms 1_000

  @type app_state :: %{
          last_send_at: integer(),
          waiting: :queue.queue(GenServer.from())
        }

  @type state :: %{interval_ms: non_neg_integer(), apps: %{String.t() => app_state()}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts =
      :ankole
      |> Application.get_env(__MODULE__, [])
      |> Keyword.merge(opts)

    name = Keyword.get(opts, :name, __MODULE__)

    case name do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Waits until the application can start its next CardKit write.
  """
  @spec wait(String.t(), GenServer.server()) :: :ok
  def wait(app_id, server \\ __MODULE__)
      when is_binary(app_id) and byte_size(app_id) > 0 do
    GenServer.call(server, {:wait, app_id}, :infinity)
  end

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)

    if is_integer(interval_ms) and interval_ms >= 0 do
      {:ok, %{interval_ms: interval_ms, apps: %{}}}
    else
      {:stop, {:invalid_interval_ms, interval_ms}}
    end
  end

  @impl true
  def handle_call({:wait, app_id}, from, state) do
    now = System.monotonic_time(:millisecond)

    case Map.get(state.apps, app_id) do
      nil ->
        app = %{last_send_at: now, waiting: :queue.new()}
        {:reply, :ok, put_in(state.apps[app_id], app)}

      %{waiting: waiting} = app ->
        if :queue.is_empty(waiting) do
          wait_or_send(app_id, app, from, now, state)
        else
          app = %{app | waiting: :queue.in(from, waiting)}
          {:noreply, put_in(state.apps[app_id], app)}
        end
    end
  end

  @impl true
  def handle_info({:release, app_id}, state) do
    app = Map.fetch!(state.apps, app_id)
    {{:value, from}, waiting} = :queue.out(app.waiting)
    now = System.monotonic_time(:millisecond)
    GenServer.reply(from, :ok)

    unless :queue.is_empty(waiting) do
      Process.send_after(self(), {:release, app_id}, state.interval_ms)
    end

    app = %{app | last_send_at: now, waiting: waiting}
    {:noreply, put_in(state.apps[app_id], app)}
  end

  defp wait_or_send(app_id, app, from, now, state) do
    delay_ms = max(app.last_send_at + state.interval_ms - now, 0)

    case delay_ms do
      0 ->
        app = %{app | last_send_at: now}
        {:reply, :ok, put_in(state.apps[app_id], app)}

      delay_ms ->
        Process.send_after(self(), {:release, app_id}, delay_ms)
        app = %{app | waiting: :queue.in(from, app.waiting)}
        {:noreply, put_in(state.apps[app_id], app)}
    end
  end
end
