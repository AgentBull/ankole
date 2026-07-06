defmodule Ankole.AIGateway.ProviderRuntime do
  @moduledoc """
  Provider helper runtime context and operator-triggered live checks.

  Model requests use `PrepareContext`; provider helper APIs such as live checks
  and model metadata use this smaller context because they do not run inside an
  actor turn or carry a public request body.
  """

  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.ProviderConfigs.Provider
  alias Ankole.AIGateway.ProviderConnectionCheck
  alias Ankole.AIGateway.Providers

  @default_timeout_ms 15_000

  @doc """
  Builds the provider-facing helper context for live checks and metadata hooks.

  The shape is intentionally map-based because built-in and plugin provider
  callbacks share it. `settings` preserves the existing top-level atom-key view
  of the decrypted runtime connection.
  """
  @spec context(Provider.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def context(%Provider{} = provider, opts \\ []) when is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    capability = Keyword.get(opts, :capability, "llm")

    with {:ok, connection} <- ProviderConfigs.runtime_connection(provider) do
      {:ok,
       %{
         provider_id: provider.provider_id,
         provider_kind: provider.provider_kind,
         capability: capability,
         connection: connection,
         settings: atomize_keys(connection),
         timeout_ms: timeout_ms,
         http_client: Keyword.get(opts, :http_client)
       }}
    end
  end

  @doc """
  Performs an operator-triggered live provider check.

  This intentionally sits outside ordinary turn execution: it decrypts provider
  options just long enough to call the provider-owned connection endpoint, then
  returns a redacted result suitable for Console/API display.
  """
  @spec live_check_provider(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def live_check_provider(provider_id, opts \\ [])

  def live_check_provider(provider_id, opts) when is_binary(provider_id) do
    with {:ok, %Provider{} = provider} <- ProviderConfigs.fetch_active_provider(provider_id),
         {:ok, _result} <- provider_connection_check(provider, opts) do
      {:ok,
       %{
         "status" => "ok",
         "provider_id" => provider.provider_id,
         "provider_kind" => provider.provider_kind,
         "checked_at" => DateTime.utc_now(:microsecond) |> DateTime.to_iso8601()
       }}
    else
      {:error, {:provider_connection_check_failed, status, body}} when is_integer(status) ->
        {:error,
         {:provider_live_check_failed,
          %{
            "http_status" => status,
            "reason" => "upstream_error",
            "body" => truncate_body(body)
          }}}

      {:error, :provider_connection_check_not_supported} = error ->
        error

      {:error, reason}
      when reason in [
             :provider_disabled,
             :missing_base_url,
             :unknown_ai_gateway_provider
           ] ->
        {:error, reason}

      {:error, reason} ->
        {:error, {:provider_live_check_failed, reason}}
    end
  end

  def live_check_provider(_provider_id, _opts), do: {:error, :not_found}

  # Connection checks are optional provider hooks, not model metadata sources.
  defp provider_connection_check(%Provider{} = provider, opts) do
    with {:ok, ctx} <- context(provider, opts),
         {:ok, definition} <- Providers.fetch(provider.provider_kind) do
      case function_exported?(definition.module, :prepare_connection_check, 1) do
        true ->
          with {:ok, check} <- apply(definition.module, :prepare_connection_check, [ctx]) do
            ProviderConnectionCheck.run(check)
          end

        false ->
          {:error, :provider_connection_check_not_supported}
      end
    end
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {String.to_atom(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp truncate_body(body) when is_binary(body), do: String.slice(body, 0, 2_000)
  defp truncate_body(body), do: inspect(body)
end
