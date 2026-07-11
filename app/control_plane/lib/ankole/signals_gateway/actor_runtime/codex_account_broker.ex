defmodule Ankole.SignalsGateway.ActorRuntime.CodexAccountBroker do
  @moduledoc """
  Turn-fenced Codex account material for one active delegation worker.
  """

  alias Ankole.AIAgent.CodexAccounts
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SubagentDelegations
  alias Ankole.SubagentDelegations.Schemas.Delegation

  @spec handle_resolve(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_resolve(%TurnRef{} = turn_ref, request, _route) do
    request_id = request_id(request, "resolve")
    delegation_id = RPCWire.text(request, "delegation_id") || ""

    with {:ok, %Delegation{} = delegation} <- delegation_for_turn(turn_ref, delegation_id),
         :ok <- require_subscription_account(delegation.codex_account_id),
         {:ok, resolved} <- CodexAccounts.resolve_auth(delegation.codex_account_id) do
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
    delegation_id = RPCWire.text(request, "delegation_id") || ""
    auth_json = RPCWire.text(request, "auth_json")

    with {:ok, %Delegation{} = delegation} <- delegation_for_turn(turn_ref, delegation_id),
         :ok <- require_subscription_account(delegation.codex_account_id),
         auth_json when is_binary(auth_json) <- auth_json,
         {:ok, account} <- CodexAccounts.update_auth(delegation.codex_account_id, auth_json) do
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

  defp delegation_for_turn(%TurnRef{} = turn_ref, delegation_id) do
    with "subagent:" <> ^delegation_id <- turn_ref.session_id,
         %Delegation{} = delegation <-
           SubagentDelegations.get_delegation_for_agent(delegation_id, turn_ref.agent_uid) do
      {:ok, delegation}
    else
      nil -> {:error, :delegation_not_found}
      _value -> {:error, :subagent_delegation_turn_mismatch}
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
