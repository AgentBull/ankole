defmodule Ankole.BackgroundAgentJobs.TrajectoryReader do
  @moduledoc """
  The one bounded reader of the stored TurnItem stream.

  Every trajectory that leaves the control plane comes from `page/4`. The
  scope names the caller contract, the caller passes its budget, and the
  reader owns the item walk, the group selection, and the truncation ladder.
  The item stream is the only readable trajectory form: a Turn recorded
  before it existed has no item rows and renders nothing, and an item whose
  projection is empty stays replay-only.

  The model page keeps AIGateway opaque values in their encoded form. The
  owner Agent message result, the Console, and thread replay reveal them.
  """

  import Ecto.Query

  alias Ankole.AIGateway.OpaqueContent
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Schemas.Turn
  alias Ankole.BackgroundAgentJobs.Schemas.TurnItem
  alias Ankole.BackgroundAgentJobs.TurnItemProjection
  alias Ankole.Repo
  alias Ankole.Text

  @cursor_version 2
  @item_window_factor 4
  @summary_item_window 32
  @page_reserve_bytes 512
  @model_string_bytes 4_000
  @truncation_suffix "...[truncated]"

  @typedoc """
  The read contract. Callers pass the Turn rows they already hold, in
  chronological order; the lineage walk selects its own Turns because no
  caller owns a workspace lineage.
  """
  @type scope ::
          {:current_attempt_lead, [Turn.t()]}
          | {:one_turn, Turn.t()}
          | {:attempt_summary, [Turn.t()]}
          | {:console_detail, [Turn.t()]}
          | :lineage_replay

  @typedoc "Semantic groups count `groups` and `bytes`; a summary counts `bytes`; replay counts `items`."
  @type budget ::
          %{groups: pos_integer(), bytes: pos_integer()}
          | %{bytes: pos_integer()}
          | %{items: pos_integer()}

  @type group :: %{
          turn_id: Ecto.UUID.t(),
          position: non_neg_integer(),
          messages: [map()],
          redacted: boolean(),
          content_truncated: boolean()
        }
  @type summary :: %{turn_id: Ecto.UUID.t(), position: non_neg_integer(), text: String.t()}
  @type item :: %{
          turn_id: Ecto.UUID.t(),
          runtime_thread_id: String.t(),
          runtime_turn_id: String.t(),
          position: non_neg_integer(),
          item_key: String.t(),
          item: map()
        }

  @typedoc """
  `units` are chronological. `turn_ids` are the Turns the page spans, so a
  caller with a supplied Turn list can show a Turn that has no readable unit.
  A lineage page lists the Turns represented by its items. `next_cursor`
  continues the walk beyond the last delivered unit.
  """
  @type page :: %{
          units: [group() | summary() | item()],
          turn_ids: [Ecto.UUID.t()],
          next_cursor: String.t() | nil
        }

  @spec page(Job.t(), scope(), String.t() | nil, budget()) ::
          {:ok, page()} | {:error, atom()}
  def page(%Job{} = job, :lineage_replay, cursor, %{items: limit})
      when is_integer(limit) and limit > 0 do
    with {:ok, cursor} <- decode_cursor(cursor),
         {:ok, boundary} <- lineage_cursor_boundary(job, cursor) do
      rows =
        job
        |> lineage_query()
        |> lineage_after(boundary)
        |> order_by([row, turn, _job],
          asc: turn.started_at,
          asc: turn.id,
          asc: row.position
        )
        |> limit(^(limit + 1))
        |> select([row, turn, _job], %{
          turn_id: row.turn_id,
          runtime_thread_id: turn.runtime_thread_id,
          runtime_turn_id: turn.runtime_turn_id,
          attempt: turn.attempt,
          started_at: turn.started_at,
          position: row.position,
          item_key: row.item_key,
          item: row.item
        })
        |> Repo.all()

      {delivered, rest} = Enum.split(rows, limit)

      {:ok,
       %{
         units: Enum.map(delivered, &lineage_unit/1),
         turn_ids: delivered |> Enum.map(& &1.turn_id) |> Enum.uniq(),
         next_cursor:
           if(rest == [], do: nil, else: delivered |> List.last() |> encode_lineage_cursor())
       }}
    end
  end

  def page(%Job{} = job, scope, cursor, budget) when is_map(budget) do
    walk = walk(job, scope)

    with {:ok, cursor} <- decode_cursor(cursor),
         :ok <- check_fence(walk, cursor),
         {:ok, state} <- start_walk(walk, cursor) do
      {:ok, collect(state, budget)}
    end
  end

  defp walk(%Job{} = job, {:current_attempt_lead, turns}) when is_list(turns),
    do: newest_first(turns, :group, reveal: false, fence: job.attempts)

  defp walk(%Job{}, {:one_turn, %Turn{} = turn}),
    do: newest_first([turn], :group, reveal: true, fence: nil)

  defp walk(%Job{}, {:attempt_summary, turns}) when is_list(turns),
    do: newest_first(turns, :summary, reveal: false, fence: nil)

  defp walk(%Job{}, {:console_detail, turns}) when is_list(turns),
    do: newest_first(turns, :group, reveal: true, fence: nil)

  defp newest_first(turns, unit, reveal: reveal, fence: fence) do
    %{turns: turns, unit: unit, reveal: reveal, fence: fence}
  end

  # Child-agent threads stay out of replay: the lead thread of one attempt is
  # the runtime thread of its first Turn. The correlated lookup uses the
  # existing Job-attempt timeline index and never materializes the lineage.
  defp lineage_query(%Job{} = job) do
    TurnItem
    |> join(:inner, [row], turn in Turn, on: turn.id == row.turn_id)
    |> join(:inner, [_row, turn], lineage_job in Job, on: lineage_job.id == turn.job_id)
    |> where(
      [_row, _turn, lineage_job],
      lineage_job.workspace_owner_job_id == ^job.workspace_owner_job_id and
        lineage_job.agent_uid == ^job.agent_uid
    )
    |> where(
      [_row, turn, _job],
      fragment(
        "? = (SELECT lead.runtime_thread_id FROM background_agent_job_turns AS lead WHERE lead.job_id = ? AND lead.attempt = ? ORDER BY lead.started_at ASC, lead.id ASC LIMIT 1)",
        turn.runtime_thread_id,
        turn.job_id,
        turn.attempt
      )
    )
  end

  defp lineage_cursor_boundary(_job, nil), do: {:ok, nil}

  defp lineage_cursor_boundary(
         %Job{} = job,
         %{turn_id: turn_id, position: position, attempt: attempt}
       ) do
    boundary =
      job
      |> lineage_query()
      |> where([row], row.turn_id == ^turn_id and row.position == ^position)
      |> select([row, turn, _job], %{
        turn_id: row.turn_id,
        attempt: turn.attempt,
        started_at: turn.started_at,
        position: row.position
      })
      |> Repo.one()

    case boundary do
      %{attempt: ^attempt} -> {:ok, boundary}
      _other -> {:error, :invalid_background_agent_job_trajectory_cursor}
    end
  end

  defp lineage_after(query, nil), do: query

  defp lineage_after(query, %{started_at: started_at, turn_id: turn_id, position: position}) do
    where(
      query,
      [row, turn, _job],
      turn.started_at > ^started_at or
        (turn.started_at == ^started_at and turn.id > ^turn_id) or
        (turn.started_at == ^started_at and turn.id == ^turn_id and row.position > ^position)
    )
  end

  defp lineage_unit(row) do
    %{
      turn_id: row.turn_id,
      runtime_thread_id: row.runtime_thread_id,
      runtime_turn_id: row.runtime_turn_id,
      position: row.position,
      item_key: row.item_key,
      item: OpaqueContent.reveal(row.item)
    }
  end

  # Cursor

  defp decode_cursor(nil), do: {:ok, nil}
  defp decode_cursor(""), do: {:ok, nil}

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         {:ok,
          %{
            "v" => @cursor_version,
            "attempt" => attempt,
            "turn_id" => turn_id,
            "position" => position
          }} <- Ankole.JSON.decode(decoded),
         true <- is_integer(attempt) and attempt > 0,
         {:ok, turn_id} <- Ecto.UUID.cast(turn_id),
         true <- is_integer(position) and position >= 0 do
      {:ok, %{attempt: attempt, turn_id: turn_id, position: position}}
    else
      _reason -> {:error, :invalid_background_agent_job_trajectory_cursor}
    end
  end

  defp decode_cursor(_cursor), do: {:error, :invalid_background_agent_job_trajectory_cursor}

  defp encode_cursor(%{turn_id: turn_id, position: position}, turn_attempts) do
    %{
      "v" => @cursor_version,
      "attempt" => Map.fetch!(turn_attempts, turn_id),
      "turn_id" => turn_id,
      "position" => position
    }
    |> Ankole.JSON.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp encode_lineage_cursor(%{turn_id: turn_id, position: position, attempt: attempt}) do
    encode_cursor(%{turn_id: turn_id, position: position}, %{turn_id => attempt})
  end

  # A page of the current attempt expires with the attempt; the model learns
  # that its page reference is stale rather than invalid.
  defp check_fence(%{fence: attempt}, %{attempt: cursor_attempt})
       when is_integer(attempt) and cursor_attempt != attempt,
       do: {:error, :background_agent_job_trajectory_cursor_stale}

  defp check_fence(_walk, _cursor), do: :ok

  # The cursor must name one exact stored unit of one Turn in the scope;
  # anything else is invalid.
  defp start_walk(walk, nil), do: {:ok, walk_state(walk, nil)}

  defp start_walk(walk, %{turn_id: turn_id, position: position, attempt: attempt}) do
    with %Turn{attempt: ^attempt} <- Enum.find(walk.turns, &(&1.id == turn_id)),
         true <- cursor_unit_exists?(walk, turn_id, position) do
      {:ok, walk_state(walk, {turn_id, position})}
    else
      _other -> {:error, :invalid_background_agent_job_trajectory_cursor}
    end
  end

  defp cursor_unit_exists?(_walk, turn_id, position) do
    case Repo.get_by(TurnItem, turn_id: turn_id, position: position) do
      nil -> false
      %TurnItem{item: item} -> match?({[_ | _], _}, TurnItemProjection.project(item))
    end
  end

  # Walk

  # Rows arrive through a windowed query in walk order and project in memory,
  # so a page never loads the whole scope. `boundary` is the last row the
  # window passed together with the Turns entirely beyond it.
  defp walk_state(walk, cursor) do
    turn_ids = Enum.map(walk.turns, & &1.id)
    turn_index = turn_ids |> Enum.with_index() |> Map.new()

    %{
      walk: walk,
      turn_ids: turn_ids,
      turn_index: turn_index,
      turns_by_id: Map.new(walk.turns, &{&1.id, &1}),
      turn_meta: Map.new(walk.turns, &{&1.id, turn_meta(&1)}),
      cursor_turn_id: cursor && elem(cursor, 0),
      boundary: cursor && boundary(cursor, turn_index, turn_ids),
      batch: nil,
      bytes: nil,
      buffer: [],
      done: turn_ids == []
    }
  end

  defp boundary({turn_id, position}, turn_index, turn_ids) do
    passed_index = Map.fetch!(turn_index, turn_id)

    beyond =
      Enum.filter(turn_ids, fn id ->
        index = Map.fetch!(turn_index, id)
        index < passed_index
      end)

    {turn_id, position, beyond}
  end

  defp collect(%{walk: %{unit: :summary}} = state, %{bytes: bytes}) do
    {units, state} = state |> Map.put(:batch, @summary_item_window) |> take_units(1)

    units =
      Enum.map(units, fn unit ->
        Map.update!(unit, :text, &Text.truncate_utf8_window(&1, bytes, @truncation_suffix))
      end)

    build_page(state, units, false, nil)
  end

  defp collect(%{walk: %{unit: :group}} = state, %{groups: limit, bytes: bytes}) do
    {units, state} =
      state
      |> Map.merge(%{batch: (limit + 1) * @item_window_factor, bytes: bytes})
      |> take_units(limit + 1)

    units = Enum.reverse(units)
    selected = select_page_groups(units, limit, bytes)
    more? = length(units) > length(selected) and selected != []
    build_page(state, selected, more?, List.first(selected))
  end

  defp build_page(state, units, more?, edge_unit) do
    %{
      units: units,
      turn_ids: spanned_turn_ids(state, units, more?),
      next_cursor: if(more?, do: encode_cursor(edge_unit, turn_attempts(state)))
    }
  end

  defp turn_attempts(state),
    do: Map.new(state.turns_by_id, fn {id, turn} -> {id, turn.attempt} end)

  # The page spans every Turn from the walk start to the last delivered
  # unit's Turn, or to the end of the scope when nothing remains. The Turn a
  # cursor points into is spanned only when it still holds a delivered unit.
  defp spanned_turn_ids(%{turn_ids: []}, _units, _more?), do: []

  defp spanned_turn_ids(state, units, more?) do
    %{turn_ids: turn_ids, turn_index: turn_index} = state
    start_id = state.cursor_turn_id || List.last(turn_ids)
    start_index = Map.fetch!(turn_index, start_id)
    unit_turn_ids = MapSet.new(units, & &1.turn_id)

    range =
      case more? do
        false -> 0..start_index
        true -> Map.fetch!(turn_index, hd(units).turn_id)..start_index
      end

    turn_ids
    |> Enum.slice(range)
    |> Enum.reject(&(&1 == state.cursor_turn_id and not MapSet.member?(unit_turn_ids, &1)))
  end

  defp take_units(state, want), do: take_units(state, want, [])

  defp take_units(state, 0, acc), do: {Enum.reverse(acc), state}

  defp take_units(state, want, acc) do
    case peek_unit(state) do
      {nil, state} -> {Enum.reverse(acc), state}
      {unit, state} -> take_units(pop_unit(state), want - 1, [unit | acc])
    end
  end

  defp peek_unit(%{buffer: [unit | _rest]} = state), do: {unit, state}
  defp peek_unit(%{done: true} = state), do: {nil, state}

  defp peek_unit(state) do
    rows = fetch_window(state)

    state = %{
      state
      | done: length(rows) < state.batch,
        boundary: next_boundary(rows, state),
        buffer: Enum.flat_map(rows, &project_unit(&1, state))
    }

    peek_unit(state)
  end

  defp pop_unit(%{buffer: [_unit | rest]} = state), do: %{state | buffer: rest}

  defp fetch_window(%{turn_ids: turn_ids, boundary: boundary, batch: batch}) do
    TurnItem
    |> join(:inner, [row], turn in Turn, on: turn.id == row.turn_id)
    |> where([row], row.turn_id in ^turn_ids)
    |> window_beyond(boundary)
    |> order_by([row, turn], desc: turn.started_at, desc: turn.id, desc: row.position)
    |> limit(^batch)
    |> Repo.all()
  end

  defp window_beyond(query, nil), do: query

  defp window_beyond(query, {turn_id, position, beyond_turn_ids}) do
    where(
      query,
      [row],
      (row.turn_id == ^turn_id and row.position < ^position) or
        row.turn_id in ^beyond_turn_ids
    )
  end

  defp next_boundary([], %{boundary: boundary}), do: boundary

  defp next_boundary(rows, state) do
    last = List.last(rows)

    boundary(
      {last.turn_id, last.position},
      state.turn_index,
      state.turn_ids
    )
  end

  # Units

  defp project_unit(%TurnItem{} = row, %{walk: %{unit: :summary}}) do
    {messages, _truncated} = TurnItemProjection.project(row.item)

    messages
    |> Enum.reverse()
    |> Enum.find_value([], fn
      %{"role" => "assistant", "content" => content} when is_binary(content) and content != "" ->
        [%{turn_id: row.turn_id, position: row.position, text: content}]

      _message ->
        nil
    end)
  end

  defp project_unit(%TurnItem{} = row, %{walk: %{unit: :group}} = state) do
    case TurnItemProjection.project(row.item) do
      {[], _truncated} ->
        []

      {messages, projection_truncated} ->
        meta = Map.fetch!(state.turn_meta, row.turn_id)
        messages = if state.walk.reveal, do: OpaqueContent.reveal(messages), else: messages
        {bounded, bound_truncated} = bound_group(messages, state.bytes)

        [
          %{
            turn_id: row.turn_id,
            position: row.position,
            messages: bounded,
            redacted: meta.redacted,
            content_truncated: meta.content_truncated or projection_truncated or bound_truncated
          }
        ]
    end
  end

  defp turn_meta(%Turn{} = turn) do
    metadata = get_in(turn.trajectory || %{}, ["metadata"])

    %{
      redacted: is_map(metadata) and metadata["redacted"] == true,
      content_truncated: is_map(metadata) and metadata["content_truncated"] == true
    }
  end

  # Page selection and the truncation ladder

  defp select_page_groups(groups, limit, bytes) do
    groups
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn group, {selected, count} ->
      candidate = [group | selected]

      cond do
        count >= limit ->
          {:halt, {selected, count}}

        trajectory_messages_bytes(candidate) > bytes - @page_reserve_bytes ->
          {:halt, {selected, count}}

        true ->
          {:cont, {candidate, count + 1}}
      end
    end)
    |> elem(0)
  end

  defp trajectory_messages_bytes(groups) do
    Ankole.JSON.encode!(%{
      format: "ankole_chatml",
      version: 1,
      messages: Enum.flat_map(groups, & &1.messages)
    })
    |> byte_size()
  end

  defp bound_group(messages, bytes) do
    trimmed = trim_group(messages, 16)
    target = bytes - @page_reserve_bytes

    bounded =
      [@model_string_bytes, 2_000, 1_000, 500, 200, 64]
      |> Enum.find_value(fn limit ->
        candidate = Enum.map(trimmed, &bound_value(&1, limit))
        if encoded_bytes(candidate) <= target, do: candidate
      end)
      |> case do
        nil -> minimal_group(trimmed)
        candidate -> candidate
      end

    {bounded, bounded != messages}
  end

  defp trim_group(
         [%{"role" => "assistant", "tool_calls" => tool_calls} = assistant | rest],
         max_calls
       )
       when is_list(tool_calls) do
    retained_calls = Enum.take(tool_calls, max_calls)
    retained_ids = retained_calls |> Enum.map(&Map.get(&1, "id")) |> MapSet.new()

    retained_results =
      Enum.filter(rest, fn
        %{"role" => "tool", "tool_call_id" => id} -> MapSet.member?(retained_ids, id)
        _message -> false
      end)

    [Map.put(assistant, "tool_calls", retained_calls) | retained_results]
  end

  defp trim_group(messages, _max_calls), do: Enum.take(messages, 1)

  defp minimal_group([
         %{"role" => "assistant", "tool_calls" => [tool_call | _]} = assistant | rest
       ]) do
    id = Map.get(tool_call, "id", "bounded-tool-call")
    name = get_in(tool_call, ["function", "name"]) || "bounded_tool"
    namespace = get_in(tool_call, ["function", "namespace"])

    call =
      assistant
      |> Map.put(
        "content",
        Text.truncate_utf8_window(Map.get(assistant, "content", ""), 64, @truncation_suffix)
      )
      |> Map.put("tool_calls", [
        %{
          "id" => id,
          "type" => "function",
          "function" =>
            %{"name" => name, "arguments" => "{}"}
            |> Ankole.Attrs.maybe_put("namespace", namespace)
        }
      ])
      |> Map.delete("metadata")

    result =
      Enum.find(rest, fn
        %{"role" => "tool", "tool_call_id" => ^id} -> true
        _message -> false
      end)

    case result do
      %{} -> [call, bound_value(result, 64)]
      nil -> [call]
    end
  end

  defp minimal_group([message]), do: [bound_value(message, 64)]
  defp minimal_group(_messages), do: []

  defp encoded_bytes(value), do: value |> Ankole.JSON.encode!() |> byte_size()

  defp bound_value(value, limit) when is_binary(value) do
    Text.truncate_utf8_window(value, limit, @truncation_suffix)
  end

  defp bound_value(value, limit) when is_list(value) do
    value |> Enum.take(32) |> Enum.map(&bound_value(&1, limit))
  end

  defp bound_value(value, limit) when is_map(value) do
    value
    |> Enum.take(32)
    |> Map.new(fn {key, nested} -> {key, bound_value(nested, limit)} end)
  end

  defp bound_value(value, _limit), do: value
end
