defmodule Ankole.SignalsGateway.ActorRuntime.TurnErrorClassifier do
  @moduledoc false

  # Conversation and Codex retry owners share the meaning of a failure.
  # Each owner keeps its own budget and waiting strategy.

  @infrastructure_error_codes ~w(
    background_agent_job_runtime_exception
    agent_codex_runtime_busy
    background_agent_job_steer_delivery_failed
    codex_app_server_request_timeout
    socket_closed
    runtime_fabric_timeout
    runtime_rpc_timeout
    job_attempt_unknown
    worker_turn_acceptance_timeout
    worker_draining
    worker_busy
  )
  @credential_pool_exhausted_code "credential_pool_exhausted"

  @type class :: :infrastructure | :execution

  @doc """
  Returns the retry account for one execution failure.

  `:infrastructure` marks an interruption that is not the task failing, so it
  never consumes a bounded failure budget. Everything else is an `:execution`
  failure charged against the owner's failure budget.
  """
  @spec classify(map()) :: class()
  def classify(reason) when is_map(reason) do
    if infrastructure_error?(reason, details(reason)), do: :infrastructure, else: :execution
  end

  @doc "Reads the retryable conclusion the Worker recorded for one turn failure."
  @spec retryable?(map()) :: boolean()
  def retryable?(reason) when is_map(reason), do: details(reason)["retryable"] == true
  def retryable?(_reason), do: false

  @doc """
  Returns the credential pool recovery time when the failure carries a valid
  `retry_at` in the future.

  A missing, unparseable, or already elapsed time returns `nil`, which sends
  the failure back to the owner's ordinary capacity ladder.
  """
  @spec credential_pool_retry_at(map(), DateTime.t()) :: DateTime.t() | nil
  def credential_pool_retry_at(reason, %DateTime{} = now) when is_map(reason) do
    details = details(reason)

    if credential_pool_exhausted?(details) do
      details
      |> pool_retry_at()
      |> parse_future_datetime(now)
    end
  end

  def credential_pool_retry_at(_reason, %DateTime{}), do: nil

  defp details(%{"details_json" => details}) when is_map(details), do: details
  defp details(_reason), do: %{}

  defp infrastructure_error?(reason, details) do
    reason["code"] in @infrastructure_error_codes or
      details["error_code"] in @infrastructure_error_codes
  end

  defp credential_pool_exhausted?(details),
    do: details["error_code"] == @credential_pool_exhausted_code

  defp pool_retry_at(details), do: details["retry_at"]

  defp parse_future_datetime(retry_at, now) when is_binary(retry_at) do
    case DateTime.from_iso8601(retry_at) do
      {:ok, parsed, _offset} ->
        if DateTime.compare(parsed, now) == :gt, do: parsed

      _error ->
        nil
    end
  end

  defp parse_future_datetime(_retry_at, _now), do: nil
end
