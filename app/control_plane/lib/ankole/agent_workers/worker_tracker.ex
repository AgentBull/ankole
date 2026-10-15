defmodule Ankole.AgentWorkers.WorkerTracker do
  @moduledoc """
  Connection directory for Worker Channels.

  Every admitted `AnkoleWeb.WorkerChannel` tracks itself under the topic of
  its Worker with its `connection_id` as the key. The metadata holds only
  `incarnation_id`. The topic names the Worker, the key names the connection,
  and the entry supplies the process and node. Heartbeat, load, and capacity
  stay in the PostgreSQL projection.

  The tracker is an eventually consistent directory. `WorkerRoute` reads it
  with `get_by_key/3` to find the process for one route; it never drives a
  durable decision, and no scheduling path lists a whole topic.
  """

  use Phoenix.Tracker

  alias Ankole.Logging

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    configured = Application.get_env(:ankole, __MODULE__, [])

    opts =
      opts
      |> Keyword.put_new(:name, __MODULE__)
      |> Keyword.put_new(:pubsub_server, Ankole.PubSub)
      |> Keyword.put_new(:pool_size, Keyword.get(configured, :pool_size, 1))

    Phoenix.Tracker.start_link(__MODULE__, opts, opts)
  end

  @impl true
  def init(opts), do: {:ok, %{pubsub_server: Keyword.fetch!(opts, :pubsub_server)}}

  @impl true
  def handle_diff(diff, state) do
    Enum.each(diff, fn {topic, {joins, leaves}} ->
      Logging.debug(
        "runtime_fabric.worker_directory_changed",
        "runtime fabric worker directory changed",
        %{topic: topic, joins: length(joins), leaves: length(leaves)}
      )
    end)

    {:ok, state}
  end
end
