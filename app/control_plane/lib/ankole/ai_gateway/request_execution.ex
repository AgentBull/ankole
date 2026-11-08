defmodule Ankole.AIGateway.RequestExecution do
  @moduledoc false

  alias Ankole.AIGateway.CredentialAttempts
  alias Ankole.AIGateway.FailureDiagnostics
  alias Ankole.AIGateway.HostedTools.ImageGeneration
  alias Ankole.AIGateway.UniversalAIRequest

  @spec execute_prepared_request(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute_prepared_request(runtime, prepared_request, opts) do
    started_at = System.monotonic_time()

    case CredentialAttempts.request(prepared_request, opts) do
      {:error, reason} = error ->
        log_request_failure(runtime, prepared_request, reason, started_at)
        error

      result ->
        result
    end
  end

  @spec request_upstream_host(term()) :: String.t() | nil
  def request_upstream_host(%UniversalAIRequest{path: path, ctx: ctx}) do
    url =
      if String.starts_with?(path, ["https://", "http://"]) do
        path
      else
        UniversalAIRequest.setting(ctx, :base_url)
      end

    case url do
      value when is_binary(value) -> URI.parse(value).host
      _value -> nil
    end
  end

  def request_upstream_host(%{upstream: %{url: url}}) when is_binary(url),
    do: URI.parse(url).host

  def request_upstream_host(%{"upstream" => %{"url" => url}}) when is_binary(url),
    do: URI.parse(url).host

  def request_upstream_host(_prepared_request), do: nil

  # Keeps transport response data separate from model resolution facts. The body
  # must stay provider-contract compatible; internal trace facts belong in
  # `model_ref`, telemetry, or durable turn metadata.
  @spec gateway_response(pos_integer(), map(), map()) :: map()
  def gateway_response(status, body, runtime) do
    %{
      status: status,
      body: body,
      model_ref: %{
        "provider_id" => runtime["provider_id"],
        "provider_kind" => runtime["provider_kind"],
        "model" => runtime["model"],
        "selector" => runtime["selector"],
        "capability" => runtime["capability"]
      }
    }
  end

  defp log_request_failure(runtime, prepared_request, reason, started_at) do
    context =
      if Map.has_key?(prepared_request, :hosted_tools),
        do: ImageGeneration.failure_log_fields(prepared_request, reason),
        else: %{}

    FailureDiagnostics.log(
      "ai_gateway.request_failed",
      "AIGateway provider request failed",
      Map.merge(context, %{
        capability: runtime["capability"],
        provider_id: runtime["provider_id"],
        provider_kind: runtime["provider_kind"],
        model: runtime["model"],
        api_resolver: prepared_request.api_resolver,
        upstream_host: request_upstream_host(prepared_request),
        duration_ms:
          System.monotonic_time()
          |> Kernel.-(started_at)
          |> System.convert_time_unit(:native, :millisecond)
      }),
      reason
    )
  end
end
