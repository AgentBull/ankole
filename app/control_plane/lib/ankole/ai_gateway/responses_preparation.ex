defmodule Ankole.AIGateway.ResponsesPreparation do
  @moduledoc """
  One preparation path for Responses JSON, SSE, and WebSocket transports.

  The ordinary single-upstream spec remains unchanged when no hosted tool is
  declared. Hosted tools add a private composite spec consumed inside Kernel.
  """

  alias Ankole.AIGateway.CompactionArtifacts
  alias Ankole.AIGateway.ChatGPTProtocol
  alias Ankole.AIGateway.CodexVision
  alias Ankole.AIGateway.CredentialAttempts
  alias Ankole.AIGateway.HostedTools.ImageGeneration
  alias Ankole.AIGateway.MapUtils
  alias Ankole.AIGateway.OpenAIError
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.RequestContext
  alias Ankole.AIGateway.Resolver
  alias Ankole.AIGateway.ToolContract
  alias Ankole.AIGateway.ToolSearch
  alias Ankole.AIGateway.ToolSearch.StreamLoop

  @hosted_max_bytes 128 * 1024 * 1024
  @hosted_total_timeout_ms 30 * 60 * 1000

  @type prepared :: %{
          required(:request) => map(),
          required(:runtime) => map(),
          required(:spec) => map(),
          required(:driver) => :single_request | :response_stream
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

    with {:ok, request} <- CompactionArtifacts.resolve_request_input_handles(subject_uid, request),
         {:ok, request} <- CodexVision.adapt(subject_uid, request) do
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
           ),
         {:ok, request} <- CodexVision.adapt(subject_uid, request) do
      {:ok, request, runtime}
    end
  end

  defp build(subject_uid, runtime, request, opts) do
    stream? = Keyword.get(opts, :stream?, false)

    with {:ok, provider_request} <- provider_request(runtime, request),
         {:ok, provider_request, tool_plan} <- plan_tools(runtime, provider_request),
         response_stream_driver? = response_stream_driver?(runtime, tool_plan),
         provider_request =
           StreamLoop.apply_tool_budget(
             tool_plan,
             provider_request,
             initial_tool_budget(request)
           ),
         {:ok, image_generation} <-
           prepare_image_generation(subject_uid, request, runtime, stream?),
         {:ok, spec} <-
           build_attempt_spec(
             runtime,
             provider_request,
             request,
             image_generation,
             tool_plan,
             stream? or response_stream_driver?
           ) do
      {:ok,
       %{
         request: request,
         runtime: runtime,
         spec: spec,
         driver: if(response_stream_driver?, do: :response_stream, else: :single_request)
       }}
    end
  end

  defp initial_tool_budget(%{"max_tool_calls" => 0}), do: 0
  defp initial_tool_budget(_request), do: nil

  defp prepare_image_generation(_subject_uid, %{"max_tool_calls" => 0}, _runtime, _stream?),
    do: {:ok, nil}

  defp prepare_image_generation(subject_uid, request, runtime, stream?) do
    ImageGeneration.prepare(subject_uid, request,
      stream?: stream?,
      main_runtime: runtime
    )
  end

  defp response_stream_driver?(%{"provider_kind" => "chatgpt_subscription"}, _plan), do: true
  defp response_stream_driver?(_runtime, plan), do: ToolSearch.response_stream_required?(plan)

  # Tool ownership follows the stable provider/client protocol. A tool list
  # change must not switch one conversation between native and local handling.
  defp plan_tools(runtime, provider_request) do
    with :ok <- validate_tool_identifiers(provider_request) do
      if native_openai_tools?(runtime) do
        {:ok, provider_request, nil}
      else
        case ToolSearch.plan(provider_request) do
          {:ok, _provider_request, _plan} = planned -> planned
          {:error, reason} -> {:error, invalid_tool_plan(reason)}
        end
      end
    end
  end

  defp validate_tool_identifiers(provider_request) do
    case ToolContract.validate_responses_identifiers(ToolSearch.list_tools(provider_request)) do
      :ok -> :ok
      {:error, reason} -> {:error, invalid_tool_plan(reason)}
    end
  end

  defp invalid_tool_plan(reason) do
    code =
      case reason do
        {tag, _details} when is_atom(tag) -> Atom.to_string(tag)
        tag when is_atom(tag) -> Atom.to_string(tag)
        _reason -> "invalid_tools"
      end

    OpenAIError.invalid(
      nil,
      code,
      "The Responses tool declaration or tool-call history is invalid."
    )
  end

  # Only the `openai` kind follows the Responses-wire owner. Azure and
  # compatible upstreams keep local tool handling on every endpoint kind, and
  # `chatgpt_subscription` follows the codex client, not the wire.
  defp native_openai_tools?(%{"provider_kind" => "openai"} = runtime),
    do: Providers.responses_endpoint?(runtime)

  defp native_openai_tools?(%{"provider_kind" => "chatgpt_subscription"} = runtime) do
    runtime
    |> Map.get("request_context", %{})
    |> ChatGPTProtocol.codex_client?()
  end

  defp native_openai_tools?(_runtime), do: false

  defp native_encrypted_tool_fields?(runtime) do
    Providers.responses_endpoint?(runtime) and
      (native_openai_tools?(runtime) or
         runtime
         |> Map.get("request_context", %{})
         |> ChatGPTProtocol.codex_client?())
  end

  defp build_attempt_spec(
         runtime,
         provider_request,
         public_request,
         image_generation,
         tool_plan,
         upstream_stream?
       ) do
    with {:ok, main_spec} <-
           build_main_spec(runtime, provider_request, image_generation, upstream_stream?) do
      spec =
        main_spec
        |> put_native_encrypted_tool_fields(native_encrypted_tool_fields?(runtime))
        |> composite_spec(public_request, image_generation)
        |> put_tool_loop(tool_plan, provider_request)

      rebuild = fn next_runtime, request_override ->
        build_attempt_spec(
          next_runtime,
          request_override || provider_request,
          public_request,
          image_generation,
          tool_plan,
          upstream_stream?
        )
      end

      {:ok, CredentialAttempts.reattach(spec, rebuild, provider_request)}
    end
  end

  defp build_main_spec(runtime, provider_request, nil, upstream_stream?) do
    Providers.build_response_request(runtime, provider_request, stream?: upstream_stream?)
  end

  defp build_main_spec(runtime, provider_request, _image_generation, false) do
    Providers.build_response_request(runtime, provider_request, stream?: false)
  end

  defp build_main_spec(runtime, provider_request, _image_generation, true) do
    case Providers.build_response_request(runtime, provider_request, stream?: true) do
      {:ok, %{upstream: %{kind: :websocket_text}} = spec} ->
        {:ok, spec}

      {:ok, _stream_spec} ->
        Providers.build_response_request(runtime, provider_request, stream?: false)

      {:error, _reason} = error ->
        error
    end
  end

  defp provider_request(%{"provider_kind" => "chatgpt_subscription"}, request),
    do: {:ok, Map.delete(request, "service_tier")}

  defp provider_request(runtime, request) do
    request = Map.delete(request, "service_tier")
    ChatGPTProtocol.normalize_non_subscription(request, Map.get(runtime, "request_context", %{}))
  end

  # OpenAI Responses and Codex-compatible Responses proxies own the `encrypted`
  # tool-parameter marker and the encrypted function arguments they return.
  defp put_native_encrypted_tool_fields(spec, true) do
    update_in(spec, [:response_context, :request], fn request ->
      Map.put(request || %{}, "__ankole_native_encrypted_tool_fields", true)
    end)
  end

  defp put_native_encrypted_tool_fields(spec, false), do: spec

  # The loop context rides inside the spec so every existing prepare caller
  # forwards it unchanged; `ResponseStream.open` pops it before the spec
  # reaches the Kernel.
  defp put_tool_loop(spec, nil, _provider_request), do: spec

  defp put_tool_loop(spec, plan, provider_request) do
    Map.put(spec, :tool_loop, %{
      plan: plan,
      provider_request: provider_request
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
