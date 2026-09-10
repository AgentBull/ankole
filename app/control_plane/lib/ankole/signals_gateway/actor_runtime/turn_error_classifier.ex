defmodule Ankole.SignalsGateway.ActorRuntime.TurnErrorClassifier do
  @moduledoc false

  # One Worker turn failure feeds every control-plane retry owner: the ordinary
  # actor turn and the Background Agent Job. Each owner keeps its own waiting
  # strategy, but they must agree on what the failure means, so the split lives
  # here rather than in either owner.

  @infrastructure_error_codes ~w(
    background_agent_job_runtime_exception
    agent_codex_runtime_busy
    background_agent_job_steer_delivery_failed
    codex_app_server_request_timeout
  )
  @provider_capacity_error_kinds ~w(server rate_limit)
  @credential_pool_exhausted_code "credential_pool_exhausted"

  @type class :: :infrastructure | :provider_capacity | :execution

  @doc """
  Returns the retry account for one Worker turn failure.

  `:infrastructure` marks an interruption that is not the task failing, so it
  never consumes a bounded failure budget. `:provider_capacity` marks a
  retryable provider or credential-pool shortage, which each retry owner
  schedules on its own capacity ladder. Everything else is an `:execution`
  failure charged against the owner's failure budget.
  """
  @spec classify(map()) :: class()
  def classify(reason) when is_map(reason) do
    details = details(reason)

    cond do
      infrastructure_error?(reason, details) -> :infrastructure
      provider_capacity?(reason, details) -> :provider_capacity
      true -> :execution
    end
  end

  @doc """
  Reads the retryable conclusion the Worker recorded for one turn failure.

  `details_json.retryable` is authoritative because the Worker already folds
  the AIGateway hint into it. The nested AIGateway value is only a fallback for
  a reason with no top-level field. An explicit `false` always wins, so a
  failure the Worker called permanent is never scheduled as provider capacity.
  """
  @spec retryable?(map()) :: boolean()
  def retryable?(reason) when is_map(reason) do
    case details(reason) do
      %{"retryable" => true} ->
        true

      %{"retryable" => false} ->
        false

      details ->
        get_in(details, ["aigateway", "details_json", "retryable"]) == true
    end
  end

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

  defp provider_capacity?(reason, details) do
    retryable?(reason) and
      (details["llm_error_kind"] in @provider_capacity_error_kinds or
         credential_pool_exhausted?(details))
  end

  defp credential_pool_exhausted?(details) do
    details["error_code"] == @credential_pool_exhausted_code or
      get_in(details, ["aigateway", "code"]) == @credential_pool_exhausted_code
  end

  defp pool_retry_at(details) do
    details["retry_at"] ||
      get_in(details, ["aigateway", "details_json", "retry_at"])
  end

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
