defmodule Ankole.AIGateway.FailureDiagnostics do
  @moduledoc """
  Normalizes safe AIGateway failure facts and selects one log severity.

  Callers own request-specific context. This module owns failure-shape parsing,
  retry classification, provider error extraction, and severity. It keeps one
  bounded provider error message for the authenticated caller, but it never
  returns provider response bodies or writes provider messages to logs.
  """

  alias Ankole.AIGateway.OpenAIError
  alias Ankole.Logging

  @timeout_codes ~w(
    connect_timeout first_byte_timeout idle_timeout total_timeout universal_ai_stream_ready_timeout
  )
  @transport_codes ~w(
    provider_stream_aborted provider_stream_closed_without_terminal provider_stream_error
    response_body_read_failed response_body_too_large runtime_unavailable transport_failed
    upstream_read_failed upstream_stream_closed_before_terminal_event websocket_connect_failed
    websocket_read_failed websocket_send_failed
  )
  @legacy_provider_status_codes ~w(invalid_upstream_response upstream_response_failed)
  @retryable_provider_codes ~w(
    rate_limit rate_limited rate_limit_exceeded server_is_overloaded slow_down too_many_requests
  )
  # Codex reads only the error code on a terminal Responses failure and treats
  # every code outside this vocabulary as retryable, so a permanent rejection
  # must arrive as one of these codes.
  @responses_semantic_error_codes ~w(
    bio_policy context_length_exceeded cyber_policy insufficient_quota invalid_prompt
    rate_limit_exceeded server_is_overloaded slow_down usage_not_included
  )
  @generic_provider_validation_codes ~w(bad_request invalid_request invalid_request_error)
  @provider_validation_types ~w(invalid_request invalid_request_error)
  @warning_codes ~w(response_stream_cancelled stream_consumer_terminated)
  @identifier_limit 256
  @provider_message_limit 2_000

  @spec classify(term()) :: map()
  def classify(reason) do
    fields = reason_fields(reason)

    fields
    |> Map.delete(:provider_event?)
    |> Map.put(:failure_kind, failure_kind(fields))
    |> Map.reject(fn {_key, value} -> is_nil(value) or value == [] end)
  end

  @spec classify_stored(map()) :: map()
  def classify_stored(%{} = reason) do
    classification = classify(reason)

    classification =
      case {classification.failure_kind, stored_failure_kind(value(reason, "failure_kind"))} do
        {:internal, stored_kind} when not is_nil(stored_kind) ->
          Map.put(classification, :failure_kind, stored_kind)

        _other ->
          classification
      end

    restore_stored_provider_message(classification, reason)
  end

  @spec public_message(map()) :: String.t()
  def public_message(%{failure_kind: :provider_response, provider_message: message})
      when is_binary(message),
      do: message

  def public_message(%{error_code: "partial_tool_call_incomplete"}),
    do: "The provider response ended with an incomplete client tool call."

  def public_message(%{error_code: "partial_tool_call_completed"}),
    do: "The provider response completed with an incomplete client tool call."

  def public_message(%{error_code: "partial_function_call_incomplete"}),
    do: "The provider response ended with an incomplete function call."

  def public_message(%{error_code: "partial_function_call_completed"}),
    do: "The provider response completed with an incomplete function call."

  def public_message(%{error_code: "response_incomplete"}),
    do: "The provider response ended before completion."

  def public_message(%{error_code: "provider_stream_closed_without_terminal"}),
    do: "AIGateway provider stream closed before a terminal response."

  def public_message(%{error_code: "provider_stream_aborted"}),
    do: "AIGateway provider stream was aborted before a terminal response."

  # The Worker recognizes an exhausted pool on a mid-stream terminal only from
  # this text and reads the recovery time from `retry_at=`. Keep both stable.
  def public_message(%{error_code: "credential_pool_exhausted", retry_at: retry_at})
      when is_binary(retry_at),
      do: "AIGateway credential pool exhausted. retry_at=#{retry_at}"

  def public_message(%{error_code: "credential_pool_exhausted"}),
    do: "AIGateway credential pool exhausted. Try again later."

  def public_message(%{error_code: code})
      when code in ["provider_stream_error", "response_stream_cleanup_error"],
      do: "AIGateway provider stream failed before a terminal response."

  def public_message(%{error_code: "stateful_terminal_commit_failed"}),
    do: "AIGateway failed to store the completed provider response."

  def public_message(%{failure_kind: :timeout}), do: "The upstream provider timed out."

  def public_message(%{failure_kind: :transport}),
    do: "The upstream provider connection failed."

  def public_message(%{failure_kind: :invalid_response}),
    do: "The upstream provider returned an invalid response."

  def public_message(%{failure_kind: :consumer_cancelled}),
    do: "The response stream was cancelled."

  def public_message(%{failure_kind: :provider_response}),
    do: "The upstream provider request failed."

  def public_message(_classification), do: "The AIGateway request failed."

  @doc """
  Returns the public error code for one classification.

  A Provider code that the Responses vocabulary already defines stays
  unchanged, because it carries a decision the client cannot rebuild from the
  message. A permanent Provider request rejection becomes `invalid_prompt`,
  the one code in that vocabulary that means the request cannot succeed
  unchanged. Every other classification keeps its own code.
  """
  @spec public_error_code(map(), String.t()) :: String.t()
  def public_error_code(classification, fallback) when is_binary(fallback) do
    cond do
      Map.get(classification, :error_code) in @responses_semantic_error_codes ->
        Map.fetch!(classification, :error_code)

      Map.get(classification, :provider_error_code) in @responses_semantic_error_codes ->
        Map.fetch!(classification, :provider_error_code)

      provider_validation_failure?(classification) ->
        "invalid_prompt"

      true ->
        Map.get(classification, :error_code) ||
          Map.get(classification, :provider_error_code) ||
          fallback
    end
  end

  @doc """
  Projects one failure reason into the public error that every transport frames.

  `status` is the HTTP status of the failure, `headers` holds transport headers
  such as `retry-after`, and `error` is the public error object with string
  keys `type`, `code`, `message`, and `param`. Safe failure details go into
  `details_json`; `stage` in `opts` names the transport phase inside them. An
  exhausted credential pool also carries `resets_at`.

  The status rule is the AIGateway design rule: an upstream 4xx passes through,
  a native upstream timeout is 504, and every other upstream, transport, or
  internal failure is 502. A request that AIGateway itself rejects keeps its
  own 4xx status. Codex reads `code` on a terminal failure, so codes stay
  stable across transports.
  """
  @spec project(term(), keyword()) :: %{
          status: pos_integer(),
          headers: %{String.t() => String.t()},
          error: map()
        }
  def project(reason, opts \\ [])

  def project(%OpenAIError{} = error, _opts),
    do: %{status: error.status, headers: %{}, error: OpenAIError.envelope(error)["error"]}

  def project({:credential_pool_exhausted, _details} = reason, _opts) do
    classification = classify(reason)
    retry_at = retry_at_datetime(Map.get(classification, :retry_at))

    error =
      429
      |> error_object(
        "credential_pool_exhausted",
        public_message(classification),
        nil,
        pool_details(classification)
      )
      |> Map.put("type", "usage_limit_reached")
      |> put_resets_at(retry_at)

    %{status: 429, headers: pool_retry_headers(retry_at), error: error}
  end

  def project(reason, opts) do
    {status, code, message, param, details} = row(reason)

    %{
      status: status,
      headers: %{},
      error: error_object(status, code, message, param, resolve_details(details, opts))
    }
  end

  @doc """
  Returns whether one classification is a permanent Provider request rejection.

  A rejection is authoritative over a later transport symptom: the Provider
  already refused the request, so no retry of the same request can succeed.
  """
  @spec provider_validation_failure?(map()) :: boolean()
  def provider_validation_failure?(%{retryable: true}), do: false

  def provider_validation_failure?(%{provider_error_type: type})
      when type in @provider_validation_types,
      do: true

  def provider_validation_failure?(%{provider_error_code: code})
      when code in @generic_provider_validation_codes,
      do: true

  def provider_validation_failure?(%{error_code: code})
      when code in @generic_provider_validation_codes,
      do: true

  def provider_validation_failure?(%{provider_status: status}) when status in [400, 422],
    do: true

  def provider_validation_failure?(_classification), do: false

  @spec log(String.t() | atom(), String.t(), map(), term()) :: :ok
  def log(event, message, context, reason)
      when (is_binary(event) or is_atom(event)) and is_binary(message) and is_map(context) do
    fields =
      context
      |> Map.merge(classify(reason))
      |> Map.delete(:provider_message)
      |> Map.reject(fn {_key, value} -> is_nil(value) or value == [] end)

    case severity(fields) do
      :warning -> Logging.warning(event, message, fields)
      :error -> Logging.error(event, message, fields)
    end
  end

  # Public failure rows: {status, code, message, param, details}. `details` is
  # nil, a safe map from the reason, or {:safe_fields, classification}.

  defp row(:missing_model), do: {400, "missing_model", "model is required.", "model", nil}
  defp row(:missing_input), do: {400, "missing_input", "input is required.", "input", nil}
  defp row(:missing_query), do: {400, "missing_query", "query is required", nil, nil}
  defp row(:missing_urls), do: {400, "missing_urls", "urls is required", nil, nil}
  defp row(:invalid_query), do: {400, "invalid_query", "query is too long", nil, nil}

  defp row(:invalid_limit),
    do: {400, "invalid_limit", "limit must be an integer from 1 to 100", nil, nil}

  defp row(:invalid_urls),
    do: {400, "invalid_urls", "urls must contain 1 to 5 public HTTPS URLs", nil, nil}

  defp row(:invalid_embedding_input),
    do:
      {400, "invalid_embedding_input", "input must be text, token arrays, or input blocks", nil,
       nil}

  defp row(:invalid_documents),
    do: {400, "invalid_documents", "documents must be a non-empty array", nil, nil}

  defp row(:invalid_top_n),
    do: {400, "invalid_top_n", "top_n must be a positive integer", nil, nil}

  defp row(:invalid_request_body),
    do: {400, "invalid_request_body", "JSON object body required", nil, nil}

  defp row(:invalid_codex_model_binding),
    do: {400, "invalid_codex_model_binding", "Codex model binding is invalid", nil, nil}

  defp row(:invalid_compaction_item),
    do:
      {400, "invalid_compaction_item", "input must contain exactly one compaction item", nil, nil}

  defp row(:invalid_compaction_handle),
    do:
      {400, "invalid_compaction_handle", "compaction encrypted_content handle is invalid", nil,
       nil}

  defp row(:no_compaction_candidate),
    do:
      {400, "no_compaction_candidate",
       "input has no compactable items after the last compaction item.", nil, nil}

  # The caller's request is well formed: the summarizer produced nothing usable
  # after its retry. That is an upstream fault, so it must not read as a client
  # error that the caller could fix by changing the request.
  defp row(reason) when reason in [:empty_compaction_summary, :invalid_summary_shape],
    do:
      {502, Atom.to_string(reason), "upstream provider returned no usable compaction summary.",
       nil, nil}

  defp row(:invalid_input),
    do:
      {400, "invalid_input", "input must be a string or an array of Response input items.",
       "input", nil}

  defp row(:invalid_tool_results),
    do:
      {400, "invalid_tool_results",
       "response.tool_results.record requires at least one function_call_output item.", "input",
       nil}

  defp row(:invalid_max_tool_calls),
    do:
      {400, "invalid_max_tool_calls", "max_tool_calls must be a non-negative integer.",
       "max_tool_calls", nil}

  defp row(:invalid_anchor),
    do:
      {400, "invalid_previous_response_id",
       "previous_response_id does not reference a valid complete message in this conversation.",
       nil, nil}

  defp row(:previous_response_not_found),
    do:
      {400, "previous_response_not_found",
       "previous_response_id was not found on this WebSocket connection.", "previous_response_id",
       nil}

  defp row(:invalid_conversation),
    do:
      {400, "invalid_stateful_conversation",
       "conversation does not reference an active conversation owned by this subject.", nil, nil}

  defp row(:missing_stateful_anchor),
    do:
      {400, "stateful_anchor_required",
       "previous_response_id is required for this stateful Responses operation.",
       "previous_response_id", nil}

  defp row(:stateful_anchor_conflict),
    do:
      {400, "stateful_anchor_conflict",
       "previous_response_id and conversation are mutually exclusive.", nil, nil}

  defp row(:stateful_store_required),
    do:
      {400, "stateful_store_required",
       "previous_response_id and conversation require explicit store=true on WebSocket response.create.",
       nil, nil}

  defp row({:stateful_http_field_forbidden, field}),
    do:
      {400, "stateful_responses_require_websocket",
       "#{field} is only supported on WebSocket response.create with store=true", nil, nil}

  defp row(:invalid_oidc_access),
    do: {401, "invalid_token", "OIDC access token is invalid or expired.", nil, nil}

  defp row({:oidc_access_denied, reason}),
    do:
      {403, "access_denied", "OIDC Client policy does not allow this response.create.",
       if(reason == :model_not_allowed, do: "model"), nil}

  defp row(:not_found), do: {404, "not_found", "resource not found", nil, nil}
  defp row(:agent_not_found), do: {404, "agent_not_found", "agent not found", nil, nil}

  defp row(:response_run_in_progress),
    do:
      {409, "response_in_progress", "This conversation already has an active stateful run.", nil,
       nil}

  defp row({:tool_results_quarantined, %{} = details}),
    do:
      {409, "tool_results_quarantined",
       "Tool results did not match executable calls on the anchor and were excluded from canonical history.",
       "input", details}

  defp row(:provider_disabled), do: {422, "provider_disabled", "provider is disabled", nil, nil}

  defp row(:request_too_large),
    do: {422, "request_too_large", "request_too_large", nil, nil}

  defp row(:invalid_provider_options),
    do: {422, "invalid_provider_options", "invalid_provider_options", nil, nil}

  defp row({:unknown_model_selector, _capability, selector}),
    do: {422, "unknown_model_selector", "Unknown model selector: #{selector}.", "model", nil}

  defp row({:model_binding_not_configured, capability, name}),
    do:
      {422, "model_binding_not_configured", "#{capability}.#{name} is not configured.", "model",
       nil}

  # A model name that is neither provider/model nor a configured profile reaches
  # here, because any valid profile name is a candidate once an Agent can own
  # custom profiles. That is a caller or configuration fault, not a server fault.
  defp row(:model_profile_not_configured),
    do:
      {422, "model_profile_not_configured", "Model profile is not configured for this Agent.",
       "model", nil}

  defp row({:unsupported_capability, capability}),
    do: {422, "unsupported_capability", "provider does not support #{capability}", nil, nil}

  defp row({:context_overflow, details}),
    do:
      {422, "context_overflow", "AIGateway stateful input exceeds the configured context budget.",
       nil, details}

  defp row({:stateful_wire_unsupported, provider_kind, api_resolver}),
    do:
      {422, "stateful_wire_unsupported",
       "Stateful conversations replay history as Responses items. Provider " <>
         "'#{provider_kind}' uses the '#{api_resolver}' wire, which cannot replay " <>
         "that history. Select a provider on the openai_responses or " <>
         "openai_chat_completions wire, or use this provider for stateless requests.", "model",
       nil}

  defp row(:invalid_response_stream_collect_timeout),
    do:
      {400, "invalid_response_stream_collect_timeout",
       "response stream collect timeout must be a positive integer", nil, nil}

  defp row(reason)
       when reason in [:response_stream_collect_timeout, :universal_ai_stream_ready_timeout],
       do: {504, "upstream_timeout", public_message(%{failure_kind: :timeout}), nil, nil}

  defp row(:response_stream_missing_terminal_response),
    do:
      {502, "invalid_upstream_response", "upstream provider closed without a terminal response",
       nil, nil}

  defp row(:response_stream_closed), do: row({:response_stream_closed, nil})

  defp row({:response_stream_closed, _reason}),
    do:
      {502, "provider_stream_error", public_message(%{error_code: "provider_stream_error"}), nil,
       nil}

  defp row({:tool_results_record_unavailable, %{} = details}),
    do:
      {503, "tool_results_record_unavailable",
       "AIGateway could not persist tool results before the retry budget was exhausted.", nil,
       details}

  defp row({:upstream_response_failed, status, body, _headers}),
    do: row({:upstream_response_failed, status, body})

  defp row({:upstream_response_failed, status, _body} = reason) do
    classification = classify(reason)

    {upstream_status(status), "upstream_response_failed", public_message(classification), nil,
     {:safe_fields, classification}}
  end

  defp row({:invalid_upstream_response, _status, _body} = reason) do
    classification = classify(reason)

    {502, "invalid_upstream_response", public_message(classification), nil,
     {:safe_fields, classification}}
  end

  defp row({:universal_ai_request_failed, _details} = reason) do
    classification = classify(reason)
    message = public_message(classification)
    details = {:safe_fields, classification}

    case classification do
      %{failure_kind: :timeout} ->
        {504, "upstream_timeout", message, nil, details}

      %{failure_kind: :transport} ->
        {502, "upstream_transport_failed", message, nil, details}

      %{failure_kind: :provider_response} ->
        {upstream_status(Map.get(classification, :provider_status)), "upstream_response_failed",
         message, nil, details}

      _classification ->
        {502, "ai_gateway_request_failed", message, nil, details}
    end
  end

  defp row({:exception, _module, _message}), do: row(:ai_gateway_request_failed)
  defp row({:exit, _reason}), do: row(:ai_gateway_request_failed)

  defp row(:ai_gateway_request_failed),
    do: {502, "ai_gateway_request_failed", public_message(%{}), nil, nil}

  # Known request failures have explicit rows above. An unlisted reason is an
  # internal failure and must not tell the caller to change a valid request.
  defp row({reason, _details}) when is_atom(reason), do: row(reason)

  defp row(_reason), do: {502, "ai_gateway_request_failed", public_message(%{}), nil, nil}

  defp upstream_status(status) when is_integer(status) and status in 400..499, do: status
  defp upstream_status(_status), do: 502

  defp error_object(status, code, message, param, details) do
    %{
      "type" => if(status >= 500, do: "server_error", else: "invalid_request_error"),
      "code" => code,
      "message" => message,
      "param" => param
    }
    |> put_details_json(details)
  end

  defp put_details_json(error, details) when is_map(details),
    do: Map.put(error, "details_json", details)

  defp put_details_json(error, _details), do: error

  defp resolve_details({:safe_fields, classification}, opts) do
    classification
    |> Map.take([
      :error_code,
      :error_stage,
      :provider_status,
      :http_status,
      :provider_error_code,
      :provider_error_type,
      :retryable
    ])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> put_stage(Keyword.get(opts, :stage))
  end

  defp resolve_details(details, _opts), do: details

  defp put_stage(details, stage) when is_binary(stage), do: Map.put(details, "stage", stage)
  defp put_stage(details, _stage), do: details

  defp pool_details(%{retry_at: retry_at}) when is_binary(retry_at),
    do: %{"retry_at" => retry_at}

  defp pool_details(_classification), do: %{}

  defp pool_retry_headers(%DateTime{} = retry_at) do
    retry_after = max(DateTime.diff(retry_at, DateTime.utc_now(), :second), 0)

    %{
      "retry-after" => Integer.to_string(retry_after),
      "x-codex-primary-reset-at" => Integer.to_string(DateTime.to_unix(retry_at))
    }
  end

  defp pool_retry_headers(nil), do: %{}

  defp put_resets_at(error, %DateTime{} = retry_at),
    do: Map.put(error, "resets_at", DateTime.to_unix(retry_at))

  defp put_resets_at(error, nil), do: error

  defp retry_at_datetime(retry_at) when is_binary(retry_at) do
    case DateTime.from_iso8601(retry_at) do
      {:ok, parsed, _offset} -> parsed
      _error -> nil
    end
  end

  defp retry_at_datetime(_retry_at), do: nil

  defp retry_at_string(retry_at) when is_binary(retry_at) do
    if is_nil(retry_at_datetime(retry_at)), do: nil, else: retry_at
  end

  defp retry_at_string(_retry_at), do: nil

  defp failure_kind(%{error_code: code}) when code in @timeout_codes, do: :timeout
  defp failure_kind(%{error_code: code}) when code in @transport_codes, do: :transport
  defp failure_kind(%{error_code: "invalid_upstream_response"}), do: :invalid_response
  defp failure_kind(%{error_code: code}) when code in @warning_codes, do: :consumer_cancelled
  defp failure_kind(%{provider_event?: true}), do: :provider_response
  defp failure_kind(%{error_code: "upstream_response_failed"}), do: :provider_response

  defp failure_kind(%{error_code: code}) when code in @retryable_provider_codes,
    do: :provider_response

  defp failure_kind(%{error_code: "invalid_prompt"}), do: :provider_response

  defp failure_kind(%{provider_status: status}) when is_integer(status), do: :provider_response
  defp failure_kind(%{http_status: status}) when is_integer(status), do: :public_response
  defp failure_kind(_fields), do: :internal

  defp severity(%{provider_status: status}) when status in 400..499, do: :warning
  defp severity(%{provider_status: status}) when is_integer(status), do: :error
  defp severity(%{http_status: status}) when status in 400..499, do: :warning
  defp severity(%{error_code: code}) when code in @retryable_provider_codes, do: :warning
  defp severity(%{error_code: code}) when code in @warning_codes, do: :warning
  defp severity(_fields), do: :error

  defp reason_fields(%OpenAIError{} = error) do
    %{
      error_code: error.code,
      http_status: error.status,
      retryable: retryable(nil, error.status, error.code)
    }
  end

  defp reason_fields({:upstream_response_failed, status, body}) do
    %{
      error_code: "upstream_response_failed",
      provider_status: integer(status),
      retryable: retryable(nil, status, "upstream_response_failed")
    }
    |> Map.merge(provider_error_fields(body))
  end

  defp reason_fields({:upstream_response_failed, status, body, _headers}),
    do: reason_fields({:upstream_response_failed, status, body})

  defp reason_fields({:invalid_upstream_response, status, body}) do
    %{
      error_code: "invalid_upstream_response",
      provider_status: integer(status),
      retryable: retryable(nil, status, "invalid_upstream_response")
    }
    |> Map.merge(provider_error_fields(body))
  end

  defp reason_fields({:provider_event_failed, %{} = reason}) do
    reason
    |> reason_fields()
    |> move_http_status_to_provider_status()
    |> Map.merge(provider_error_fields(reason))
    |> Map.put(:provider_event?, true)
  end

  defp reason_fields({:credential_pool_exhausted, details}) do
    %{
      error_code: "credential_pool_exhausted",
      provider_status: 429,
      retryable: true,
      retry_at: if(is_map(details), do: retry_at_string(value(details, "retry_at")))
    }
  end

  defp reason_fields({tag, details}) when is_atom(tag) do
    details
    |> reason_fields()
    |> put_error_code_if_missing(Atom.to_string(tag))
  end

  defp reason_fields(%{} = reason) do
    error = reason |> value("error") |> map_or(reason)
    details = error |> value("details_json") |> map_or(value(reason, "details_json"))

    error_code =
      first_string([
        value(error, "code"),
        value(reason, "code")
      ])

    legacy_status =
      first_integer([
        value(error, "status"),
        value(reason, "status")
      ])

    provider_status =
      first_integer([
        value(reason, "provider_status"),
        value(error, "provider_status"),
        value(details, "provider_status"),
        value(details, "providerStatus")
      ]) ||
        if error_code in @legacy_provider_status_codes, do: legacy_status

    http_status =
      first_integer([
        value(reason, "http_status"),
        value(error, "http_status"),
        value(details, "http_status")
      ]) ||
        if is_nil(provider_status) do
          legacy_status
        end

    explicit_retryable =
      first_boolean([
        value(reason, "retryable"),
        value(error, "retryable"),
        value(details, "retryable")
      ])

    excerpt =
      value(details, "provider_body_excerpt") ||
        value(error, "provider_body_excerpt") ||
        value(reason, "provider_body_excerpt")

    explicit_provider_fields =
      %{
        provider_error_code:
          first_string([
            value(reason, "provider_error_code"),
            value(error, "provider_error_code"),
            value(details, "provider_error_code")
          ]),
        provider_error_type:
          first_string([
            value(reason, "provider_error_type"),
            value(error, "provider_error_type"),
            value(details, "provider_error_type")
          ])
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    %{
      error_code: error_code,
      error_stage:
        first_string([
          value(details, "stage"),
          value(error, "stage"),
          value(reason, "stage")
        ]),
      provider_status: provider_status,
      http_status: http_status,
      retryable: retryable(explicit_retryable, provider_status || http_status, error_code),
      retry_at:
        retry_at_string(
          value(reason, "retry_at") || value(error, "retry_at") || value(details, "retry_at")
        )
    }
    |> Map.merge(provider_error_fields(excerpt))
    |> Map.merge(explicit_provider_fields)
  end

  defp reason_fields(reason) when is_atom(reason),
    do: %{error_code: Atom.to_string(reason)}

  defp reason_fields(_reason), do: %{}

  defp provider_error_fields(body) when is_binary(body) do
    case Ankole.JSON.decode(body) do
      {:ok, decoded} -> provider_error_fields(decoded)
      {:error, _reason} -> %{}
    end
  end

  defp provider_error_fields(%{} = body) do
    error = body |> value("error") |> map_or(body)

    %{
      provider_error_code: string(value(error, "code")),
      provider_error_type: string(value(error, "type")) || string(value(body, "error_type")),
      provider_message: bounded_provider_message(value(error, "message"))
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp provider_error_fields(_body), do: %{}

  defp retryable(value, _status, _code) when is_boolean(value), do: value
  defp retryable(_value, _status, code) when code in @timeout_codes, do: true
  defp retryable(_value, _status, code) when code in @transport_codes, do: true
  defp retryable(_value, _status, "invalid_upstream_response"), do: true
  defp retryable(_value, _status, code) when code in @retryable_provider_codes, do: true
  defp retryable(_value, status, _code), do: retryable_status?(status)

  defp retryable_status?(nil), do: nil
  defp retryable_status?(status) when status in [408, 409, 425, 429], do: true
  defp retryable_status?(status) when is_integer(status) and status >= 500, do: true
  defp retryable_status?(_status), do: false

  defp stored_failure_kind("timeout"), do: :timeout
  defp stored_failure_kind("transport"), do: :transport
  defp stored_failure_kind("invalid_response"), do: :invalid_response
  defp stored_failure_kind("consumer_cancelled"), do: :consumer_cancelled
  defp stored_failure_kind("provider_response"), do: :provider_response
  defp stored_failure_kind("public_response"), do: :public_response
  defp stored_failure_kind(:timeout), do: :timeout
  defp stored_failure_kind(:transport), do: :transport
  defp stored_failure_kind(:invalid_response), do: :invalid_response
  defp stored_failure_kind(:consumer_cancelled), do: :consumer_cancelled
  defp stored_failure_kind(:provider_response), do: :provider_response
  defp stored_failure_kind(:public_response), do: :public_response
  defp stored_failure_kind(_value), do: nil

  defp restore_stored_provider_message(
         %{failure_kind: :provider_response} = classification,
         reason
       ) do
    case bounded_provider_message(value(reason, "message")) do
      nil -> classification
      message -> Map.put_new(classification, :provider_message, message)
    end
  end

  defp restore_stored_provider_message(classification, _reason), do: classification

  defp put_error_code_if_missing(fields, code) do
    if is_nil(Map.get(fields, :error_code)) do
      Map.put(fields, :error_code, code)
    else
      fields
    end
  end

  defp move_http_status_to_provider_status(%{provider_status: status} = fields)
       when is_integer(status),
       do: fields

  defp move_http_status_to_provider_status(%{http_status: status} = fields) do
    fields
    |> Map.delete(:http_status)
    |> Map.put(:provider_status, status)
  end

  defp move_http_status_to_provider_status(fields), do: fields

  defp map_or(value, _fallback) when is_map(value), do: value
  defp map_or(_value, fallback) when is_map(fallback), do: fallback
  defp map_or(_value, _fallback), do: %{}

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.reduce_while(map, nil, fn
          {atom_key, value}, _acc when is_atom(atom_key) ->
            if Atom.to_string(atom_key) == key, do: {:halt, value}, else: {:cont, nil}

          _entry, _acc ->
            {:cont, nil}
        end)
    end
  end

  defp first_integer(values), do: Enum.find_value(values, &integer/1)
  defp first_string(values), do: Enum.find_value(values, &string/1)
  defp first_boolean(values), do: Enum.find(values, &is_boolean/1)

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: nil

  defp string(nil), do: nil

  defp string(value) when is_binary(value) and value != "",
    do: String.slice(value, 0, @identifier_limit)

  defp string(value) when is_atom(value), do: value |> Atom.to_string() |> string()
  defp string(_value), do: nil

  defp bounded_provider_message(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      message -> String.slice(message, 0, @provider_message_limit)
    end
  end

  defp bounded_provider_message(_value), do: nil
end
