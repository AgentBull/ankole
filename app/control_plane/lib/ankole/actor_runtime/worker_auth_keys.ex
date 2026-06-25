defmodule Ankole.ActorRuntime.WorkerAuthKeys do
  @moduledoc """
  Worker-scoped pre-auth key bootstrap service.
  """

  import Ecto.Query, warn: false

  alias Ankole.ActorRuntime.Schemas.AgentComputerWorkerAuthKey
  alias Ankole.AppConfigure.GeneratedSecret
  alias Ankole.Repo

  @doc """
  Builds the current Repo database URL for worker auth bootstrap and router ZAP checks.
  """
  @spec database_url!() :: String.t()
  def database_url! do
    config = Repo.config()

    case Keyword.get(config, :url) do
      url when is_binary(url) and url != "" ->
        url

      _value ->
        username = Keyword.fetch!(config, :username)
        password = Keyword.get(config, :password, "")
        hostname = Keyword.get(config, :hostname, "localhost")
        port = Keyword.get(config, :port, 5432)
        database = Keyword.fetch!(config, :database)

        "postgresql://#{url_encode(username)}:#{url_encode(password)}@#{hostname}:#{port}/#{url_encode(database)}"
    end
  end

  @doc """
  Fetches or creates the pre-auth key for a stable worker id.
  """
  @spec bootstrap_key(String.t(), keyword()) ::
          {:ok, AgentComputerWorkerAuthKey.t()} | {:error, term()}
  def bootstrap_key(worker_id, opts \\ []) when is_binary(worker_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      case lock_key(repo, worker_id) do
        %AgentComputerWorkerAuthKey{disabled_at: %DateTime{}} ->
          {:error, :worker_auth_key_disabled}

        %AgentComputerWorkerAuthKey{} = auth_key ->
          auth_key
          |> AgentComputerWorkerAuthKey.changeset(%{last_bootstrap_at: now})
          |> repo.update()

        nil ->
          %AgentComputerWorkerAuthKey{}
          |> AgentComputerWorkerAuthKey.changeset(%{
            worker_id: worker_id,
            pre_auth_key: GeneratedSecret.generate(),
            key_revision: 1,
            last_bootstrap_at: now
          })
          |> repo.insert()
      end
    end)
  end

  @doc """
  Verifies a worker id/password pair for ZAP PLAIN semantics.
  """
  @spec verify(String.t(), String.t()) :: {:ok, AgentComputerWorkerAuthKey.t()} | {:error, term()}
  def verify(worker_id, pre_auth_key) when is_binary(worker_id) and is_binary(pre_auth_key) do
    case Repo.get(AgentComputerWorkerAuthKey, normalize_worker_id(worker_id)) do
      %AgentComputerWorkerAuthKey{disabled_at: nil, pre_auth_key: ^pre_auth_key} = auth_key ->
        {:ok, auth_key}

      %AgentComputerWorkerAuthKey{disabled_at: %DateTime{}} ->
        {:error, :worker_auth_key_disabled}

      %AgentComputerWorkerAuthKey{} ->
        {:error, :invalid_worker_auth_key}

      nil ->
        {:error, :worker_auth_key_not_found}
    end
  end

  def verify(_worker_id, _pre_auth_key), do: {:error, :invalid_worker_auth_key}

  @doc """
  Disables one worker key.
  """
  @spec disable(String.t()) :: {:ok, AgentComputerWorkerAuthKey.t()} | {:error, term()}
  def disable(worker_id) do
    now = DateTime.utc_now(:microsecond)

    Repo.transact(fn repo ->
      case lock_key(repo, worker_id) do
        %AgentComputerWorkerAuthKey{} = auth_key ->
          auth_key
          |> AgentComputerWorkerAuthKey.changeset(%{disabled_at: now})
          |> repo.update()

        nil ->
          {:error, :worker_auth_key_not_found}
      end
    end)
  end

  defp lock_key(repo, worker_id) do
    AgentComputerWorkerAuthKey
    |> where([auth_key], auth_key.worker_id == ^normalize_worker_id(worker_id))
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp normalize_worker_id(worker_id), do: worker_id |> String.trim() |> String.downcase()

  defp url_encode(value), do: value |> to_string() |> URI.encode_www_form()
end
