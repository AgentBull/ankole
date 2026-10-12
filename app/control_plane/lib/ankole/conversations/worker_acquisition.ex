defmodule Ankole.Conversations.WorkerAcquisition do
  @moduledoc "A run's Worker acquisition. Transitions return effects; the Driver performs I/O."

  @timeout_ms 60_000
  @type t ::
          :idle
          | {:idle, :requested}
          | {:opening, integer(), map() | nil}
          | {:waiting, atom(), integer()}
          | {:ready, map()}
          | {:unavailable, term()}

  def next(state, event, now \\ System.monotonic_time(:millisecond))
  def next({:unavailable, _} = state, _event, _now), do: {state, []}
  def next(:idle, :request, _now), do: {{:idle, :requested}, [:request]}

  def next(state, :acquire, now) when state in [:idle, {:idle, :requested}],
    do: {{:opening, now, nil}, [{:phase, :starting}, :resolve]}

  def next({:waiting, _phase, since}, :acquire, _now), do: {{:opening, since, nil}, [:resolve]}
  def next({:ready, _} = state, :acquire, _now), do: {state, [:ready]}

  def next({:opening, since, _}, {:resolved, {:ok, row, message}}, _now),
    do: {{:opening, since, row}, [{:send_open, row, message}]}

  def next({:opening, since, _}, {:resolved, {:wait, phase}}, _now),
    do: {{:waiting, phase, since}, [:request, {:phase, phase}]}

  def next({:opening, _, _}, {:resolved, {:error, reason}}, _now),
    do: {{:unavailable, reason}, [{:unavailable, reason}]}

  def next({:opening, since, _}, {:sent, {:wait, phase}}, _now),
    do: {{:waiting, phase, since}, [:request, {:phase, phase}]}

  def next({:opening, _, _}, {:sent, {:error, reason}}, _now),
    do: {{:unavailable, reason}, [{:unavailable, reason}]}

  def next({:opening, _, row}, :ready, _now) when is_map(row), do: {{:ready, row}, [:ready]}

  def next({:opening, since, _}, {:waiting, reason}, _now) do
    phase = if reason == :CAPACITY, do: :capacity, else: :replacing
    {{:waiting, phase, since}, [{:phase, phase}]}
  end

  def next(state, {:unavailable, reason}, _now) when state != :idle,
    do: {{:unavailable, reason}, [{:unavailable, reason}]}

  def next({:opening, since, _} = state, :expired, now) do
    if now - since >= @timeout_ms, do: unavailable(:starting), else: {state, []}
  end

  def next({:waiting, phase, since} = state, :expired, now) do
    if now - since >= @timeout_ms, do: unavailable(phase), else: {state, []}
  end

  def next({:ready, row} = state, :check, _now), do: {state, [{:check, row}]}
  def next({:opening, _, nil} = state, :check, _now), do: {state, [:resolve]}
  def next({:opening, _, row} = state, :check, _now), do: {state, [{:check, row}]}
  def next({:waiting, _, _} = state, :check, now), do: next(state, :acquire, now)
  def next({:opening, _, _} = state, {:checked, {:ok, :same}}, _now), do: {state, []}

  def next({:opening, since, _}, {:checked, {:ok, :changed}}, _now),
    do: {{:opening, since, nil}, [:resolve]}

  def next({:ready, _} = state, {:checked, {:ok, :same}}, _now), do: {state, [:probe]}

  def next({:ready, _}, {:checked, {:ok, :changed}}, now),
    do: {{:opening, now, nil}, [:retry_calls, :resolve]}

  def next(state, :send_failed, now) do
    case state do
      {:ready, _} -> {{:opening, now, nil}, [:retry_calls, :resolve]}
      _ -> {state, []}
    end
  end

  def next(state, _event, _now), do: {state, []}

  def timers({:opening, since, _}, now),
    do: [{:acquire, max(@timeout_ms - (now - since), 0)}, {:check, 60_000}]

  def timers({:waiting, phase, since}, now),
    do: [
      {:acquire, max(@timeout_ms - (now - since), 0)},
      {:check, if(phase == :retrying, do: 5_000, else: 60_000)}
    ]

  def timers({:ready, _}, _now), do: [{:acquire, :cancel}, {:check, 60_000}]
  def timers(_state, _now), do: [{:acquire, :cancel}, {:check, :cancel}]

  def row({:ready, row}), do: row
  def row({:opening, _, row}), do: row
  def row(_), do: nil

  defp unavailable(phase),
    do: {{:unavailable, {:timeout, phase}}, [{:unavailable, {:timeout, phase}}]}

  def phase_key(:starting), do: "starting_computer"
  def phase_key(:resuming), do: "resuming_computer"
  def phase_key(:retrying), do: "computer_retrying"
  def phase_key(:replacing), do: "computer_replacing"
  def phase_key(:capacity), do: "computer_busy"
  def phase_key(:preparing), do: "computer_preparing"

  def error_text({:rejected, _}), do: error_text(:worker_provider_missing)

  def error_text(:worker_provider_missing),
    do:
      "The Agent computer cannot start: its provider configuration was rejected. An administrator must fix it in the Console."

  def error_text({:timeout, :preparing}),
    do: "The Agent computer is being prepared for a new version. Try again in a few minutes."

  def error_text({:timeout, :capacity}),
    do: "The Agent computer is busy with other tasks. Try again shortly."

  def error_text({:timeout, _}),
    do: "The Agent computer did not become ready in time. Try again shortly."

  def error_text(:agent_not_active), do: "This Agent is disabled, so its computer is unavailable."
  def error_text(_), do: "The Agent computer is unavailable. Try again shortly."
end
