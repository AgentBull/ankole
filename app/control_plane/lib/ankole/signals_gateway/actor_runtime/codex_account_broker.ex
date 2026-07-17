defmodule Ankole.SignalsGateway.ActorRuntime.CodexAccountBroker do
  @moduledoc """
  Turn-fenced Codex account material for one active job worker.
  """

  alias Ankole.AIAgent.CodexAccounts
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job

  @spec handle_resolve(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_resolve(%TurnRef{} = turn_ref, request, _route) do
    request_id = request_id(request, "resolve")
    job_id = RPCWire.text(request, "job_id") || ""

    with {:ok, %Job{} = job} <- job_for_turn(turn_ref, job_id),
         :ok <- require_subscription_account(job.codex_account_id),
         {:ok, resolved} <- CodexAccounts.resolve_auth(job.codex_account_id) do
      {:ok,
       %{
         "request_id" => request_id,
         "account_id" => resolved.account_id,
         "auth_json" => resolved.auth_json,
         "auth_hash" => resolved.auth_hash
       }}
    else
      {:error, reason} -> error(request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_update_auth(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_update_auth(%TurnRef{} = turn_ref, request, _route) do
    request_id = request_id(request, "update")
    job_id = RPCWire.text(request, "job_id") || ""
    auth_json = RPCWire.text(request, "auth_json")

    with {:ok, %Job{} = job} <- job_for_turn(turn_ref, job_id),
         :ok <- require_subscription_account(job.codex_account_id),
         auth_json when is_binary(auth_json) <- auth_json,
         {:ok, account} <- CodexAccounts.update_auth(job.codex_account_id, auth_json) do
      {:ok,
       %{
         "request_id" => request_id,
         "account_id" => account.account_id
       }}
    else
      nil -> error(request_id, turn_ref.agent_uid, :codex_auth_json_missing)
      {:error, reason} -> error(request_id, turn_ref.agent_uid, reason)
    end
  end

  defp job_for_turn(%TurnRef{} = turn_ref, job_id) do
    with {:ok, ^job_id} <- BackgroundAgentJobs.parse_job_session_id(turn_ref.session_id),
         %Job{} = job <-
           BackgroundAgentJobs.get_job_for_agent(job_id, turn_ref.agent_uid) do
      {:ok, job}
    else
      nil -> {:error, :job_not_found}
      _value -> {:error, :background_agent_job_turn_mismatch}
    end
  end

  defp require_subscription_account("aigateway"), do: {:error, :codex_account_not_configured}
  defp require_subscription_account(account_id) when is_binary(account_id), do: :ok
  defp require_subscription_account(_account_id), do: {:error, :codex_account_not_configured}

  defp request_id(request, action) do
    RPCWire.text(request, "request_id") || "codex-account-#{action}-#{Ecto.UUID.generate()}"
  end

  defp error(request_id, agent_uid, reason) do
    {:error,
     RPCWire.error_payload(request_id, reason,
       fallback_code: "codex_account_failed",
       changeset_code: "invalid_codex_account",
       message_style: :tuple_inspect,
       details_json: %{"agent_uid" => agent_uid}
     )}
  end
end
