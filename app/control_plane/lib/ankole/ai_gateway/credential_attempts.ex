defmodule Ankole.AIGateway.CredentialAttempts do
  @moduledoc """
  Runs one provider operation across an inline credential pool.

  The native kernel performs one upstream attempt. This module owns retry,
  backoff, credential attribution, ChatGPT refresh, and same-provider
  reselection. A private attempt context is removed before each spec crosses
  the native boundary.
  """

  alias Ankole.AIGateway.ChatGPTAuth
  alias Ankole.AIGateway.CredentialPool
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.Resolver
  alias Ankole.AIGateway.UniversalAIRequest

  @private_key :credential_attempt
  @native_private_keys [:credential_attempt, :hosted_credential_attempt, :tool_loop]
  @default_base_delay_ms 250
  @maximum_delay_ms 4_000
  @transport_codes ~w(
    connect_timeout
    first_byte_timeout
    idle_timeout
    request_timeout
    total_timeout
    transport_error
    universal_ai_stream_ready_timeout
    upstream_connect_failed
    upstream_read_failed
    websocket_connect_failed
    websocket_read_failed
  )
  @retryable_provider_codes ~w(server_is_overloaded slow_down)

  @type context :: %{
          required(:runtime) => map(),
          required(:build) => (map(), map() | nil -> {:ok, map()} | {:error, term()}),
          optional(:request) => map() | nil,
          optional(:attempt_number) => non_neg_integer(),
          optional(:attempted_ids) => MapSet.t(),
          optional(:single_retry_used?) => boolean(),
          optional(:refresh_used?) => boolean()
        }

  @doc """
  Attaches a control-plane-only retry context to a prepared spec.
  """
  @spec attach(map(), map(), (map(), map() | nil -> {:ok, map()} | {:error, term()}), map() | nil) ::
          map()
  def attach(spec, runtime, build, request \\ nil)
      when is_map(spec) and is_map(runtime) and is_function(build, 2) do
    Map.put(spec, @private_key, %{
      runtime: runtime,
      build: build,
      request: request,
      attempt_number: 0,
      attempted_ids: MapSet.new(),
      single_retry_used?: false,
      refresh_used?: false
    })
  end

  @doc """
  Replaces only the builder and logical request of an attached context.
  """
  @spec reattach(map(), (map(), map() | nil -> {:ok, map()} | {:error, term()}), map() | nil) ::
          map()
  def reattach(spec, build, request)
      when is_map(spec) and is_function(build, 2) do
    case Map.get(spec, @private_key) do
      %{runtime: runtime} ->
        attach(Map.delete(spec, @private_key), runtime, build, request)

      _missing ->
        spec
    end
  end

  @doc """
  Removes the private context before native encoding.
  """
  @spec pop(map()) :: {context() | nil, map()}
  def pop(spec) when is_map(spec), do: Map.pop(spec, @private_key)

  @doc """
  Executes a non-streaming request with pool retry.
  """
  @spec request(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def request(spec, opts \\ []) when is_map(spec) do
    aggregate_includes_tool_usage? = Map.has_key?(spec, :hosted_tools)

    case pop(spec) do
      {nil, clean_spec} ->
        UniversalAIRequest.request(native_spec(clean_spec), native_opts(opts))

      {context, clean_spec} ->
        run(
          context,
          clean_spec,
          fn candidate ->
            UniversalAIRequest.request(candidate, native_opts(opts))
          end,
          opts
        )
        |> case do
          {:ok, response, context, _spec} ->
            record_success(context, response,
              aggregate_includes_tool_usage?: aggregate_includes_tool_usage?
            )

            {:ok, response}

          {:error, reason, _context} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Opens a streaming request with pool retry.

  The returned context remains attached to the live stream owner so a later
  pre-output transport failure or Tool Search round can use the same policy.
  """
  @spec open(map(), UniversalAIRequest.downstream_kind(), keyword()) ::
          {:ok, Ankole.Kernel.UniversalAIClient.stream(), map(), context(), map()}
          | {:error, term()}
  def open(spec, downstream, opts \\ []) when is_map(spec) do
    case pop(spec) do
      {nil, clean_spec} ->
        clean_spec = native_spec(clean_spec)

        case UniversalAIRequest.open_stream(clean_spec, downstream, native_opts(opts)) do
          {:ok, stream, meta} -> {:ok, stream, meta, nil, clean_spec}
          {:error, reason} -> {:error, reason}
        end

      {context, clean_spec} ->
        run(
          context,
          clean_spec,
          fn candidate ->
            UniversalAIRequest.open_stream(candidate, downstream, native_opts(opts))
          end,
          opts
        )
        |> case do
          {:ok, {stream, meta}, context, clean_spec} ->
            {:ok, stream, meta, context, clean_spec}

          {:error, reason, _context} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Reopens a live stream after a pre-output native error.
  """
  @spec reopen(context() | nil, map(), term(), UniversalAIRequest.downstream_kind(), keyword()) ::
          {:ok, Ankole.Kernel.UniversalAIClient.stream(), map(), context(), map()}
          | {:error, term()}
  def reopen(nil, _spec, reason, _downstream, _opts), do: {:error, reason}

  def reopen(context, spec, reason, downstream, opts)
      when is_map(context) and is_map(spec) do
    case recover(context, spec, reason, opts) do
      {:retry, context, candidate} ->
        run(
          context,
          candidate,
          fn next_spec ->
            UniversalAIRequest.open_stream(next_spec, downstream, native_opts(opts))
          end,
          opts
        )
        |> case do
          {:ok, {stream, meta}, context, clean_spec} ->
            {:ok, stream, meta, context, clean_spec}

          {:error, next_reason, _context} ->
            {:error, next_reason}
        end

      {:stop, final_reason, _context} ->
        {:error, final_reason}
    end
  end

  @doc """
  Applies the pool recovery policy without executing the replacement spec.

  Composite request owners use this to replace one nested provider request
  while the native boundary still performs only one transport attempt.
  """
  @spec retry_spec(context(), map(), term(), keyword()) ::
          {:ok, context(), map()} | {:error, term()}
  def retry_spec(context, spec, reason, opts \\ [])
      when is_map(context) and is_map(spec) do
    opts = Keyword.put(opts, :credential_retry_allow_hosted_failure, true)

    case recover(context, spec, reason, opts) do
      {:retry, next_context, candidate} -> {:ok, next_context, candidate}
      {:stop, final_reason, _context} -> {:error, final_reason}
    end
  end

  @doc false
  @spec recoverable_failure?(term()) :: boolean()
  def recoverable_failure?(reason) do
    failure = classify(reason)
    failure.status == 401 or failure.retryable?
  end

  @doc """
  Maps future rebuilds in an attempt context without resetting its counters.
  """
  @spec map_build(context() | nil, (map() -> map())) :: context() | nil
  def map_build(%{build: build} = context, mapper)
      when is_function(build, 2) and is_function(mapper, 1) do
    mapped_build = fn runtime, request ->
      case build.(runtime, request) do
        {:ok, spec} when is_map(spec) -> {:ok, mapper.(spec)}
        other -> other
      end
    end

    %{context | build: mapped_build}
  end

  def map_build(context, _mapper), do: context

  @doc """
  Maps future rebuilds in a context attached to a prepared spec.
  """
  @spec map_attached_build(map(), (map() -> map())) :: map()
  def map_attached_build(spec, mapper) when is_map(spec) and is_function(mapper, 1) do
    case Map.get(spec, @private_key) do
      %{} = context -> Map.put(spec, @private_key, map_build(context, mapper))
      _missing -> spec
    end
  end

  @doc """
  Starts a new logical provider round while preserving current pool health and
  affinity. Per-round retry counters reset.
  """
  @spec build_round(context(), map()) :: {:ok, map(), context()} | {:error, term()}
  def build_round(%{build: build, runtime: runtime} = context, request)
      when is_function(build, 2) and is_map(request) do
    with {:ok, spec} <- build.(runtime, request) do
      {_nested, clean_spec} = pop(spec)

      {:ok, clean_spec,
       %{
         context
         | request: request,
           attempt_number: 0,
           attempted_ids: MapSet.new(),
           single_retry_used?: false,
           refresh_used?: false
       }}
    end
  end

  @doc """
  Builds and opens a new logical provider round with the normal retry policy.
  """
  @spec open_round(context(), map(), UniversalAIRequest.downstream_kind(), keyword()) ::
          {:ok, Ankole.Kernel.UniversalAIClient.stream(), map(), context(), map()}
          | {:error, term()}
  def open_round(context, request, downstream, opts \\ [])
      when is_map(context) and is_map(request) do
    with {:ok, clean_spec, context} <- build_round(context, request) do
      run(
        context,
        clean_spec,
        fn candidate ->
          UniversalAIRequest.open_stream(candidate, downstream, native_opts(opts))
        end,
        opts
      )
      |> case do
        {:ok, {stream, meta}, context, clean_spec} ->
          {:ok, stream, meta, context, clean_spec}

        {:error, reason, _context} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Marks the current attributed credential healthy after a valid provider event.
  """
  @spec mark_ok(context() | nil, map() | list()) :: :ok
  def mark_ok(context, response_or_headers \\ [])

  def mark_ok(%{runtime: runtime}, response_or_headers),
    do: mark_runtime_ok(runtime, response_headers(response_or_headers))

  def mark_ok(_context, _response_or_headers), do: :ok

  @doc """
  Attributes one terminal usage snapshot to the credential that produced it.
  """
  @spec record_usage(context() | nil, map(), keyword()) :: :ok
  def record_usage(context, response_or_event, opts \\ [])

  def record_usage(%{runtime: runtime}, response_or_event, opts)
      when is_map(response_or_event) do
    response = response_body(response_or_event)
    usage = map_value(response, "usage")
    tool_usage = map_value(response, "tool_usage")
    image_usage = if is_map(tool_usage), do: map_value(tool_usage, "image_gen")

    usage =
      if is_map(usage) and is_map(image_usage) and
           Keyword.get(opts, :aggregate_includes_tool_usage?, false) do
        subtract_usage(usage, image_usage)
      else
        usage
      end

    tool_usage =
      if is_map(tool_usage) and
           Keyword.get(opts, :aggregate_includes_tool_usage?, false) do
        Map.drop(tool_usage, ["image_gen", :image_gen])
      else
        tool_usage
      end

    with provider_row_id when is_binary(provider_row_id) <- provider_row_id(runtime),
         credential_id when is_binary(credential_id) <- Map.get(runtime, "credential_id"),
         true <- is_map(usage) or is_map(tool_usage) do
      CredentialPool.record_usage(
        provider_row_id,
        credential_id,
        if(is_map(usage), do: usage, else: %{}),
        if(is_map(tool_usage), do: tool_usage, else: %{})
      )
    else
      _value -> :ok
    end
  end

  def record_usage(_context, _response_or_event, _opts), do: :ok

  @doc """
  Returns the current credential id for diagnostics and tests.
  """
  @spec credential_id(context() | nil) :: String.t() | nil
  def credential_id(%{runtime: runtime}), do: Map.get(runtime, "credential_id")
  def credential_id(_context), do: nil

  defp run(context, spec, operation, opts) do
    spec = native_spec(spec)

    case operation.(spec) do
      {:ok, stream, meta} ->
        {:ok, {stream, meta}, context, spec}

      {:ok, result} ->
        {:ok, result, context, spec}

      {:error, reason} ->
        case recover(context, spec, reason, opts) do
          {:retry, context, candidate} -> run(context, candidate, operation, opts)
          {:stop, final_reason, context} -> {:error, final_reason, context}
        end
    end
  end

  defp native_spec(spec), do: Map.drop(spec, @native_private_keys)

  defp recover(context, spec, reason, opts) do
    failure = classify(reason)

    cond do
      failure.hosted? and not Keyword.get(opts, :credential_retry_allow_hosted_failure, false) ->
        {:stop, reason, context}

      failure.cloudflare_challenge? ->
        {:stop, cloudflare_challenge_error(failure), context}

      failure.status == 401 ->
        recover_unauthorized(context, spec, reason, failure, opts)

      failure.retryable? ->
        recover_retryable(context, spec, reason, failure, opts)

      true ->
        {:stop, reason, context}
    end
  end

  defp recover_unauthorized(context, _spec, reason, failure, opts) do
    runtime = context.runtime

    if chatgpt_oauth?(runtime) and not context.refresh_used? do
      case ChatGPTAuth.force_refresh(
             Map.fetch!(runtime, "provider_id"),
             Map.fetch!(runtime, "credential_id"),
             [
               expected_access_token: get_in(runtime, ["connection_options", "access_token"])
             ] ++ auth_opts(opts)
           ) do
        {:ok, refreshed} ->
          with {:ok, runtime} <- runtime_with_refreshed_credential(runtime, refreshed),
               {:ok, candidate} <- rebuild(context, runtime, context.request) do
            delay(context, opts)

            {:retry, %{context | runtime: runtime, refresh_used?: true} |> increment_attempt(),
             candidate}
          else
            {:error, build_reason} -> {:stop, build_reason, context}
          end

        {:error, {:chatgpt_refresh_permanent, _code}} ->
          rotate(context, reason, failure, opts, mark: :dead)

        {:error, refresh_reason} ->
          rotate(
            context,
            reason,
            refresh_failure(refresh_reason, failure),
            opts,
            mark: :exhausted
          )
      end
    else
      mark =
        if runtime["provider_kind"] == "chatgpt_subscription",
          do: :dead,
          else: :exhausted

      rotate(context, reason, failure, opts, mark: mark)
    end
  end

  defp recover_retryable(context, spec, reason, failure, opts) do
    if attributed?(context.runtime) and single_entry?(context.runtime) and
         not context.single_retry_used? do
      delay(context, opts)

      {:retry,
       context
       |> Map.put(:single_retry_used?, true)
       |> increment_attempt(), spec}
    else
      rotate(context, reason, failure, opts, mark: :exhausted)
    end
  end

  defp attributed?(runtime),
    do: is_binary(Map.get(runtime, "credential_id"))

  defp rotate(context, original_reason, failure, opts, mark: mark) do
    runtime = context.runtime
    credential_id = Map.get(runtime, "credential_id")
    provider_row_id = provider_row_id(runtime)

    if is_binary(credential_id) and is_binary(provider_row_id) do
      case mark do
        :dead ->
          CredentialPool.mark_dead(provider_row_id, credential_id, failure.error)

        :exhausted ->
          CredentialPool.mark_exhausted(
            provider_row_id,
            credential_id,
            failure.status,
            failure.headers,
            failure.error
          )
      end

      attempted_ids = MapSet.put(context.attempted_ids, credential_id)

      case Resolver.reselect_credential(runtime, exclude: MapSet.to_list(attempted_ids)) do
        {:ok, next_runtime} ->
          with {:ok, candidate} <- rebuild(context, next_runtime, context.request) do
            delay(context, opts)

            {:retry,
             context
             |> Map.put(:runtime, next_runtime)
             |> Map.put(:attempted_ids, attempted_ids)
             |> Map.put(:refresh_used?, false)
             |> Map.put(:single_retry_used?, false)
             |> increment_attempt(), candidate}
          else
            {:error, reason} -> {:stop, reason, context}
          end

        {:error, {:credential_pool_exhausted, _details} = exhausted} ->
          final_reason = if failure.status == 429, do: exhausted, else: original_reason
          {:stop, final_reason, %{context | attempted_ids: attempted_ids}}

        {:error, reason} ->
          {:stop, reason || original_reason, %{context | attempted_ids: attempted_ids}}
      end
    else
      recover_unattributed(context, original_reason, opts)
    end
  end

  # A failure without a credential id marks no entry. Retry is bounded by one
  # pool lap so malformed attribution cannot become an unbounded loop.
  defp recover_unattributed(context, reason, opts) do
    limit = max(pool_size(context.runtime), 1)

    if context.attempt_number < limit do
      retry_unattributed(context, reason, opts)
    else
      {:stop, reason, context}
    end
  end

  defp retry_unattributed(context, original_reason, opts) do
    excluded = MapSet.to_list(context.attempted_ids)

    with {:ok, runtime} <-
           Resolver.reselect_credential(context.runtime,
             exclude: excluded,
             ignore_affinity: true
           ),
         {:ok, candidate} <- rebuild(context, runtime, context.request) do
      delay(context, opts)

      attempted_ids =
        case Map.get(runtime, "credential_id") do
          credential_id when is_binary(credential_id) ->
            MapSet.put(context.attempted_ids, credential_id)

          _missing ->
            context.attempted_ids
        end

      {:retry,
       context
       |> Map.put(:runtime, runtime)
       |> Map.put(:attempted_ids, attempted_ids)
       |> increment_attempt(), candidate}
    else
      {:error, {:credential_pool_exhausted, _details}} ->
        {:stop, original_reason, context}

      {:error, reason} ->
        {:stop, reason, context}
    end
  end

  defp rebuild(%{build: build}, runtime, request) when is_function(build, 2) do
    with {:ok, spec} <- build.(runtime, request) do
      {_nested, clean_spec} = pop(spec)
      {:ok, clean_spec}
    end
  rescue
    error -> {:error, {:credential_attempt_build_failed, error.__struct__}}
  catch
    :exit, reason -> {:error, {:credential_attempt_build_exit, reason}}
  end

  defp runtime_with_refreshed_credential(runtime, refreshed) do
    provider = Map.fetch!(refreshed, "provider")

    with {:ok, connection} <- ProviderConfigs.runtime_connection(provider, refreshed) do
      {:ok,
       runtime
       |> Map.put("provider", provider)
       |> Map.put("credential_id", refreshed["id"])
       |> Map.put("credential_entry", refreshed["entry"])
       |> Map.put("connection_options", connection)}
    end
  end

  defp classify(reason) do
    error = structured_error(reason)
    status = error_status(reason, error)
    headers = error_headers(reason, error)
    code = map_text(error, "code")
    stage = map_text(error, "stage")

    %{
      status: status,
      headers: headers,
      error: error,
      hosted?: stage in ["hosted_responses", "image_generation"],
      cloudflare_challenge?:
        status == 403 and
          header_value(headers, "cf-mitigated") == "challenge",
      retryable?:
        status == 429 or (is_integer(status) and status in 500..599) or
          code in @retryable_provider_codes or transport_failure?(reason, code, stage)
    }
  end

  defp structured_error({:universal_ai_request_failed, %{} = error}), do: error

  defp structured_error({:upstream_response_failed, _status, body}),
    do: provider_error(body)

  defp structured_error({:upstream_response_failed, _status, body, _headers}),
    do: provider_error(body)

  defp structured_error({:invalid_upstream_response, _status, body}),
    do: provider_error(body)

  defp structured_error(%{} = error), do: error
  defp structured_error(_reason), do: %{}

  defp provider_error(%{"error" => %{} = error}),
    do: Map.take(error, ~w(code type reason message))

  defp provider_error(%{} = error), do: Map.take(error, ~w(code type reason message))
  defp provider_error(_body), do: %{}

  defp error_status({:upstream_response_failed, status, _body}, _error)
       when is_integer(status),
       do: status

  defp error_status({:upstream_response_failed, status, _body, _headers}, _error)
       when is_integer(status),
       do: status

  defp error_status({:invalid_upstream_response, status, _body}, _error)
       when is_integer(status),
       do: status

  defp error_status(_reason, error) do
    case Map.get(error, "provider_status") || Map.get(error, :provider_status) do
      status when is_integer(status) -> status
      _value -> nil
    end
  end

  defp error_headers({:upstream_response_failed, _status, _body, headers}, _error),
    do: headers

  defp error_headers(_reason, error),
    do: Map.get(error, "provider_headers") || Map.get(error, :provider_headers) || %{}

  defp transport_failure?(reason, code, stage) do
    code in @transport_codes or stage in ["connect", "read", "open", "transport"] or
      reason in [
        :stream_aborted,
        :universal_ai_stream_ready_timeout,
        :timeout,
        {:error, :timeout}
      ]
  end

  defp chatgpt_oauth?(runtime) do
    runtime["provider_kind"] == "chatgpt_subscription" and
      runtime
      |> Map.get("connection_options", %{})
      |> Map.get("auth_type", "oauth")
      |> Kernel.==("oauth")
  end

  defp single_entry?(runtime) do
    case Map.get(runtime, "credential_available_count") do
      count when is_integer(count) ->
        count <= 1

      _missing ->
        runtime
        |> Map.get("provider")
        |> case do
          %{credential_pool: %{"entries" => entries}} when is_list(entries) ->
            Enum.count(entries, fn entry ->
              is_nil(Map.get(entry, "disabled_at")) and
                Map.get(entry, "reauth_required") != true
            end) <= 1

          _provider ->
            true
        end
    end
  end

  defp provider_row_id(runtime) do
    case Map.get(runtime, "provider") do
      %{id: id} when is_binary(id) -> id
      _provider -> nil
    end
  end

  defp pool_size(runtime) do
    case Map.get(runtime, "provider") do
      %{credential_pool: %{"entries" => entries}} when is_list(entries) ->
        Enum.count(entries, fn entry ->
          is_nil(Map.get(entry, "disabled_at")) and
            Map.get(entry, "reauth_required") != true
        end)

      _provider ->
        Map.get(runtime, "credential_available_count", 1)
    end
  end

  defp mark_runtime_ok(runtime, headers) do
    with provider_row_id when is_binary(provider_row_id) <- provider_row_id(runtime),
         credential_id when is_binary(credential_id) <- Map.get(runtime, "credential_id") do
      CredentialPool.observe_success(provider_row_id, credential_id, headers)
    else
      _value -> :ok
    end
  end

  defp record_success(context, response, opts) do
    mark_ok(context, response)
    record_usage(context, response, opts)
  end

  defp response_headers(%{headers: headers}) when is_map(headers) or is_list(headers), do: headers

  defp response_headers(%{"headers" => headers}) when is_map(headers) or is_list(headers),
    do: headers

  defp response_headers(headers) when is_map(headers) or is_list(headers), do: headers
  defp response_headers(_response), do: []

  defp response_body(%{"response" => %{} = response}), do: response
  defp response_body(%{body: %{} = body}), do: body
  defp response_body(%{"body" => %{} = body}), do: body
  defp response_body(%{} = response), do: response

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp subtract_usage(usage, tool_usage) do
    Map.new(usage, fn {key, value} ->
      tool_value = Map.get(tool_usage, key)

      value =
        cond do
          is_number(value) and is_number(tool_value) ->
            max(value - tool_value, 0)

          is_map(value) and is_map(tool_value) ->
            subtract_usage(value, tool_value)

          true ->
            value
        end

      {key, value}
    end)
  end

  defp increment_attempt(context),
    do: Map.update!(context, :attempt_number, &(&1 + 1))

  defp delay(context, opts) do
    exponent = min(context.attempt_number, 5)
    base = Keyword.get(opts, :credential_retry_base_ms, @default_base_delay_ms)
    maximum = Keyword.get(opts, :credential_retry_max_ms, @maximum_delay_ms)
    jitter = Keyword.get(opts, :credential_retry_jitter, &default_jitter/1)
    delay = min(base * Integer.pow(2, exponent), maximum) |> jitter.()
    sleep = Keyword.get(opts, :credential_retry_sleep, &Process.sleep/1)
    sleep.(max(delay, 0))
  end

  defp default_jitter(milliseconds) do
    factor = 0.9 + :rand.uniform() * 0.2
    round(milliseconds * factor)
  end

  defp auth_opts(opts) do
    opts
    |> Keyword.take([:now, :req_options, :receive_timeout])
  end

  defp refresh_failure(
         {:chatgpt_refresh_transient, status, headers, code},
         original
       ) do
    %{
      original
      | status: status,
        headers: headers,
        error: %{"code" => to_string(code), "reason" => "chatgpt_refresh_failed"},
        retryable?: true
    }
  end

  defp refresh_failure(_reason, original), do: original

  defp cloudflare_challenge_error(failure) do
    {:universal_ai_request_failed,
     %{
       "code" => "chatgpt_cloudflare_challenge",
       "stage" => "provider_response",
       "message" =>
         "ChatGPT rejected this network edge. Check the provider originator and User-Agent overrides or use an allowed egress.",
       "provider_status" => 403,
       "provider_headers" => failure.headers,
       "retryable" => false
     }}
  end

  defp header_value(headers, target) when is_map(headers) do
    Enum.find_value(headers, fn {name, value} ->
      if is_binary(name) and String.downcase(name) == target, do: normalize_header_value(value)
    end)
  end

  defp header_value(headers, target) when is_list(headers) do
    Enum.find_value(headers, fn
      {name, value} when is_binary(name) ->
        if String.downcase(name) == target, do: normalize_header_value(value)

      [name, value] when is_binary(name) ->
        if String.downcase(name) == target, do: normalize_header_value(value)

      _entry ->
        nil
    end)
  end

  defp header_value(_headers, _target), do: nil

  defp normalize_header_value(value) when is_binary(value), do: String.downcase(value)
  defp normalize_header_value([value | _rest]) when is_binary(value), do: String.downcase(value)
  defp normalize_header_value(_value), do: nil

  defp native_opts(opts) do
    Keyword.drop(opts, [
      :credential_retry_base_ms,
      :credential_retry_max_ms,
      :credential_retry_jitter,
      :credential_retry_sleep,
      :now,
      :req_options,
      :receive_timeout,
      :credential_retry_allow_hosted_failure
    ])
  end

  defp map_text(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end
end
