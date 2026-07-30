defmodule Ankole.AIGateway.ResponsesPreparation do
  @moduledoc """
  One preparation path for Responses JSON, SSE, and WebSocket transports.

  The ordinary single-upstream spec remains unchanged when no hosted tool is
  declared. Hosted tools add a private composite spec consumed inside Kernel.
  """

  alias Ankole.AIGateway.CompactionArtifacts
  alias Ankole.AIGateway.ChatGPTProtocol
  alias Ankole.AIGateway.CredentialAttempts
  alias Ankole.AIGateway.HostedTools.ImageGeneration
  alias Ankole.AIGateway.MapUtils
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.RequestContext
  alias Ankole.AIGateway.Resolver
  alias Ankole.AIGateway.ToolSearch

  @hosted_max_bytes 128 * 1024 * 1024
  @hosted_total_timeout_ms 30 * 60 * 1000

  @type prepared :: %{
          required(:request) => map(),
          required(:runtime) => map(),
          required(:spec) => map()
        }

  @spec prepare(String.t(), map(), keyword()) :: {:ok, prepared()} | {:error, term()}
  def prepare(subject_uid, request, opts \\ []) when is_map(request) do
    with {:ok, request, runtime} <- resolve_request_runtime(subject_uid, request, opts) do
      build(subject_uid, runtime, request, opts)
    end
  end

  @doc false
  @spec resolve_runtime(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve_runtime(subject_uid, request, opts \\ []) when is_map(request) do
    with {:ok, _request, runtime} <- resolve_request_runtime(subject_uid, request, opts) do
      {:ok, runtime}
    end
  end

  @spec prepare_with_runtime(String.t(), map(), map(), keyword()) ::
          {:ok, prepared()} | {:error, term()}
  def prepare_with_runtime(subject_uid, runtime, request, opts \\ [])
      when is_map(runtime) and is_map(request) do
    request = MapUtils.normalize_request_keys(request)

    request_context =
      opts
      |> Keyword.get(:request_context, Map.get(runtime, "request_context", %{}))
      |> RequestContext.prepare(request)

    runtime = Map.put(runtime, "request_context", request_context)

    with {:ok, request} <- CompactionArtifacts.resolve_request_input_handles(subject_uid, request) do
      build(subject_uid, runtime, request, opts)
    end
  end

  defp resolve_request_runtime(subject_uid, request, opts) do
    request = MapUtils.normalize_request_keys(request)

    request_context =
      opts
      |> Keyword.get(:request_context, %{})
      |> RequestContext.prepare(request)

    with {:ok, request} <- CompactionArtifacts.resolve_request_input_handles(subject_uid, request),
         {:ok, runtime} <-
           Resolver.resolve_request_model(
             subject_uid,
             "llm",
             Map.put(request, "__ankole_request_context", request_context)
           ) do
      {:ok, request, runtime}
    end
  end

  defp build(subject_uid, runtime, request, opts) do
    stream? = Keyword.get(opts, :stream?, false)

    with {:ok, provider_request} <- provider_request(runtime, request),
         {:ok, provider_request, tool_plan} <- ToolSearch.plan(provider_request),
         {:ok, image_generation} <-
           ImageGeneration.prepare(subject_uid, request,
             stream?: stream?,
             main_runtime: runtime
           ),
         {:ok, spec} <-
           build_attempt_spec(
             runtime,
             provider_request,
             request,
             image_generation,
             tool_plan,
             stream?
           ) do
      {:ok, %{request: request, runtime: runtime, spec: spec}}
    end
  end

  defp build_attempt_spec(
         runtime,
         provider_request,
         public_request,
         image_generation,
         tool_plan,
         stream?
       ) do
    with {:ok, main_spec} <-
           Providers.build_response_request(runtime, provider_request,
             stream?: stream? and is_nil(image_generation)
           ) do
      spec =
        main_spec
        |> composite_spec(public_request, image_generation)
        |> put_tool_loop(tool_plan, provider_request)

      rebuild = fn next_runtime, request_override ->
        build_attempt_spec(
          next_runtime,
          request_override || provider_request,
          public_request,
          image_generation,
          tool_plan,
          stream?
        )
      end

      {:ok, CredentialAttempts.reattach(spec, rebuild, provider_request)}
    end
  end

  defp provider_request(%{"provider_kind" => "chatgpt_subscription"}, request),
    do: {:ok, Map.delete(request, "service_tier")}

  defp provider_request(runtime, request) do
    request = Map.delete(request, "service_tier")
    ChatGPTProtocol.normalize_non_subscription(request, Map.get(runtime, "request_context", %{}))
  end

  # The loop context rides inside the spec so every existing prepare caller
  # forwards it unchanged; `ResponseStream.open` pops it before the spec
  # reaches the Kernel.
  defp put_tool_loop(spec, nil, _provider_request), do: spec

  defp put_tool_loop(spec, plan, provider_request) do
    Map.put(spec, :tool_loop, %{
      plan: plan,
      provider_request: provider_request,
      program_run: fn code, bindings, memo ->
        Ankole.Kernel.ProgramRunner.run(code, bindings, memo)
      end
    })
  end

  defp composite_spec(main_spec, _request, nil), do: main_spec

  defp composite_spec(main_spec, request, image_generation) do
    {credential_attempt, image_generation} =
      Map.pop(image_generation, :credential_attempt)

    main_spec
    |> ensure_hosted_total_timeout()
    |> Map.put(:hosted_tools, %{
      image_generation: image_generation,
      public_request: request
    })
    |> maybe_put_hosted_credential_attempt(credential_attempt, image_generation)
    |> Map.update(:limits, hosted_limits(), &Map.merge(hosted_limits(), &1))
  end

  defp maybe_put_hosted_credential_attempt(spec, nil, _image_generation), do: spec

  defp maybe_put_hosted_credential_attempt(spec, credential_attempt, image_generation) do
    Map.put(spec, :hosted_credential_attempt, %{
      context: credential_attempt,
      spec: Map.fetch!(image_generation, "prepared_request")
    })
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
