defmodule Ankole.RuntimeEvents.Supervisor do
  @moduledoc false

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children = [
      {Task.Supervisor, name: Ankole.RuntimeEvents.TaskSupervisor},
      {Postgrex.Notifications, notifications_opts(opts)},
      {Ankole.RuntimeEvents.Scheduler, Keyword.get(opts, :scheduler, [])},
      {Ankole.RuntimeEvents.Listener, Keyword.get(opts, :listener, [])}
    ]

    # The notification connection owns LISTEN registrations. Postgrex restores
    # them after a database reconnect, and the scheduler sweep recovers durable
    # events missed during the disconnect. If the process itself restarts, the
    # listener and scheduler restart behind it and repeat LISTEN -> snapshot.
    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp notifications_opts(opts) do
    repo = Keyword.get(opts, :repo, Ankole.Repo)

    repo.config()
    |> Keyword.take([
      :url,
      :hostname,
      :port,
      :database,
      :username,
      :password,
      :socket_dir,
      :ssl,
      :ssl_opts,
      :parameters,
      :timeout,
      :connect_timeout,
      :idle_interval
    ])
    |> Keyword.merge(
      Keyword.get(opts, :notifications, [])
      |> Keyword.put_new(:name, Ankole.RuntimeEvents.Notifications)
      |> Keyword.put(:auto_reconnect, true)
    )
  end
end
