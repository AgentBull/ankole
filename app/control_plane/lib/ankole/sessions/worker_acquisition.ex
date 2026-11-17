defmodule Ankole.Sessions.WorkerAcquisition do
  @moduledoc "A run's Worker acquisition. Transitions return effects; the Driver performs I/O."

  @timeout_ms 150_000
  @type origin_phase :: :starting | :preparing
  @type t ::
          :idle
          | {:idle, :requested}
          | {:opening, origin_phase(), integer(), map() | nil}
          | {:waiting, atom(), integer()}
          | {:ready, map()}
          | {:unavailable, term()}

  def next(state, event, now \\ System.monotonic_time(:millisecond))
  def next({:unavailable, _} = state, _event, _now), do: {state, []}
  def next(:idle, :request, _now), do: {{:idle, :requested}, [:request]}

  def next(state, :acquire, now) when state in [:idle, {:idle, :requested}],
    do: {{:opening, :starting, now, nil}, [{:phase, :starting}, :resolve]}

  def next({:waiting, phase, since}, :acquire, _now) do
    origin = if phase == :preparing, do: :preparing, else: :starting
    {{:opening, origin, since, nil}, [:resolve]}
  end

  def next({:ready, _} = state, :acquire, _now), do: {state, [:ready]}

  def next({:opening, _, _, _}, :round_committed, _now), do: {{:idle, :requested}, []}
  def next({:waiting, _, _}, :round_committed, _now), do: {{:idle, :requested}, []}

  def next({:opening, origin, since, _}, {:resolved, {:ok, row, message}}, now) do
    effective_since = if origin == :preparing, do: now, else: since
    {{:opening, :starting, effective_since, row}, [{:send_open, row, message}]}
  end

  def next({:opening, origin, since, _}, {:resolved, {:wait, phase}}, now) do
    effective_since = if origin == :preparing and phase != :preparing, do: now, else: since
    {{:waiting, phase, effective_since}, [:request, {:phase, phase}]}
  end

  def next({:opening, _, _, _}, {:resolved, {:error, reason}}, _now),
    do: {{:unavailable, reason}, [{:unavailable, reason}]}

  def next({:opening, _, since, _}, {:sent, {:wait, phase}}, _now),
    do: {{:waiting, phase, since}, [:request, {:phase, phase}]}

  def next({:opening, _, _, _}, {:sent, {:error, reason}}, _now),
    do: {{:unavailable, reason}, [{:unavailable, reason}]}

  def next({:opening, _, _, row}, :ready, _now) when is_map(row), do: {{:ready, row}, [:ready]}

  def next({:opening, _, since, row}, {:waiting, reason}, _now) when is_map(row) do
    phase = if reason == :CAPACITY, do: :capacity, else: :replacing
    {{:waiting, phase, since}, [{:phase, phase}]}
  end

  def next({:opening, _, _, row}, {:unavailable, reason}, _now) when is_map(row),
    do: {{:unavailable, reason}, [{:unavailable, reason}]}

  def next({:opening, origin, since, _} = state, :expired, now) do
    if now - since >= @timeout_ms, do: unavailable(origin), else: {state, []}
  end

  def next({:waiting, phase, since} = state, :expired, now) do
    if now - since >= @timeout_ms, do: unavailable(phase), else: {state, []}
  end

  def next({:ready, row} = state, :check, _now), do: {state, [{:check, row}]}
  def next({:opening, _, _, nil} = state, :check, _now), do: {state, [:resolve]}
  def next({:opening, _, _, row} = state, :check, _now), do: {state, [{:check, row}]}
  def next({:waiting, _, _} = state, :check, now), do: next(state, :acquire, now)
  def next({:opening, _, _, _} = state, {:checked, {:ok, :same}}, _now), do: {state, []}

  def next({:opening, origin, since, _}, {:checked, {:ok, :changed}}, _now),
    do: {{:opening, origin, since, nil}, [:resolve]}

  def next({:ready, _} = state, {:checked, {:ok, :same}}, _now), do: {state, [:probe]}

  def next({:ready, _}, {:checked, {:ok, :changed}}, now),
    do: {{:opening, :starting, now, nil}, [:retry_calls, :resolve]}

  def next(state, :send_failed, now) do
    case state do
      {:ready, _} -> {{:opening, :starting, now, nil}, [:retry_calls, :resolve]}
      _ -> {state, []}
    end
  end

  def next(state, _event, _now), do: {state, []}

  def timers({:opening, _, since, _}, now),
    do: [{:acquire, max(@timeout_ms - (now - since), 0)}, {:check, 60_000}]

  def timers({:waiting, phase, since}, now),
    do: [
      {:acquire, max(@timeout_ms - (now - since), 0)},
      {:check, if(phase == :retrying, do: 5_000, else: 60_000)}
    ]

  def timers({:ready, _}, _now), do: [{:acquire, :cancel}, {:check, 60_000}]
  def timers(_state, _now), do: [{:acquire, :cancel}, {:check, :cancel}]

  def row({:ready, row}), do: row
  def row({:opening, _, _, row}), do: row
  def row(_), do: nil

  def acquiring?({:opening, _, _, _}), do: true
  def acquiring?({:waiting, _, _}), do: true
  def acquiring?(_state), do: false

  defp unavailable(phase),
    do: {{:unavailable, {:timeout, phase}}, [{:unavailable, {:timeout, phase}}]}

  def phase_key(:starting), do: "starting_computer"
  def phase_key(:resuming), do: "resuming_computer"
  def phase_key(:retrying), do: "computer_retrying"
  def phase_key(:replacing), do: "computer_replacing"
  def phase_key(:capacity), do: "computer_busy"
  def phase_key(:preparing), do: "computer_preparing"

  # An unavailable acquisition is final for its run: every later computer call
  # in the same turn fails at once, including after messages that arrive
  # during the turn and join it. The text therefore tells the model to stop
  # calling computer tools instead of inviting a retry that cannot succeed.
  @rest_of_turn " Computer tools stay unavailable for the rest of this turn, so do not call them again now: finish with the other tools and tell the user what is blocked."
  @next_turn " After this turn ends, a later message tries to start the computer again."
  @administrator " It stays unavailable until an administrator fixes it."

  def error_text({:rejected, _}), do: error_text(:worker_provider_missing)

  def error_text(:worker_provider_missing),
    do:
      "The Agent computer cannot start: its provider configuration was rejected, and an administrator must fix it in the Console." <>
        @rest_of_turn <> @administrator

  def error_text(:agent_not_active),
    do: "This Agent is disabled, so its computer is unavailable." <> @rest_of_turn

  def error_text(reason), do: cause(reason) <> @rest_of_turn <> @next_turn

  defp cause({:timeout, :preparing}),
    do: "The Agent computer is being prepared for a new version."

  defp cause({:timeout, :capacity}), do: "The Agent computer is busy with other tasks."
  defp cause({:timeout, _}), do: "The Agent computer did not become ready in time."
  defp cause(_), do: "The Agent computer is unavailable."

  @doc """
  Returns whether a turn should pre-warm Worker acquisition alongside Round 1
  model streaming based on prior Worker usage, file attachments, or explicit
  filesystem, command-execution, or binary/document export signals.
  """
  @spec prewarm?(map()) :: boolean()
  def prewarm?(run) when is_map(run) do
    has_worker_tools? =
      Enum.any?(Map.get(run, :tools) || [], &(Map.get(&1, :executor) == :worker))

    has_worker_tools? and
      (get_in(Map.get(run, :context) || %{}, [:worker_used_in_conversation?]) == true or
         prewarm_attachments?(run) or
         prewarm_text_signal?(run))
  end

  def prewarm?(_run), do: false

  defp prewarm_attachments?(run) do
    event_attachments =
      case Map.get(run, :event) do
        %{data: %{"entry" => %{"attachments" => [_ | _]}}} -> true
        _other -> false
      end

    input_attachments =
      Enum.any?(Map.get(run, :input) || [], fn
        %{"content" => parts} when is_list(parts) ->
          Enum.any?(parts, fn
            %{"type" => "input_file"} -> true
            %{"text" => text} when is_binary(text) -> String.contains?(text, "<attachment")
            _part -> false
          end)

        %{"content" => text} when is_binary(text) ->
          String.contains?(text, "<attachment")

        _item ->
          false
      end)

    event_attachments or input_attachments
  end

  defp prewarm_text_signal?(run) do
    text = user_signal_text(run)

    text != "" and
      (Regex.match?(
         ~r/(?:\/drive\/|\/workspace\/|\.(?:xlsx|xls|csv|tsv|pptx|docx|pdf|zip|tar|gz)\b)/iu,
         text
       ) or
         Regex.match?(
           ~r/(?:运行|执行).*(?:脚本|代码|命令|bash|python|shell)|(?:生成|导出|制作|写入|整理成).*(?:表格|excel|xlsx|csv|ppt|pptx|word|docx|pdf|文件|脚本|图表)/iu,
           text
         ))
  end

  defp user_signal_text(run) do
    entry_text =
      case Map.get(run, :event) do
        %{data: %{"entry" => %{"text" => text}}} when is_binary(text) -> text
        %{data: %{"text" => text}} when is_binary(text) -> text
        _other -> ""
      end

    if entry_text != "" do
      entry_text
    else
      (Map.get(run, :input) || [])
      |> Enum.filter(&(Map.get(&1, "role") == "user"))
      |> Enum.map_join("\n", fn
        %{"content" => text} when is_binary(text) ->
          text

        %{"content" => parts} when is_list(parts) ->
          Enum.map_join(parts, "\n", fn
            %{"type" => "input_text", "text" => text} when is_binary(text) -> text
            _part -> ""
          end)

        _item ->
          ""
      end)
    end
  end
end
