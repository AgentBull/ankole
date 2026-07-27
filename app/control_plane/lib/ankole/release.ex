defmodule Ankole.Release do
  @moduledoc """
  One-shot control-plane operations for production releases without Mix installed.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Repo
  alias Ankole.Schedule
  alias Ankole.SignalsGateway.ActorRuntime.WorkerAuthKey

  @app :ankole

  @doc "Runs all pending database migrations."
  @spec migrate() :: :ok
  def migrate do
    load_app()
    with_repo(&Ecto.Migrator.run(&1, :up, all: true))

    with_repo(fn _repo ->
      with_release_oban(&reconcile_cron_schedules!/0)
    end)

    :ok
  end

  @doc "Persists the deployment-provided RuntimeFabric worker authentication key."
  @spec bootstrap_worker_auth_key() :: :ok
  def bootstrap_worker_auth_key do
    load_app()
    {:ok, _apps} = Application.ensure_all_started(:ankole_kernel)

    with_repo(fn _repo -> persist_worker_auth_key!() end)

    :ok
  end

  defp persist_worker_auth_key! do
    start_child!(Registry)
    start_child!(Cache)

    auth_key = System.fetch_env!("ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY")

    :ok = WorkerAuthKey.ensure_registered()
    {:ok, ^auth_key} = AppConfigure.put_global(WorkerAuthKey.definition(), auth_key)
  end

  defp reconcile_cron_schedules! do
    case Schedule.reconcile_cron_schedules() do
      {:ok, _result} -> :ok
      {:error, reason} -> raise "failed to reconcile cron schedules: #{inspect(reason)}"
    end
  end

  defp with_release_oban(fun) do
    {:ok, _apps} = Application.ensure_all_started(:oban)

    oban_opts =
      :ankole
      |> Application.fetch_env!(Oban)
      |> Keyword.merge(plugins: false, queues: false)

    case Oban.start_link(oban_opts) do
      {:ok, pid} ->
        try do
          fun.()
        after
          Supervisor.stop(pid)
        end

      {:error, {:already_started, _pid}} ->
        fun.()

      {:error, reason} ->
        raise "failed to start release Oban: #{inspect(reason)}"
    end
  end

  defp start_child!(module) do
    case module.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> raise "failed to start #{inspect(module)}: #{inspect(reason)}"
    end
  end

  defp with_repo(fun) do
    {:ok, result, _apps} = Ecto.Migrator.with_repo(Repo, fun)
    result
  end

  defp load_app do
    {:ok, _apps} = Application.ensure_all_started(:ssl)
    :ok = Application.ensure_loaded(@app)
  end
end
