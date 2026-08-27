defmodule Ankole.Release do
  @moduledoc """
  One-shot control-plane operations for production releases without Mix installed.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.IdentityProviders.LocalPassword
  alias Ankole.Principals.LocalCredentials
  alias Ankole.Principals.LocalPasswordResetText
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

    {:ok, ^auth_key} = AppConfigure.put_global(WorkerAuthKey.definition(), auth_key)
  end

  @doc "Resets the local sign-in password for one email and prints the new one-time password."
  @spec reset_local_password(String.t()) :: :ok
  def reset_local_password(email) when is_binary(email) do
    load_app()
    {:ok, _apps} = Application.ensure_all_started(:ankole_kernel)

    with_repo(fn _repo ->
      start_child!(Registry)
      start_child!(Cache)

      case LocalCredentials.reset_local_password_by_email(email) do
        {:ok, %{initial_password: initial_password}} ->
          IO.puts(LocalPasswordResetText.success(initial_password))

          case LocalPassword.enabled?() do
            true -> :ok
            false -> IO.puts(LocalPasswordResetText.provider_disabled_warning())
          end

        {:error, :not_found} ->
          raise LocalPasswordResetText.no_account_message(email)

        {:error, reason} ->
          raise "failed to reset the local password: #{inspect(reason)}"
      end
    end)

    :ok
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
