defmodule Ankole.AIGateway.FailureResponse do
  @moduledoc "Projects normalized failure facts into the public HTTP and Responses contract."
  alias Ankole.AIGateway.OpenAIError
  alias Ankole.AIGateway.ProviderFailure

  import Ankole.AIGateway.FailureDiagnostics,
    only: [classify: 1, quota_exhausted?: 1, provider_validation_failure?: 1]

  # Codex reads only the error code on a terminal Responses failure and treats
  # every code outside this vocabulary as retryable, so a permanent rejection
  # must arrive as one of these codes.
  @responses_semantic_error_codes ~w(
    bio_policy context_length_exceeded cyber_policy insufficient_quota invalid_prompt
    rate_limit_exceeded server_is_overloaded slow_down usage_not_included
  )
  @spec public_message(map()) :: String.t()
  def public_message(%{provider_diagnostic_message: message}) when is_binary(message),
    do: message

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
      when is_struct(retry_at, DateTime),
      do: "AIGateway credential pool exhausted. retry_at=#{DateTime.to_iso8601(retry_at)}"

  def public_message(%{error_code: "credential_pool_exhausted"}),
    do: "AIGateway credential pool exhausted. Try again later."

  def public_message(%{error_code: "agent_token_quota_exceeded"}),
    do: "The Agent has used its token quota for the current period."

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
  `details_json`; `stage` in `opts` names the transport phase inside them. A
  rejection with a known recovery instant, an exhausted credential pool or an
  Agent at its token quota, also carries `resets_at`.

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
    retry_at = Map.get(classification, :retry_at)

    error =
      429
      |> error_object(
        "credential_pool_exhausted",
        public_message(classification),
        nil,
        pool_details(classification)
      )
      |> Map.put(
        "type",
        if(quota_exhausted?(reason), do: "usage_limit_reached", else: "rate_limit_error")
      )
      |> put_resets_at(retry_at)

    %{status: 429, headers: recovery_headers(retry_at), error: error}
  end

  # Codex does not retry a 429 whose type is usage_limit_reached.
  def project({:agent_token_quota_exceeded, window}, _opts) when is_map(window) do
    window_ends_at = Map.fetch!(window, :window_ends_at)

    error =
      429
      |> error_object(
        "agent_token_quota_exceeded",
        public_message(%{error_code: "agent_token_quota_exceeded"}),
        nil,
        %{
          "used_tokens" => Map.fetch!(window, :used_tokens),
          "limit_tokens" => Map.fetch!(window, :limit_tokens),
          "window_ends_at" => DateTime.to_iso8601(window_ends_at)
        }
      )
      |> Map.put("type", "usage_limit_reached")
      |> Map.put("retryable", false)
      |> put_resets_at(window_ends_at)

    headers = recovery_headers(window_ends_at)

    %{status: 429, headers: headers, error: error}
  end

  def project(reason, opts) do
    {status, code, message, param, details} = row(reason)

    %{
      status: status,
      headers: %{},
      error: error_object(status, code, message, param, resolve_details(details, opts))
    }
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
       "A tool result log requires at least one function_call_output item.", "input", nil}

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

  defp row(:response_stream_collect_timeout),
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

  defp row(%ProviderFailure{kind: :status_rejected, provider_status: status} = reason) do
    classification = classify(reason)

    {upstream_status(status), "upstream_response_failed", public_message(classification), nil,
     {:safe_fields, classification}}
  end

  defp row(%ProviderFailure{kind: :invalid_response} = reason) do
    classification = classify(reason)

    {502, "invalid_upstream_response", public_message(classification), nil,
     {:safe_fields, classification}}
  end

  defp row(%ProviderFailure{kind: :other} = reason) do
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
    |> Ankole.Attrs.normalize_external_attrs()
    |> put_stage(Keyword.get(opts, :stage))
  end

  defp resolve_details(details, _opts), do: details

  defp put_stage(details, stage) when is_binary(stage), do: Map.put(details, "stage", stage)
  defp put_stage(details, _stage), do: details

  defp pool_details(classification) do
    classification
    |> Map.take([:retry_at, :provider_error_code, :provider_error_type])
    |> Map.new(fn {key, value} ->
      {Atom.to_string(key),
       if(is_struct(value, DateTime), do: DateTime.to_iso8601(value), else: value)}
    end)
  end

  # The recovery instant of a rejection: an exhausted pool recovers at its retry
  # time, an Agent at its token quota recovers at the window end.
  defp recovery_headers(%DateTime{} = recovers_at) do
    remaining_ms = max(DateTime.diff(recovers_at, DateTime.utc_now(), :millisecond), 0)
    retry_after = div(remaining_ms + 999, 1_000)

    %{
      "retry-after" => Integer.to_string(retry_after),
      "x-codex-primary-reset-at" => Integer.to_string(DateTime.to_unix(recovers_at))
    }
  end

  defp recovery_headers(nil), do: %{}

  defp put_resets_at(error, %DateTime{} = retry_at),
    do: Map.put(error, "resets_at", DateTime.to_unix(retry_at))

  defp put_resets_at(error, nil), do: error
end
