defmodule Ankole.Plugins.WeComAdapter.AIStream do
  @moduledoc """
  Crash-recoverable streaming-reply lifecycle for WeCom.

  The carrier is the platform's native stream message: one reply is a chain of
  stream messages bound to the triggering callback's `req_id` (the 24-hour
  reply window). Each page refreshes with the full content snapshot under a
  deterministic stream id (`ankole:<event id>:<index>`), which makes every
  provider write replay-safe; `finish: true` seals a page.

  Paging runs on two axes: a 14KB source budget (20480-byte content cap with
  headroom for the status line and thought block) and the platform's rule that
  a stream must finish within 10 minutes of opening — an unsealed tail past 9
  minutes is frozen at its last written source, sealed, and the chain
  continues on a new stream message. PostgreSQL owns the durable page ledger
  (stream id, byte-exact source slice, opened-at, sealed flag); sealed pages
  are immutable history and only the remainder after the sealed prefix is ever
  re-split.

  There is no component model: the page content is Markdown. A working tail
  carries a status line and a quoted thought block that terminal writes
  remove; presentation actions are not rendered here — interactive choices
  reach the user as separate template cards through the `card` outbox path.

  A turn without a respond anchor (proactive trigger, or the anchor expired)
  cannot stream: working syncs return the non-retryable
  `{:cardkit_plain_text_fallback, _}` shape (the host disables the preview for
  the turn) and only the durable terminal delivery falls back — once — to
  plain Markdown sends, chunk-ledgered in the checkpoint so an outbox retry
  never re-sends a delivered chunk.
  """

  @behaviour Ankole.SignalsGateway.ReplyPreviewAdapter

  alias Ankole.Plugins.WeComAdapter.Config
  alias Ankole.Plugins.WeComAdapter.ConnectionOwner
  alias Ankole.Plugins.WeComAdapter.Markdown
  alias Ankole.Plugins.WeComAdapter.Outbox
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.ReplyPresentation
  alias Ankole.SignalsGateway.ReplyPreviewAdapter.Request
  alias WeComOpenAPI.Bot
  alias WeComOpenAPI.Error

  @checkpoint_version 1
  @page_budget_bytes 14_000
  # Seal an open page before the platform's 10-minute stream-finish deadline.
  @page_age_limit_seconds 9 * 60
  # Self-limit tail refreshes against the 30-messages-per-minute conversation
  # budget (whether stream refreshes count is smoke-test pending).
  @min_refresh_interval_ms 2_500
  @thought_lease_seconds 9 * 60

  @impl true
  def open(%Request{} = request), do: request |> reconcile(false, false) |> normalize_result()

  @impl true
  def update(%Request{} = request), do: request |> reconcile(false, false) |> normalize_result()

  @impl true
  def finalize(%Request{} = request), do: request |> reconcile(true, false) |> normalize_result()

  # Repaints the checkpointed presentation (thought-lease cleanup, resolved
  # interactions). The checkpointed presentation never carries a thought, so
  # the forced repaint strips stale reasoning before anything continues.
  @impl true
  def refresh(%Request{} = request) do
    final? = ReplyPresentation.terminal_state?(request.presentation)
    request |> reconcile(final?, true) |> normalize_result()
  end

  # --- core reconcile -------------------------------------------------------

  defp reconcile(%Request{} = request, final?, repaint?) do
    with {:ok, event} <- fresh_event(request.actor_event),
         {:ok, config} <- config_for_event(event) do
      checkpoint = current_checkpoint(event, request)
      presentation = ReplyPresentation.normalize(request.presentation)

      cond do
        checkpoint["degraded"] == true ->
          degrade(event, config, presentation, checkpoint, request, final?, :degraded)

        true ->
          case respond_anchor(event, checkpoint) do
            {:ok, req_id, checkpoint} ->
              case reconcile_stream(
                     event,
                     config,
                     req_id,
                     presentation,
                     checkpoint,
                     request,
                     final?,
                     repaint?
                   ) do
                {:error, :answer_rewrite_after_rollover = reason} ->
                  mark_degraded(event, checkpoint, presentation, request, reason)
                  degrade(event, config, presentation, checkpoint, request, final?, reason)

                other ->
                  other
              end

            :no_anchor ->
              mark_degraded(event, checkpoint, presentation, request, :no_reply_anchor)
              degrade(event, config, presentation, checkpoint, request, final?, :no_reply_anchor)
          end
      end
    end
  end

  # The respond anchor is captured once at open from the channel mirror (the
  # newest inbound in this channel is the turn's trigger) and pinned in the
  # checkpoint for the rest of the turn.
  defp respond_anchor(_event, %{"req_id" => req_id} = checkpoint) when is_binary(req_id),
    do: {:ok, req_id, checkpoint}

  defp respond_anchor(%ActorEvent{signal_channel_id: signal_channel_id}, checkpoint) do
    case Outbox.resolve_delivery(signal_channel_id) do
      {:ok, %{respond_req_id: req_id}} when is_binary(req_id) ->
        {:ok, req_id, Map.put(checkpoint, "req_id", req_id)}

      _no_anchor ->
        :no_anchor
    end
  end

  # Degrade once, and only on the durable terminal path. A transient working
  # sync must never post provider messages — returning the non-retryable
  # fallback shape makes the gateway disable the preview for the rest of the
  # turn while the outbox still delivers the final reply.
  defp degrade(event, config, presentation, checkpoint, request, final?, reason) do
    if final? do
      plain_text_delivery(event, config, presentation, checkpoint, request)
    else
      {:error, {:cardkit_plain_text_fallback, reason}}
    end
  end

  defp mark_degraded(event, checkpoint, presentation, request, reason) do
    checkpoint
    |> Map.merge(%{"degraded" => true, "degraded_reason" => to_string(reason)})
    |> merge_common(presentation, request, true)
    |> then(&Actors.put_reply_preview_checkpoint(event.id, &1))
  end

  # --- stream path ----------------------------------------------------------

  defp reconcile_stream(
         event,
         config,
         req_id,
         presentation,
         checkpoint,
         request,
         final?,
         repaint?
       ) do
    answer = answer_source(presentation, final?)

    with {:ok, client} <- bot_client(config),
         {:ok, pages} <- plan_pages(checkpoint, answer),
         {:ok, page_records, wrote?} <-
           reconcile_pages(
             client,
             req_id,
             event,
             presentation,
             pages,
             checkpoint,
             final?,
             repaint?
           ) do
      checkpoint =
        build_stream_checkpoint(checkpoint, page_records, presentation, request, final?, wrote?)

      with {:ok, _event} <- Actors.put_reply_preview_checkpoint(event.id, checkpoint) do
        {:ok, delivery_result(event, page_records, checkpoint)}
      end
    end
  end

  defp bot_client(config) do
    case ConnectionOwner.bot_client(config) do
      {:ok, client} -> {:ok, client}
      {:error, reason} -> {:error, %Error{reason: :not_connected, raw: reason}}
    end
  end

  # Sealed pages are pinned byte-exact source slices. An unsealed tail past the
  # page age limit is frozen at its last written source and marked to seal now,
  # so the platform's 10-minute finish deadline is never crossed with content
  # still owed to that page. Only the remainder after the frozen prefix is
  # re-split, so growth never moves an existing boundary. An answer that no
  # longer extends the frozen prefix is a rewrite — sealed stream messages
  # cannot be unwritten, so the reply degrades to plain text.
  defp plan_pages(checkpoint, answer) do
    ledger =
      Map.get(checkpoint, "pages", []) |> Enum.filter(&is_map/1) |> Enum.sort_by(& &1["index"])

    sealed = Enum.filter(ledger, &(&1["sealed"] == true))
    overage = ledger |> Enum.reject(&(&1["sealed"] == true)) |> Enum.filter(&page_over_age?/1)

    frozen =
      Enum.map(
        sealed,
        &%{index: &1["index"], source: &1["source"], seal_now?: false, frozen?: true}
      ) ++
        Enum.map(
          overage,
          &%{index: &1["index"], source: &1["source"], seal_now?: true, frozen?: true}
        )

    prefix = Enum.map_join(frozen, "", & &1.source)

    cond do
      prefix == "" ->
        {:ok, planned_pages(Markdown.split(answer, @page_budget_bytes), 0)}

      String.starts_with?(answer, prefix) ->
        remainder = binary_part(answer, byte_size(prefix), byte_size(answer) - byte_size(prefix))

        case remainder do
          "" ->
            {:ok, frozen}

          _grown ->
            {:ok,
             frozen ++
               planned_pages(Markdown.split(remainder, @page_budget_bytes), length(frozen))}
        end

      true ->
        {:error, :answer_rewrite_after_rollover}
    end
  end

  defp page_over_age?(record) do
    with opened_at when is_binary(opened_at) <- record["opened_at"],
         {:ok, at, _offset} <- DateTime.from_iso8601(opened_at) do
      DateTime.diff(DateTime.utc_now(), at) >= @page_age_limit_seconds
    else
      _missing -> false
    end
  end

  defp planned_pages(chunks, start_index) do
    chunks
    |> Enum.with_index(start_index)
    |> Enum.map(fn {source, index} ->
      %{index: index, source: source, seal_now?: false, frozen?: false}
    end)
  end

  defp reconcile_pages(client, req_id, event, presentation, pages, checkpoint, final?, repaint?) do
    ledger = ledger_by_index(checkpoint)
    last_index = pages |> List.last() |> Map.fetch!(:index)
    state = presentation["state"]
    now = DateTime.utc_now()

    pages
    |> Enum.reduce_while({:ok, [], false, false}, fn page, {:ok, records, fence_open?, wrote?} ->
      stream_id = page_stream_id(event, page.index)
      tail? = page.index == last_index
      prior = Map.get(ledger, page.index)

      # Finalize seals the tail into its finished form, except awaiting_input,
      # which keeps the stream open so the turn can continue after the answer;
      # the age axis still seals it if the wait outlives the page deadline.
      seal? =
        page.seal_now? or (page.frozen? and prior_sealed?(prior)) or not tail? or
          (final? and state != "awaiting_input")

      display = Markdown.display_chunk(page.source, fence_open?)
      content = render_page_content(presentation, display, tail?, seal?, final?, page)

      write_action =
        cond do
          prior_sealed?(prior) -> :skip
          seal? -> :write
          not tail? -> :write
          repaint? or final? -> :write
          throttled?(checkpoint, now) -> :skip
          true -> :write
        end

      write =
        case write_action do
          :skip ->
            :ok

          :write ->
            case Bot.reply_stream(client, req_id, stream_id, content, finish: seal?) do
              {:ok, _ack} -> :ok
              {:error, _reason} = error -> error
            end
        end

      case write do
        :ok ->
          record = %{
            "index" => page.index,
            "stream_id" => stream_id,
            "source" => page.source,
            "sealed" => seal?,
            "opened_at" => page_opened_at(prior, now)
          }

          {:cont,
           {:ok, [record | records], next_fence_state(fence_open?, page.source),
            wrote? or write_action == :write}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, records, _fence_open?, wrote?} -> {:ok, Enum.reverse(records), wrote?}
      {:error, _reason} = error -> error
    end
  end

  defp prior_sealed?(%{"sealed" => true}), do: true
  defp prior_sealed?(_prior), do: false

  defp page_opened_at(%{"opened_at" => opened_at}, _now) when is_binary(opened_at), do: opened_at
  defp page_opened_at(_prior, now), do: DateTime.to_iso8601(now)

  defp throttled?(checkpoint, now) do
    with at when is_binary(at) <- checkpoint["last_write_at"],
         {:ok, last, _offset} <- DateTime.from_iso8601(at) do
      DateTime.diff(now, last, :millisecond) < @min_refresh_interval_ms
    else
      _missing -> false
    end
  end

  defp next_fence_state(open_before?, source) do
    Markdown.fence_open?(if(open_before?, do: "```\n", else: "") <> source)
  end

  # --- rendering ------------------------------------------------------------

  # A rolled-past page holds a finished slice of a longer answer; a working
  # tail leads with the live status and the transient thought (a quote block
  # the terminal write removes); a terminal tail appends the curated closing
  # sections instead.
  defp render_page_content(presentation, display_answer, tail?, seal?, final?, page) do
    cond do
      not tail? or (seal? and not final?) ->
        join_blocks([display_answer, "*（续下一条）*"])

      final? ->
        join_blocks([
          terminal_state_line(presentation),
          display_answer,
          render_results(presentation["results"]),
          render_receipts(presentation["receipts"]),
          render_meta(presentation, page)
        ])

      true ->
        join_blocks([
          working_state_line(presentation),
          thought_block(presentation["thought"]),
          display_answer
        ])
    end
  end

  defp join_blocks(blocks) do
    blocks
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
    |> blank_to_space()
  end

  defp working_state_line(presentation) do
    status =
      case get_in(presentation, ["meta", "status"]) do
        status when is_binary(status) and status != "" -> status
        _absent -> "正在处理"
      end

    "▌ #{status}"
  end

  defp terminal_state_line(presentation) do
    case presentation["state"] do
      "continued" -> "⏸ 已暂停，后续处理续接于下一张卡片"
      "failed" -> "⚠️ 出错"
      "stopped" -> "⏹ 已停止"
      "awaiting_input" -> "⏸ 等待输入"
      _completed -> nil
    end
  end

  defp thought_block(thought) when is_binary(thought) and thought != "" do
    thought
    |> String.split("\n")
    |> Enum.map_join("\n", &("> " <> &1))
  end

  defp thought_block(_thought), do: nil

  defp render_results(items) when is_list(items) and items != [] do
    Enum.map_join(items, "\n", fn item -> "- #{item["title"] || item["kind"] || "result"}" end)
  end

  defp render_results(_items), do: nil

  defp render_receipts(items) when is_list(items) and items != [] do
    Enum.map_join(items, "\n", fn item ->
      scope = if item["scope"], do: "（#{item["scope"]}）", else: ""
      "- ✅ #{item["summary"] || ""}#{scope}"
    end)
  end

  defp render_receipts(_items), do: nil

  defp render_meta(presentation, page) do
    meta = presentation["meta"] || %{}

    [
      page_note(page),
      count_note(meta["memory_source_count"], &"#{&1} 条记忆来源"),
      count_note(meta["attachment_count"], &"已附上 #{&1} 个文件"),
      elapsed_note(meta["elapsed_ms"])
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      notes -> "*" <> Enum.join(notes, " · ") <> "*"
    end
  end

  defp page_note(%{index: index}) when index > 0, do: "第 #{index + 1} 条"
  defp page_note(_page), do: nil

  defp count_note(count, format) when is_integer(count) and count > 0, do: format.(count)
  defp count_note(_count, _format), do: nil

  defp elapsed_note(milliseconds) when is_integer(milliseconds) and milliseconds >= 1_000,
    do: "用时 #{Float.round(milliseconds / 1_000, 1)} 秒"

  defp elapsed_note(_milliseconds), do: nil

  defp answer_source(presentation, final?) do
    case presentation["answer"] do
      answer when is_binary(answer) and answer != "" ->
        answer

      _empty ->
        if final?, do: blank_to_space(ReplyPresentation.fallback_text(presentation)), else: " "
    end
  end

  defp blank_to_space(""), do: " "
  defp blank_to_space(text) when is_binary(text), do: text
  defp blank_to_space(_other), do: " "

  # --- checkpoint -----------------------------------------------------------

  defp current_checkpoint(%ActorEvent{reply_preview_checkpoint: checkpoint}, _request)
       when is_map(checkpoint),
       do: checkpoint

  defp current_checkpoint(_event, %Request{checkpoint: checkpoint}) when is_map(checkpoint),
    do: checkpoint

  defp current_checkpoint(_event, _request), do: %{}

  defp ledger_by_index(checkpoint) do
    checkpoint
    |> Map.get("pages", [])
    |> Enum.filter(&is_map/1)
    |> Map.new(&{&1["index"], &1})
  end

  defp build_stream_checkpoint(existing, page_records, presentation, request, final?, wrote?) do
    existing
    |> Map.merge(%{
      "streaming_state" => if(final?, do: "closed", else: "open"),
      "answer_content" => presentation["answer"] || "",
      "pages" => page_records
    })
    # Only an actual provider write advances the throttle clock; a skipped
    # refresh must not push the next one further out.
    |> then(fn checkpoint ->
      if wrote? do
        Map.put(checkpoint, "last_write_at", DateTime.to_iso8601(DateTime.utc_now()))
      else
        checkpoint
      end
    end)
    |> merge_common(presentation, request, final?)
  end

  # Checkpoint fields shared by the stream and degraded paths. The merge
  # preserves keys owned by the host (interaction ledger, refresh bookkeeping)
  # except the refresh flags this write just satisfied, and always carries the
  # last renderer-safe presentation so restart recovery and thought-lease
  # refreshes can repaint the surface.
  defp merge_common(checkpoint, presentation, request, final?) do
    checkpoint
    |> Map.put("version", @checkpoint_version)
    |> Map.put("presentation", ReplyPresentation.checkpoint(presentation))
    |> put_subject(request)
    |> put_thought_lease(presentation, final?)
    |> Map.delete("refresh_pending")
    |> Map.delete("refresh_reason")
  end

  defp put_subject(checkpoint, %Request{
         subject_uid: subject_uid,
         conversation_id: conversation_id
       }) do
    checkpoint
    |> maybe_put("subject_uid", subject_uid)
    |> maybe_put("conversation_id", conversation_id)
  end

  defp maybe_put(map, _key, value) when not is_binary(value), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp put_thought_lease(checkpoint, presentation, false) do
    case presentation["thought"] do
      thought when is_binary(thought) and thought != "" ->
        deadline =
          DateTime.utc_now(:microsecond)
          |> DateTime.add(@thought_lease_seconds, :second)
          |> DateTime.to_iso8601()

        Map.put(checkpoint, "cleanup_at", deadline)

      _absent ->
        Map.delete(checkpoint, "cleanup_at")
    end
  end

  defp put_thought_lease(checkpoint, _presentation, true),
    do: Map.delete(checkpoint, "cleanup_at")

  defp delivery_result(event, page_records, checkpoint) do
    first_stream_id = page_records |> List.first() |> then(&(&1 && &1["stream_id"]))

    %{
      created_source_entry_id: event.reply_preview_source_entry_id || first_stream_id,
      reply_preview_checkpoint: checkpoint,
      recovery_state: %{
        "streaming_state" => checkpoint["streaming_state"],
        "pages" => page_records
      }
    }
  end

  # --- degraded plain delivery ----------------------------------------------

  # Terminal-only fallback: the durable reply intent is still delivered, just
  # without a stream. Chunks ride the same Markdown split budget as Outbox
  # text, and each delivered chunk is ledgered in the checkpoint so an outbox
  # retry resumes after the last recorded chunk instead of re-sending it. The
  # proactive send path requires the user to have messaged the bot before; a
  # locked conversation surfaces as an operator-visible provider error.
  defp plain_text_delivery(event, config, presentation, checkpoint, request) do
    text =
      presentation
      |> ReplyPresentation.fallback_text()
      |> Markdown.to_wecom()
      |> blank_to_space()

    chunks = text |> Markdown.split(@page_budget_bytes) |> Markdown.display_chunks()
    ledger = plain_chunk_ledger(checkpoint)

    with {:ok, client} <- bot_client(config),
         {:ok, delivery} <- Outbox.resolve_delivery(event.signal_channel_id) do
      {records, failure} = deliver_plain_chunks(client, delivery, chunks, ledger)

      checkpoint =
        checkpoint
        |> Map.merge(%{
          "degraded" => true,
          "plain_chunks" => records,
          "streaming_state" => "closed"
        })
        |> merge_common(presentation, request, true)

      with {:ok, _event} <- Actors.put_reply_preview_checkpoint(event.id, checkpoint) do
        case failure do
          nil ->
            {:ok,
             %{
               created_source_entry_id: "wecom:degraded:#{event.id}",
               delivered_operation: :post,
               reply_preview_checkpoint: checkpoint,
               raw_payload: %{"plain_chunks" => length(records)}
             }}

          {:error, _reason} = error ->
            error
        end
      end
    end
  end

  defp deliver_plain_chunks(client, delivery, chunks, ledger) do
    chunks
    |> Enum.with_index()
    |> Enum.reduce_while({[], nil}, fn {chunk, index}, {records, nil} ->
      case Map.get(ledger, index) do
        %{"source" => ^chunk} = record ->
          {:cont, {[record | records], nil}}

        _missing_or_changed ->
          result =
            case delivery do
              %{respond_req_id: req_id} when is_binary(req_id) ->
                Bot.reply_markdown(client, req_id, chunk)

              _proactive ->
                Bot.send_markdown(client, delivery.chat_target, delivery.chat_type, chunk)
            end

          case result do
            {:ok, _ack} ->
              record = %{"index" => index, "source" => chunk}
              {:cont, {[record | records], nil}}

            {:error, _reason} = error ->
              {:halt, {records, error}}
          end
      end
    end)
    |> then(fn {records, failure} -> {Enum.reverse(records), failure} end)
  end

  defp plain_chunk_ledger(checkpoint) do
    checkpoint
    |> Map.get("plain_chunks", [])
    |> Enum.filter(&is_map/1)
    |> Map.new(&{&1["index"], &1})
  end

  # --- helpers --------------------------------------------------------------

  defp page_stream_id(%ActorEvent{id: id}, index), do: "ankole:#{id}:#{index}"

  defp config_for_event(%ActorEvent{} = event) do
    with {:ok, binding} <- SignalsGateway.get_binding(event.agent_uid, event.binding_name),
         {:ok, config} <- Config.load_chat_config_ref(binding.config_ref) do
      {:ok, config}
    else
      :error -> {:error, :binding_config_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp fresh_event(%ActorEvent{id: id}) do
    case Repo.get(ActorEvent, id) do
      %ActorEvent{} = event -> {:ok, event}
      nil -> {:error, :actor_event_not_found}
    end
  end

  # Provider errors use the same retry policy as plain outbox delivery;
  # deterministic degrades already returned the non-retryable fallback shape
  # from inside reconcile.
  defp normalize_result({:error, %Error{} = error}),
    do: Outbox.normalize_delivery_result({:error, error})

  defp normalize_result(result), do: result
end
