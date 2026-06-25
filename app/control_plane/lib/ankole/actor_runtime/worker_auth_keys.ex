defmodule Ankole.ActorRuntime.WorkerAuthKeys do
  @moduledoc """
  Worker-scoped pre-auth key bootstrap service.

  Each stable `worker_id` owns one long-lived pre-auth key (a generated secret)
  used as the password in ZeroMQ's ZAP PLAIN handshake. The native ROUTER calls
  `verify/2` during a worker's connect to authenticate it before any envelope is
  accepted; `bootstrap_key/2` mints (or fetches) the key an operator hands to the
  worker container. This is the identity that the worker-admission layer then
  fences every lifecycle message against.
  """

  import Ecto.Query, warn: false

  alias Ankole.ActorRuntime.Schemas.AgentComputerWorkerAuthKey
  alias Ankole.AppConfigure.GeneratedSecret
  alias Ankole.Repo

  @doc """
  Builds the current Repo database URL for worker auth bootstrap and router ZAP checks.

  The native ROUTER runs its ZAP key lookups by connecting to Postgres directly,
  so it needs the same database URL the Repo uses. When the Repo is configured
  with discrete fields instead of a URL, reconstruct one (URL-encoding each part
  so credentials with special characters survive).
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

  Bootstrap is sticky: an existing key is reused (its secret never rotates here)
  so re-bootstrapping the same worker is idempotent and doesn't invalidate a
  worker that is already connected. A row locked under `FOR UPDATE` keeps two
  concurrent bootstraps from both inserting. A disabled key is refused outright —
  a revoked worker must not be silently re-enabled by asking for its key again.
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

  Called by the ROUTER's ZAP handler on every worker connect. The supplied secret
  is pinned directly in the match (`pre_auth_key: ^pre_auth_key`), so only an
  exact, enabled key authenticates; a disabled key, a wrong key, and an unknown
  worker are each rejected with a distinct reason for operator diagnostics. The
  fallback clause rejects non-binary input so malformed ZAP frames cannot pass.
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

  Operator revocation: sets `disabled_at` so the next `verify/2` (and any future
  bootstrap) is refused. Existing connections are not torn down here — the worker
  is locked out on its next ZAP handshake.
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

  # Worker ids are matched case-insensitively and trimmed so a stray space or
  # casing difference between bootstrap and the ZAP handshake can't lock a worker
  # out of its own key. Must stay consistent across bootstrap/verify/disable.
  defp normalize_worker_id(worker_id), do: worker_id |> String.trim() |> String.downcase()

  defp url_encode(value), do: value |> to_string() |> URI.encode_www_form()
end
