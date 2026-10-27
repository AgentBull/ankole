defmodule Ankole.AIGateway.FailureDiagnostics do
  @moduledoc """
  Normalizes safe AIGateway failure facts and selects one log severity.

  Callers own request-specific context. This module owns failure-shape parsing,
  retry classification, provider error extraction, and severity. It keeps one
  bounded provider error message for the authenticated caller, but it never
  returns provider response bodies or writes provider messages to logs.
  """

  alias Ankole.AIGateway.OpenAIError
  alias Ankole.AIGateway.ProviderFailure
  alias Ankole.Logging

  @timeout_codes ~w(
    connect_timeout first_byte_timeout idle_timeout total_timeout upstream_timeout
    universal_ai_stream_ready_timeout
  )
  @transport_codes ~w(
    provider_stream_aborted provider_stream_closed_without_terminal provider_stream_error
    response_body_read_failed response_body_too_large runtime_unavailable transport_failed
    upstream_read_failed upstream_stream_closed_before_terminal_event websocket_connect_failed
    websocket_read_failed websocket_send_failed
  )
  @route_retry_codes ~w(connect_timeout first_byte_timeout idle_timeout total_timeout
    upstream_read_failed websocket_connect_failed websocket_read_failed)
  @provider_protocol_rejection_codes ~w(invalid_provider_event provider_terminal_rejected)
  @legacy_provider_status_codes ~w(invalid_upstream_response upstream_response_failed)
  # Providers report the same capacity failure under several codes and types.
  # A Codex gateway substitutes `server_error` for `server_is_overloaded` on a
  # mid-stream capacity shed, which carries no HTTP status. Every alias here
  # keeps its provider failure identity and stays retryable.
  @retryable_provider_codes ~w(
    overloaded_error rate_limit rate_limited rate_limit_exceeded server_error
    server_is_overloaded slow_down too_many_requests
  )
  @retryable_provider_types ~w(overloaded_error server_error service_unavailable_error)
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

  @doc "Returns whether an AIGateway failure is a retryable provider capacity shortage."
  @spec provider_capacity?(term()) :: boolean()
  def provider_capacity?(reason) do
    failure = classify(reason)
    status = failure[:provider_status] || failure[:http_status]

    failure[:retryable] == true and
      (failure[:error_code] == "credential_pool_exhausted" or
         failure[:error_code] in @retryable_provider_codes or
         failure[:provider_error_code] in @retryable_provider_codes or
         failure[:provider_error_type] in @retryable_provider_types or
         status == 429 or
         (failure[:failure_kind] == :provider_response and is_integer(status) and status >= 500))
  end

  @doc """
  Identifies an explicit quota rejection. HTTP 429 alone is not quota evidence.
  """
  @spec quota_exhausted?(term()) :: boolean()
  def quota_exhausted?(reason) do
    classification = classify(reason)
    quota_codes = ~w(insufficient_quota usage_limit_reached billing_hard_limit_reached)

    Map.get(classification, :provider_error_code) in quota_codes or
      Map.get(classification, :provider_error_type) in quota_codes
  end

  @doc "Returns the bounded provider code, type, and message from one error body."
  @spec provider_error(term()) :: map()
  def provider_error(body) do
    fields = provider_error_fields(body)

    %{
      "code" => fields[:provider_error_code],
      "type" => fields[:provider_error_type],
      "message" => fields[:provider_message]
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc "Returns whether one provider error explicitly rejects quota."
  @spec quota_error?(term()) :: boolean()
  def quota_error?(body) do
    error = provider_error(body)
    codes = ~w(insufficient_quota usage_limit_reached billing_hard_limit_reached)
    error["code"] in codes or error["type"] in codes
  end

  @doc "Returns whether the unchanged request permits one route retry."
  @spec route_retryable?(term()) :: boolean()
  def route_retryable?(:stream_aborted), do: true

  def route_retryable?(%ProviderFailure{} = failure) do
    code = classify(failure)[:provider_error_code] || failure.code

    failure.provider_status in [502, 503, 504] or code in @route_retry_codes or
      (failure.kind == :other and failure.stage in ["connect", "read", "open"])
  end

  def route_retryable?(%{} = reason) do
    code = classify(reason)[:provider_error_code] || value(reason, "code")

    value(reason, "provider_status") in [502, 503, 504] or code in @route_retry_codes or
      value(reason, "stage") in ["connect", "read", "open"]
  end

  def route_retryable?(_reason), do: false

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
  @doc "Formats normalized facts for JSON logs and trace attributes."
  def log_fields(reason) do
    reason
    |> classify()
    |> Map.new(fn
      {key, %DateTime{} = value} -> {key, DateTime.to_iso8601(value)}
      pair -> pair
    end)
  end

  def log(event, message, context, reason)
      when (is_binary(event) or is_atom(event)) and is_binary(message) and is_map(context) do
    fields =
      context
      |> Map.merge(log_fields(reason))
      |> Map.reject(fn {_key, value} -> is_nil(value) or value == [] end)

    case severity(fields) do
      :warning -> Logging.warning(event, message, fields)
      :error -> Logging.error(event, message, fields)
    end
  end

  defp failure_kind(%{error_code: code}) when code in @timeout_codes, do: :timeout
  defp failure_kind(%{error_code: code}) when code in @transport_codes, do: :transport
  defp failure_kind(%{error_code: "invalid_upstream_response"}), do: :invalid_response

  defp failure_kind(%{error_code: code}) when code in @provider_protocol_rejection_codes,
    do: :provider_response

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

  defp reason_fields(%ProviderFailure{kind: kind} = failure)
       when kind in [:status_rejected, :invalid_response] do
    code =
      if kind == :status_rejected,
        do: "upstream_response_failed",
        else: "invalid_upstream_response"

    %{
      error_code: code,
      provider_status: integer(failure.provider_status),
      retryable: retryable(nil, failure.provider_status, code)
    }
    |> Map.merge(provider_error_fields(failure.provider_body))
  end

  defp reason_fields(%ProviderFailure{kind: :other} = failure) do
    fields =
      %{
        error_code: string(failure.code),
        error_stage: string(failure.stage),
        provider_status: integer(failure.provider_status)
      }
      |> Map.merge(provider_error_fields(failure.provider_body))

    fields =
      if is_binary(failure.provider_error_type),
        do: Map.put(fields, :provider_error_type, string(failure.provider_error_type)),
        else: fields

    fields
    |> Map.put(
      :retryable,
      retryable(
        failure.retryable,
        failure.provider_status,
        failure.code,
        fields[:provider_error_type]
      )
    )
    |> put_error_code_if_missing("universal_ai_request_failed")
  end

  defp reason_fields({:provider_event_failed, %{} = reason}) do
    fields = reason |> reason_fields() |> move_http_status_to_provider_status()

    fields
    |> Map.merge(event_error_fields(reason, Map.get(fields, :error_stage)))
    |> Map.put(:provider_event?, true)
  end

  defp reason_fields({:credential_pool_exhausted, details}) do
    %{
      error_code: "credential_pool_exhausted",
      provider_status: 429,
      retryable: true,
      retry_at: if(is_map(details), do: Ankole.Attrs.parse_datetime(value(details, "retry_at")))
    }
    |> Map.merge(provider_error_fields(value(details, "upstream_error")))
  end

  defp reason_fields({:agent_token_quota_exceeded, _window}) do
    %{
      error_code: "agent_token_quota_exceeded",
      http_status: 429,
      retryable: false
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
        value(details, "error_code"),
        value(error, "error_code"),
        value(reason, "error_code"),
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
        provider_diagnostic_message:
          bounded_provider_message(value(details, "provider_diagnostic_message")),
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

    fields =
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
        retry_at:
          Ankole.Attrs.parse_datetime(
            value(reason, "retry_at") || value(error, "retry_at") || value(details, "retry_at")
          )
      }
      |> Map.merge(provider_error_fields(excerpt))
      |> Map.merge(explicit_provider_fields)

    Map.put(
      fields,
      :retryable,
      retryable(
        explicit_retryable,
        provider_status || http_status,
        error_code,
        Map.get(fields, :provider_error_type) || reported_provider_type(error, fields.error_stage)
      )
    )
  end

  defp reason_fields(reason) when is_atom(reason),
    do: %{error_code: Atom.to_string(reason)}

  defp reason_fields(_reason), do: %{}

  # An error object with a stage is an Ankole envelope, not a Provider error.
  # Its code names the Ankole failure, and the kernel gives every envelope the
  # OpenAI type `server_error`, so neither is a Provider fact: a Provider code
  # or type comes only from the Provider error type and the body excerpt of
  # the envelope. The message of an envelope is the Provider's message.
  defp reported_provider_type(_error, stage) when is_binary(stage), do: nil
  defp reported_provider_type(error, nil), do: string(value(error, "type"))

  defp event_error_fields(event, stage) when is_binary(stage),
    do: event |> provider_error_fields() |> Map.take([:provider_message])

  defp event_error_fields(event, nil), do: provider_error_fields(event)

  defp provider_error_fields(body) when is_binary(body) do
    case Ankole.JSON.decode(body) do
      {:ok, decoded} -> provider_error_fields(decoded)
      {:error, _reason} -> %{}
    end
  end

  # Google's OpenAI-compatible endpoint puts the error object in a one-item
  # array. A status rejection reaches this module with that array wrapped as
  # `%{"body" => array}`, because its decoded body must be a map.
  defp provider_error_fields(%{"body" => [%{} = body]}), do: provider_error_fields(body)
  defp provider_error_fields([%{} = body]), do: provider_error_fields(body)

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

  defp retryable(value, status, code), do: retryable(value, status, code, nil)

  defp retryable(value, _status, _code, _type) when is_boolean(value), do: value
  defp retryable(_value, _status, code, _type) when code in @timeout_codes, do: true
  defp retryable(_value, _status, code, _type) when code in @transport_codes, do: true
  defp retryable(_value, _status, "invalid_upstream_response", _type), do: true

  defp retryable(_value, _status, code, _type) when code in @provider_protocol_rejection_codes,
    do: false

  defp retryable(_value, _status, code, _type) when code in @retryable_provider_codes,
    do: true

  defp retryable(_value, _status, _code, type) when type in @retryable_provider_types,
    do: true

  defp retryable(_value, status, _code, _type), do: retryable_status?(status)

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

  defp value(map, key) when is_map(map) and is_binary(key),
    do: Ankole.Attrs.get_string_first(map, key)

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
