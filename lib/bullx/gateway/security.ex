defmodule BullX.Gateway.Security do
  @moduledoc false

  alias BullX.Gateway.{InboundError, SourceConfig}

  @callback check_inbound(SourceConfig.t(), map()) ::
              :allow | {:deny, String.t(), map()} | {:error, term()}
  @callback sanitize_outbound(term(), SourceConfig.t()) :: {:ok, term()} | {:error, term()}

  @spec check_inbound(SourceConfig.t(), map()) :: :allow | {:error, InboundError.t()}
  def check_inbound(%SourceConfig{} = source, input) do
    source
    |> module()
    |> safe_check_inbound(source, input)
  end

  @spec sanitize_outbound(term(), SourceConfig.t()) :: {:ok, term()} | {:error, term()}
  def sanitize_outbound(delivery, %SourceConfig{} = source) do
    source
    |> module()
    |> safe_sanitize_outbound(delivery, source)
  end

  defp module(_source) do
    :bullx
    |> Application.get_env(:gateway, [])
    |> Keyword.get(:security, BullX.Gateway.Security.Default)
  end

  defp safe_check_inbound(module, source, input) do
    case module.check_inbound(source, input) do
      :allow ->
        :allow

      {:deny, message, details} ->
        {:error, InboundError.new(:security_denied, message, details)}

      {:error, reason} ->
        {:error,
         InboundError.new(:security_denied, "security denied", %{reason: inspect(reason)})}

      _other ->
        {:error, InboundError.new(:security_denied, "invalid security hook result")}
    end
  catch
    :exit, reason ->
      {:error,
       InboundError.new(:security_denied, "security hook exited", %{reason: inspect(reason)})}

    kind, reason ->
      {:error,
       InboundError.new(:security_denied, "security hook failed", %{
         kind: kind,
         reason: inspect(reason)
       })}
  end

  defp safe_sanitize_outbound(module, delivery, source) do
    case module.sanitize_outbound(delivery, source) do
      {:ok, delivery} -> {:ok, delivery}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_security_hook_result}
    end
  catch
    :exit, reason -> {:error, {:security_exit, reason}}
    kind, reason -> {:error, {kind, reason}}
  end
end

defmodule BullX.Gateway.Security.Default do
  @moduledoc false

  @behaviour BullX.Gateway.Security

  alias BullX.Gateway.SourceConfig

  @impl true
  def check_inbound(%SourceConfig{enabled?: true} = source, input) do
    case {Map.get(input, "adapter"), Map.get(input, "channel_id")} do
      {nil, nil} ->
        :allow

      {adapter, channel_id} ->
        check_source_match(source, adapter, channel_id)
    end
  end

  def check_inbound(_source, _input), do: {:deny, "source disabled", %{}}

  @impl true
  def sanitize_outbound(delivery, _source), do: {:ok, delivery}

  defp check_source_match(source, adapter, channel_id)
       when is_binary(adapter) and is_binary(channel_id) do
    case SourceConfig.canonical_key(source) == SourceConfig.canonical_key({adapter, channel_id}) do
      true -> :allow
      false -> {:deny, "normalized source mismatch", %{}}
    end
  end

  defp check_source_match(_source, _adapter, _channel_id),
    do: {:deny, "invalid source identity", %{}}
end
