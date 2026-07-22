defmodule Ankole.SignalsGateway.ActorRuntime.CodexAccountBroker do
  @moduledoc """
  Turn-fenced Codex account material for one active job worker.
  """

  alias Ankole.AIAgent.CodexAccounts
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef

  @spec handle_resolve(TurnRef.t(), FabricProto.CodexAccountResolveRequest.t(), map()) ::
          {:ok, FabricProto.CodexAccountResolveResponse.t()} | {:error, map()}
  def handle_resolve(
        %TurnRef{} = turn_ref,
        %FabricProto.CodexAccountResolveRequest{} = request,
        ctx
      ) do
    with {:ok, %Job{} = job} <- job_for_turn(turn_ref, request.job_id),
         :ok <- require_subscription_account(job.codex_account_id),
         {:ok, resolved} <- CodexAccounts.resolve_auth(job.codex_account_id),
         {:ok, config} <- codex_subscription_config(job) do
      {:ok,
       %FabricProto.CodexAccountResolveResponse{
         account_id: resolved.account_id,
         auth_json: resolved.auth_json,
         auth_hash: resolved.auth_hash,
         model: config["model"],
         model_reasoning_effort: config["model_reasoning_effort"],
         fast_mode: config["fast_mode"]
       }}
    else
      {:error, reason} -> error(ctx.request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_update_auth(TurnRef.t(), FabricProto.CodexAccountAuthUpdateRequest.t(), map()) ::
          {:ok, FabricProto.CodexAccountAuthUpdateResponse.t()} | {:error, map()}
  def handle_update_auth(
        %TurnRef{} = turn_ref,
        %FabricProto.CodexAccountAuthUpdateRequest{} = request,
        ctx
      ) do
    with {:ok, %Job{} = job} <- job_for_turn(turn_ref, request.job_id),
         :ok <- require_subscription_account(job.codex_account_id),
         auth_json when is_binary(auth_json) <- presence(request.auth_json),
         {:ok, account} <- CodexAccounts.update_auth(job.codex_account_id, auth_json) do
      {:ok, %FabricProto.CodexAccountAuthUpdateResponse{account_id: account.account_id}}
    else
      nil -> error(ctx.request_id, turn_ref.agent_uid, :codex_auth_json_missing)
      {:error, reason} -> error(ctx.request_id, turn_ref.agent_uid, reason)
    end
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _trimmed -> value
    end
  end

  defp presence(_value), do: nil

  defp job_for_turn(%TurnRef{} = turn_ref, job_id) do
    with {:ok, job_id} <- BackgroundAgentJobs.parse_job_id(job_id),
         {:ok, ^job_id} <- BackgroundAgentJobs.parse_job_session_id(turn_ref.session_id),
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

  defp codex_subscription_config(%Job{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "codex_subscription") do
      nil -> ModelProfiles.codex_subscription_config(%{})
      %{} = config -> ModelProfiles.codex_subscription_config(config)
      _value -> {:error, :invalid_codex_account_profile}
    end
  end

  defp codex_subscription_config(%Job{}), do: ModelProfiles.codex_subscription_config(%{})

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
