defmodule Ankole.AIGateway.ResponsesPreparation do
  @moduledoc """
  One preparation path for Responses JSON, SSE, and WebSocket transports.

  The ordinary single-upstream spec remains unchanged when no hosted tool is
  declared. Hosted tools add a private composite spec consumed inside Kernel.
  """

  alias Ankole.AIGateway.CompactionArtifacts
  alias Ankole.AIGateway.HostedTools.ImageGeneration
  alias Ankole.AIGateway.MapUtils
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.Resolver

  @hosted_max_bytes 128 * 1024 * 1024
  @hosted_total_timeout_ms 30 * 60 * 1000

  @type prepared :: %{
          required(:request) => map(),
          required(:runtime) => map(),
          required(:spec) => map()
        }

  @spec prepare(String.t(), map(), keyword()) :: {:ok, prepared()} | {:error, term()}
  def prepare(subject_uid, request, opts \\ []) when is_map(request) do
    request = MapUtils.normalize_request_keys(request)

    with {:ok, request} <- CompactionArtifacts.resolve_request_input_handles(subject_uid, request),
         {:ok, runtime} <- Resolver.resolve_request_model(subject_uid, "llm", request) do
      build(subject_uid, runtime, request, opts)
    end
  end

  @spec prepare_with_runtime(String.t(), map(), map(), keyword()) ::
          {:ok, prepared()} | {:error, term()}
  def prepare_with_runtime(subject_uid, runtime, request, opts \\ [])
      when is_map(runtime) and is_map(request) do
    request = MapUtils.normalize_request_keys(request)

    with {:ok, request} <- CompactionArtifacts.resolve_request_input_handles(subject_uid, request) do
      build(subject_uid, runtime, request, opts)
    end
  end

  defp build(subject_uid, runtime, request, opts) do
    stream? = Keyword.get(opts, :stream?, false)

    with {:ok, image_generation} <-
           ImageGeneration.prepare(subject_uid, request, stream?: stream?),
         {:ok, main_spec} <-
           Providers.build_response_request(runtime, provider_request(request),
             stream?: stream? and is_nil(image_generation)
           ) do
      {:ok,
       %{
         request: request,
         runtime: runtime,
         spec: composite_spec(main_spec, request, image_generation)
       }}
    end
  end

  defp provider_request(request), do: Map.delete(request, "service_tier")

  defp composite_spec(main_spec, _request, nil), do: main_spec

  defp composite_spec(main_spec, request, image_generation) do
    main_spec
    |> ensure_hosted_total_timeout()
    |> Map.put(:hosted_tools, %{
      image_generation: image_generation,
      public_request: request
    })
    |> Map.update(:limits, hosted_limits(), &Map.merge(hosted_limits(), &1))
  end

  defp ensure_hosted_total_timeout(%{upstream: %{timeout: timeout} = upstream} = spec) do
    total_ms =
      Map.get(timeout, :total_ms) ||
        Map.get(timeout, :first_byte_ms) ||
        @hosted_total_timeout_ms

    Map.put(spec, :upstream, Map.put(upstream, :timeout, Map.put(timeout, :total_ms, total_ms)))
  end

  defp hosted_limits do
    %{
      max_response_bytes: @hosted_max_bytes,
      max_sse_event_bytes: @hosted_max_bytes,
      max_websocket_text_bytes: @hosted_max_bytes,
      max_pending_bytes: @hosted_max_bytes
    }
  end
end
