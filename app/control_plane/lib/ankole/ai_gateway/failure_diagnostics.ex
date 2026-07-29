defmodule Ankole.AIGateway.FailureDiagnostics do
  @moduledoc """
  Normalizes safe AIGateway failure facts and selects one log severity.

  Callers own request-specific context. This module owns failure-shape parsing,
  retry classification, provider error extraction, and severity. It never
  returns provider messages or provider response bodies.
  """

  alias Ankole.AIGateway.OpenAIError
  alias Ankole.Logging

  @timeout_codes ~w(first_byte_timeout idle_timeout total_timeout)
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
  @warning_codes ~w(response_stream_cancelled stream_consumer_terminated)

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

    case {classification.failure_kind, stored_failure_kind(value(reason, "failure_kind"))} do
      {:internal, stored_kind} when not is_nil(stored_kind) ->
        Map.put(classification, :failure_kind, stored_kind)

      _other ->
        classification
    end
  end

  @spec public_message(map()) :: String.t()
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

  def public_message(%{error_code: "credential_pool_exhausted"}),
    do: "All credentials in this provider pool are temporarily unavailable."

  def public_message(%{error_code: code})
      when code in ["provider_stream_error", "response_stream_cleanup_error"],
      do: "AIGateway provider stream failed before a terminal response."

  def public_message(%{error_code: code})
      when code in ["stateful_commit_failed", "stateful_terminal_commit_failed"],
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

  @spec log(String.t() | atom(), String.t(), map(), term()) :: :ok
  def log(event, message, context, reason)
      when (is_binary(event) or is_atom(event)) and is_binary(message) and is_map(context) do
    fields =
      context
      |> Map.merge(classify(reason))
      |> Map.reject(fn {_key, value} -> is_nil(value) or value == [] end)

    case severity(fields) do
      :warning -> Logging.warning(event, message, fields)
      :error -> Logging.error(event, message, fields)
    end
  end

  defp failure_kind(%{error_code: code}) when code in @timeout_codes, do: :timeout
  defp failure_kind(%{error_code: code}) when code in @transport_codes, do: :transport
  defp failure_kind(%{error_code: "invalid_upstream_response"}), do: :invalid_response
  defp failure_kind(%{error_code: code}) when code in @warning_codes, do: :consumer_cancelled
  defp failure_kind(%{provider_event?: true}), do: :provider_response
  defp failure_kind(%{error_code: "upstream_response_failed"}), do: :provider_response

  defp failure_kind(%{error_code: code}) when code in @retryable_provider_codes,
    do: :provider_response

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

  defp reason_fields({:credential_pool_exhausted, _details}) do
    %{
      error_code: "credential_pool_exhausted",
      provider_status: 429,
      retryable: true
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
      retryable: retryable(explicit_retryable, provider_status || http_status, error_code)
    }
    |> Map.merge(provider_error_fields(excerpt))
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
      provider_error_type: string(value(error, "type")) || string(value(body, "error_type"))
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
  defp string(value) when is_binary(value) and value != "", do: value
  defp string(value) when is_atom(value), do: Atom.to_string(value)
  defp string(_value), do: nil
end
