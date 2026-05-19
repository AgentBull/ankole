defmodule BullX.AIAgent.ACL do
  @moduledoc """
  Narrow AIAgent access gate backed by `BullX.AuthZ`.

  The gate answers whether a caller may invoke one Agent Principal, and whether
  the same caller also has the extra grant needed for a privileged operation.
  It does not introduce an ACL-specific policy store.
  """

  alias BullX.AIAgent.Profile
  alias BullX.AuthZ

  @type operation_tag :: :ordinary | :privileged
  @type decision :: :allowed | {:denied, atom()} | {:error, term()}

  @spec resource(String.t()) :: String.t()
  def resource(agent_principal_id) when is_binary(agent_principal_id) do
    "ai_agent:" <> agent_principal_id
  end

  @spec authorize(String.t(), String.t(), operation_tag(), map()) :: decision()
  def authorize(caller_principal_id, agent_principal_id, operation_tag, context \\ %{})

  def authorize(caller_principal_id, agent_principal_id, operation_tag, context)
      when is_binary(caller_principal_id) and is_binary(agent_principal_id) and is_map(context) do
    sanitized_context = sanitize_context(context)
    resource = resource(agent_principal_id)

    with :ok <- authz(caller_principal_id, resource, "invoke", sanitized_context),
         :ok <-
           authorize_operation(caller_principal_id, resource, operation_tag, sanitized_context) do
      :allowed
    else
      {:denied, reason} -> {:denied, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  def authorize(_caller_principal_id, _agent_principal_id, _operation_tag, _context),
    do: {:denied, :invalid_request}

  @spec allowed?(String.t(), String.t(), operation_tag(), map()) :: boolean()
  def allowed?(caller_principal_id, agent_principal_id, operation_tag, context \\ %{}) do
    authorize(caller_principal_id, agent_principal_id, operation_tag, context) == :allowed
  end

  @spec filter_allowed_tags(String.t(), String.t(), map()) :: MapSet.t(operation_tag())
  def filter_allowed_tags(caller_principal_id, agent_principal_id, context \\ %{}) do
    [:ordinary, :privileged]
    |> Enum.filter(&(authorize(caller_principal_id, agent_principal_id, &1, context) == :allowed))
    |> MapSet.new()
  end

  @spec validate_profile(Profile.t()) :: :ok | {:error, {:invalid_profile, [String.t()]}}
  def validate_profile(%Profile{acl: %{elevation_strategy: :deny}}), do: :ok

  def validate_profile(%Profile{}) do
    {:error, {:invalid_profile, ["acl.elevation_strategy must be deny"]}}
  end

  defp authorize_operation(_caller, _resource, :ordinary, _context), do: :ok

  defp authorize_operation(caller, resource, :privileged, context) do
    authz(caller, resource, "invoke_privileged", context)
  end

  defp authorize_operation(_caller, _resource, _operation_tag, _context),
    do: {:denied, :invalid_operation_tag}

  defp authz(caller, resource, action, context) do
    case AuthZ.authorize(caller, resource, action, context) do
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
      :source_type,
      :source_id,
      "input_mode",
      "connected_realm_id",
      "channel_kind",
      "web_session?",
      "source_type",
      "source_id"
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
