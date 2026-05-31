defmodule BullX.AIAgent.ACL do
  @moduledoc """
  Narrow AIAgent access gate backed by `BullX.AuthZ`.

  In an OpenClaw / Hermes-style harness, tool access is configured *per
  agent* — the operator decides which tools the assistant can call, and that
  configuration applies to every invocation. BullX gates *per call*: every
  invocation carries the triggering caller's Principal, and ACL answers two
  questions for that specific call against this specific Agent — "may this
  caller talk to this Agent at all?" and "does this caller also hold the
  privileged grant for tools tagged that way?". Tool schemas are rendered from
  ToolSet/profile/availability state; ACL is enforced when the dispatcher
  handles a concrete tool call.

  ACL does not own a separate policy store; the actual grants live in the
  general authorization system (`BullX.AuthZ`). Future Budget, Approval,
  channel-send, and Capability checks should reuse the same Principal/AuthZ
  boundary when those surfaces are implemented.
  """

  alias BullX.AuthZ

  @type operation_tag :: :ordinary | :privileged
  @type decision :: :allowed | {:denied, atom()} | {:error, term()}

  @spec resource(String.t()) :: String.t()
  def resource(agent_uid) when is_binary(agent_uid) do
    "ai_agent:" <> agent_uid
  end

  @spec authorize(String.t(), String.t(), operation_tag(), map()) :: decision()
  def authorize(caller_principal_uid, agent_uid, operation_tag, context \\ %{})

  def authorize(caller_principal_uid, agent_uid, operation_tag, context)
      when is_binary(caller_principal_uid) and is_binary(agent_uid) and is_map(context) do
    sanitized_context = sanitize_context(context)
    resource = resource(agent_uid)

    with {:ok, actions} <- operation_actions(operation_tag),
         :ok <- authz(caller_principal_uid, resource, actions, sanitized_context) do
      :allowed
    else
      {:denied, reason} -> {:denied, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  def authorize(_caller_principal_uid, _agent_uid, _operation_tag, _context),
    do: {:denied, :invalid_request}

  @spec allowed?(String.t(), String.t(), operation_tag(), map()) :: boolean()
  def allowed?(caller_principal_uid, agent_uid, operation_tag, context \\ %{}) do
    authorize(caller_principal_uid, agent_uid, operation_tag, context) == :allowed
  end

  defp operation_actions(:ordinary), do: {:ok, ["invoke"]}
  defp operation_actions(:privileged), do: {:ok, ["invoke", "invoke_privileged"]}
  defp operation_actions(_operation_tag), do: {:denied, :invalid_operation_tag}

  defp authz(caller, resource, actions, context) do
    case AuthZ.authorize_all(caller, resource, actions, context) do
      :ok ->
        :ok

      {:error, reason}
      when reason in [:forbidden, :principal_disabled, :not_found, :invalid_request] ->
        {:denied, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sanitize_context(context) do
    context
    |> Map.take([
      :input_mode,
      :connected_realm_id,
      :channel_kind,
      :web_session?,
      :trigger_type,
      :trigger_id,
      "input_mode",
      "connected_realm_id",
      "channel_kind",
      "web_session?",
      "trigger_type",
      "trigger_id"
    ])
    |> Map.new(fn {key, value} ->
      {normalize_context_key(key), normalize_context_value(value)}
    end)
  end

  defp normalize_context_key(key) when is_atom(key), do: key
  defp normalize_context_key(key) when is_binary(key), do: key

  defp normalize_context_value(value) when is_binary(value), do: String.slice(value, 0, 200)
  defp normalize_context_value(value) when is_atom(value), do: value
  defp normalize_context_value(value) when is_boolean(value), do: value
  defp normalize_context_value(value) when is_integer(value), do: value
  defp normalize_context_value(_value), do: nil
end
