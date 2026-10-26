defmodule Ankole.AIGateway.CompactionCandidate do
  @moduledoc "Selects a typed, pair-safe history cut that fits its retention budget."
  alias Ankole.AIGateway.CompactionArtifacts
  alias Ankole.AIGateway.CompactionRetention
  alias Ankole.AIGateway.ResponseItems
  alias Ankole.AIGateway.Schemas.Message
  import Ankole.AIGateway.CompactionPolicy, only: [tail_rows: 0, user_message_budget_tokens: 0]

  import Ankole.AIGateway.CompactionHistory,
    only: [
      previous_checkpoint_items: 2,
      rows_after_last_compaction: 1,
      split_last_compaction: 1,
      message_items: 1,
      text_compactable_message?: 1,
      messages_to_items: 1,
      provider_neutral_tail_items: 1,
      input_items: 1,
      items_token_estimate: 1
    ]

  defstruct anchor: nil,
            prefix: [],
            prefix_items: nil,
            retained_tail: [],
            retained_user_originals: [],
            retained_pending_clarify: [],
            retained_client_tool_search: [],
            recent_items: [],
            previous_chat_history: nil,
            previous_summary_discarded: false,
            opaque_prefix: [],
            tail_rows_requested: 0,
            brain_context_pack: []

  @type t :: %__MODULE__{}

  def truncate_history_to_stable_tail(history, current_input) do
    {checkpoint, tail} = split_last_compaction(history)
    tail_count = length(tail)
    minimum_count = min(tail_rows(), tail_count)
    boundary_plan = boundary_plan(tail, current_input)

    case Enum.find(Range.new(minimum_count, tail_count), fn retained_count ->
           safe_boundary?(boundary_plan, tail_count - retained_count)
         end) do
      nil -> {:error, :no_safe_truncation_boundary}
      retained_count -> {:ok, checkpoint ++ Enum.take(tail, -retained_count)}
    end
  end

  def for_history(
        subject_uid,
        history,
        current_input,
        retained_tail_budget_tokens,
        tail_rows_requested \\ nil
      ) do
    tail_rows_requested = tail_rows_requested || tail_rows()

    with {:ok, candidate} <-
           build_compaction_candidate(
             subject_uid,
             history,
             current_input,
             retained_tail_budget_tokens,
             tail_rows_requested
           ) do
      fit_compaction_candidate(
        candidate,
        subject_uid,
        history,
        current_input,
        retained_tail_budget_tokens,
        tail_rows_requested
      )
    end
  end

  defp build_compaction_candidate(
         subject_uid,
         history,
         current_input,
         retained_tail_budget_tokens,
         tail_rows_requested
       ) do
    with %Message{} = anchor <- List.last(history),
         rows_after_compaction = rows_after_last_compaction(history),
         preferred_prefix_count = max(length(rows_after_compaction) - tail_rows_requested, 0),
         compactable_count =
           rows_after_compaction
           |> Enum.take_while(&text_compactable_message?/1)
           |> length(),
         prefix_count when is_integer(prefix_count) and prefix_count > 0 <-
           compaction_prefix_count(
             rows_after_compaction,
             current_input,
             preferred_prefix_count,
             compactable_count,
             retained_tail_budget_tokens
           ),
         prefix = Enum.take(rows_after_compaction, prefix_count),
         %Message{} = _covers_until <- List.last(prefix),
         retained_tail = Enum.drop(rows_after_compaction, length(prefix)),
         prefix_items = messages_to_items(prefix),
         surviving_items =
           provider_neutral_tail_items(retained_tail) ++ input_items(current_input),
         {:ok, previous_checkpoint_items} <- previous_checkpoint_items(subject_uid, history),
         {:ok, retained_client_tool_search} <-
           CompactionRetention.collect_client_tool_search(
             previous_checkpoint_items ++ prefix_items,
             surviving_items
           ) do
      {retained_user_originals, _used_tokens} =
        CompactionRetention.collect_user_originals(
          prefix_items,
          user_message_budget_tokens()
        )

      {:ok,
       %__MODULE__{
         anchor: anchor,
         prefix: prefix,
         retained_tail: retained_tail,
         retained_user_originals: retained_user_originals,
         retained_pending_clarify: CompactionRetention.collect_pending_clarify(prefix_items),
         retained_client_tool_search: retained_client_tool_search,
         recent_items: surviving_items,
         previous_chat_history: previous_compaction_summary(subject_uid, history),
         tail_rows_requested: tail_rows_requested
       }}
    else
      {:error, _reason} = error -> error
      _value -> {:error, :no_compaction_candidate}
    end
  end

  defp fit_compaction_candidate(
         candidate,
         _subject_uid,
         _history,
         _current_input,
         nil,
         _tail_rows_requested
       ) do
    {:ok, candidate}
  end

  defp fit_compaction_candidate(
         candidate,
         subject_uid,
         history,
         current_input,
         retained_tail_budget_tokens,
         tail_rows_requested
       ) do
    if candidate_retention_within_budget?(candidate, retained_tail_budget_tokens) do
      {:ok, candidate}
    else
      with {:ok, maximum_retained_client_tool_search} <-
             maximum_retained_client_tool_search(
               subject_uid,
               history,
               current_input
             ),
           adjusted_tail_budget =
             max(
               retained_tail_budget_tokens -
                 retained_items_token_estimate(maximum_retained_client_tool_search),
               0
             ),
           {:ok, fitted_candidate} <-
             build_compaction_candidate(
               subject_uid,
               history,
               current_input,
               adjusted_tail_budget,
               tail_rows_requested
             ),
           :ok <-
             candidate_retention_within_budget(
               fitted_candidate,
               retained_tail_budget_tokens
             ) do
        {:ok, fitted_candidate}
      else
        {:error, :no_compaction_candidate} -> {:error, :compaction_output_over_budget}
        {:error, _reason} = error -> error
      end
    end
  end

  defp maximum_retained_client_tool_search(subject_uid, history, current_input) do
    rows_after_compaction = rows_after_last_compaction(history)

    compactable_count =
      rows_after_compaction
      |> Enum.take_while(&text_compactable_message?/1)
      |> length()

    boundary_plan = boundary_plan(rows_after_compaction, current_input)

    maximum_safe_prefix_count =
      compactable_count
      |> Range.new(0, -1)
      |> Enum.find(0, &safe_boundary?(boundary_plan, &1))

    prefix_items =
      rows_after_compaction
      |> Enum.take(maximum_safe_prefix_count)
      |> messages_to_items()

    surviving_items =
      rows_after_compaction
      |> Enum.drop(maximum_safe_prefix_count)
      |> provider_neutral_tail_items()
      |> Kernel.++(input_items(current_input))

    with {:ok, previous_checkpoint_items} <- previous_checkpoint_items(subject_uid, history) do
      CompactionRetention.collect_client_tool_search(
        previous_checkpoint_items ++ prefix_items,
        surviving_items
      )
    end
  end

  defp compaction_prefix_count(
         _rows_after_compaction,
         _current_input,
         _preferred_prefix_count,
         0,
         _retained_tail_budget_tokens
       ),
       do: nil

  defp compaction_prefix_count(
         rows_after_compaction,
         current_input,
         preferred_prefix_count,
         compactable_count,
         retained_tail_budget_tokens
       ) do
    start_count = min(max(preferred_prefix_count, 1), compactable_count)
    boundary_plan = boundary_plan(rows_after_compaction, current_input)

    forward_counts = Enum.to_list(start_count..compactable_count)

    backward_counts =
      if start_count > 1,
        do: 1..(start_count - 1) |> Enum.to_list() |> Enum.reverse(),
        else: []

    Enum.find(forward_counts ++ backward_counts, fn count ->
      safe_boundary?(boundary_plan, count) and
        retained_tail_within_budget?(boundary_plan, count, retained_tail_budget_tokens)
    end)
  end

  defp boundary_plan(rows, current_input) do
    row_items = Enum.map(rows, &message_items/1)
    current_items = input_items(current_input)
    row_stats = Enum.map(row_items, &json_item_stats/1)
    current_stats = json_item_stats(current_items)

    prefix_item_counts =
      [
        0
        | Enum.scan(row_stats, 0, fn %{count: count}, total -> total + count end)
      ]
      |> List.to_tuple()

    total_row_stats =
      Enum.reduce(row_stats, %{count: 0, bytes: 0}, fn stats, total ->
        %{count: total.count + stats.count, bytes: total.bytes + stats.bytes}
      end)

    prefix_stats =
      [
        %{count: 0, bytes: 0}
        | Enum.scan(row_stats, %{count: 0, bytes: 0}, fn stats, prefix ->
            %{count: prefix.count + stats.count, bytes: prefix.bytes + stats.bytes}
          end)
      ]

    tail_token_estimates =
      prefix_stats
      |> Enum.map(fn prefix ->
        tail_count = total_row_stats.count - prefix.count + current_stats.count
        tail_bytes = total_row_stats.bytes - prefix.bytes + current_stats.bytes
        json_list_token_estimate(tail_count, tail_bytes)
      end)
      |> List.to_tuple()

    all_items = List.flatten(row_items) ++ current_items

    %{
      safe_item_cuts: ResponseItems.safe_boundary_cuts(all_items),
      prefix_item_counts: prefix_item_counts,
      tail_token_estimates: tail_token_estimates
    }
  end

  defp json_item_stats(items) do
    Enum.reduce(items, %{count: 0, bytes: 0}, fn item, stats ->
      %{count: stats.count + 1, bytes: stats.bytes + byte_size(Ankole.JSON.encode!(item))}
    end)
  end

  defp json_list_token_estimate(item_count, item_bytes) do
    comma_bytes = max(item_count - 1, 0)
    encoded_bytes = 2 + item_bytes + comma_bytes
    max(div(encoded_bytes, 4), 1)
  end

  defp safe_boundary?(plan, row_count) do
    MapSet.member?(plan.safe_item_cuts, elem(plan.prefix_item_counts, row_count))
  end

  defp retained_tail_within_budget?(_plan, _row_count, nil), do: true

  defp retained_tail_within_budget?(
         plan,
         row_count,
         retained_tail_budget_tokens
       ) do
    elem(plan.tail_token_estimates, row_count) <= retained_tail_budget_tokens
  end

  defp candidate_retention_within_budget(candidate, retained_tail_budget_tokens) do
    if candidate_retention_within_budget?(candidate, retained_tail_budget_tokens) do
      :ok
    else
      {:error, :compaction_output_over_budget}
    end
  end

  defp candidate_retention_within_budget?(candidate, retained_tail_budget_tokens) do
    retained_items_token_estimate(candidate.retained_client_tool_search ++ candidate.recent_items) <=
      retained_tail_budget_tokens
  end

  defp retained_items_token_estimate([]), do: 0
  defp retained_items_token_estimate(items), do: items_token_estimate(items)

  defp previous_compaction_summary(subject_uid, history) do
    history
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{type: :checkpoint} = checkpoint ->
        case CompactionArtifacts.summary_for_checkpoint(subject_uid, checkpoint) do
          {:ok, summary} when is_binary(summary) -> summary
          _missing_or_invalid -> nil
        end

      _row ->
        nil
    end)
  end

  def for_input(subject_uid, original_input, resolved_input) do
    {original_start, previous_compaction_item} = items_after_last_compaction(original_input)
    original_region = Enum.drop(original_input, original_start)

    # The region after the last original compaction item holds no compaction
    # items, so handle resolution leaves it unchanged: the resolved region is
    # the resolved input's tail of the same length, and everything before it is
    # the resolved form of the already-compacted head.
    region_length = length(original_region)
    prefix_items = Enum.take(resolved_input, -region_length)
    resolved_head = Enum.drop(resolved_input, -region_length)

    if prefix_items == [] do
      {:error, :no_compaction_candidate}
    else
      {previous_chat_history, previous_summary_discarded} =
        previous_compaction_content(subject_uid, previous_compaction_item)

      # A compaction item that survives resolution is Provider-owned ciphertext
      # this summarizer cannot read. Keep the resolved head through its last
      # such item verbatim, so the caller's next turn replays the Provider
      # state instead of losing it. Readable head items after that point ride
      # `previous_chat_history` instead.
      {head_opaque_end, _head_compaction_item} = items_after_last_compaction(resolved_head)
      opaque_prefix = Enum.take(resolved_head, head_opaque_end)

      {retained_user_originals, _used_tokens} =
        CompactionRetention.collect_user_originals(original_region, user_message_budget_tokens())

      with {:ok, retained_client_tool_search} <-
             CompactionRetention.collect_client_tool_search(original_region) do
        {:ok,
         %__MODULE__{
           prefix_items: prefix_items,
           retained_tail: [],
           retained_user_originals: retained_user_originals,
           retained_pending_clarify: CompactionRetention.collect_pending_clarify(original_region),
           retained_client_tool_search: retained_client_tool_search,
           previous_chat_history: previous_chat_history,
           previous_summary_discarded: previous_summary_discarded and opaque_prefix == [],
           opaque_prefix: opaque_prefix,
           tail_rows_requested: 0
         }}
      end
    end
  end

  defp items_after_last_compaction(items) do
    items
    |> Enum.with_index()
    |> Enum.reduce({0, nil}, fn
      {%{"type" => "compaction"} = item, index}, _last -> {index + 1, item}
      _other, last -> last
    end)
  end

  defp previous_compaction_content(_subject_uid, nil), do: {nil, false}

  defp previous_compaction_content(subject_uid, %{} = item) do
    content =
      item
      |> then(&(Map.get(&1, "encrypted_content") || Map.get(&1, "summary")))
      |> resolve_previous_compaction_handle(subject_uid)

    if usable_previous_summary?(content) do
      {content, false}
    else
      {nil, true}
    end
  end

  defp resolve_previous_compaction_handle(content, subject_uid) when is_binary(content) do
    case CompactionArtifacts.get_for_subject(subject_uid, content) do
      {:ok, artifact} -> CompactionArtifacts.summary_text(artifact) || content
      {:error, :invalid_compaction_handle} -> content
    end
  end

  defp resolve_previous_compaction_handle(content, _subject_uid), do: content

  defp usable_previous_summary?(content) when is_binary(content) do
    String.valid?(content) and byte_size(content) <= 32_768 and content =~ ~r/\s/
  end

  defp usable_previous_summary?(_content), do: false
end
