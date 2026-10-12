defmodule Ankole.SignalsGateway.ActorRuntime.TurnErrorClassifier do
  @moduledoc false

  # Conversation and Codex retry owners share the meaning of a failure.
  # The retry policy preserves the distinct Job and conversation waiting budgets.

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
    code = Ankole.AIGateway.FailureDiagnostics.classify(reason)[:error_code]
    if code in @infrastructure_error_codes, do: :infrastructure, else: :execution
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
  @spec credential_pool_retry_at(term(), DateTime.t()) :: DateTime.t() | nil
  def credential_pool_retry_at(reason, %DateTime{} = now) do
    failure = Ankole.AIGateway.FailureDiagnostics.classify(reason)

    if failure[:error_code] == @credential_pool_exhausted_code do
      case failure[:retry_at] do
        %DateTime{} = time -> if DateTime.compare(time, now) == :gt, do: time
        _ -> nil
      end
    end
  end

  # Job execution retries span an upstream outage; infrastructure interruptions
  # never consume that failure budget. Conversation retries retain their shorter
  # interactive policy. Both strategies have this single owner.
  @job_execution [60, 600, 1_800, 3_600, 7_200]
  @job_infrastructure [15, 30, 60, 120, 300]
  @conversation_capacity [30, 120, 300, 750]

  def delay_seconds(:job, attempt, :infrastructure), do: ladder(@job_infrastructure, attempt)
  def delay_seconds(:job, attempt, _class), do: ladder(@job_execution, attempt)

  def delay_seconds(:conversation, attempt, :provider_capacity),
    do: ladder(@conversation_capacity, attempt)

  def delay_seconds(:conversation, attempt, _class),
    do: min(5 * Integer.pow(2, min(max(attempt - 1, 0), 5)), 120)

  defp ladder(values, attempt), do: Enum.at(values, min(max(attempt - 1, 0), length(values) - 1))

  defp details(%{"details_json" => details}) when is_map(details), do: details
  defp details(_reason), do: %{}
end
