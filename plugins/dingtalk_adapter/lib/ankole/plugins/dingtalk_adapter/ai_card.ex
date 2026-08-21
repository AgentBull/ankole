defmodule Ankole.Plugins.DingTalkAdapter.AICard do
  @moduledoc """
  Crash-recoverable AI-card reply lifecycle for DingTalk.

  DingTalk cards are template-hosted: the operator builds the standard Ankole AI
  card template on the card platform (variable schema in
  `priv/card_template/README.md`) and supplies its `cardTemplateId`. Ankole
  injects the fixed variable set, streams `answer` through
  `PUT /v1.0/card/streaming` (`isFull: true`, mandatory for Markdown variables),
  and commits card structure through `PUT /v1.0/card/instances`.

  DingTalk owns the AI card state. A streaming update keeps the card in its
  input state, `isFinalize: true` moves it to the completed state, and
  `isError: true` moves it to the failed state. Instance writes merge by key
  (`cardUpdateOptions.updateCardDataByKey`) so a structural repaint does not
  clear template variables that it omits.

  One reply is a chain of cards. PostgreSQL owns the durable page ledger: each
  page's `outTrackId`, byte-exact source slice, and sealed flag. Sealed pages
  are immutable history — reconcile re-derives them from the ledger, only the
  remainder after the sealed prefix is ever re-split, and only changed pages
  receive provider writes, so a sealed (finalized) card is never re-streamed.
  `outTrackId` derives deterministically from the actor event and page index,
  making create/deliver/stream replay-safe across control-plane restarts. The
  checkpoint also carries the last renderer-safe `ReplyPresentation` and, while
  a thought is visible, a cleanup deadline, so the host lease sweeper can strip
  stale reasoning even when no preview process survives.

  Working-mode syncs never emit plain messages. A missing `cardTemplateId`, a
  permanent `param.contentUnsafe` rejection, or an answer rewrite behind the
  sealed prefix marks the reply degraded: transient syncs return a
  non-retryable error (the gateway disables the preview for the turn) and only
  the durable terminal delivery falls back — once — to plain Markdown messages.
  Fallback chunks are ledgered in the checkpoint so an outbox retry never
  re-sends a delivered chunk.
  """

  @behaviour Ankole.SignalsGateway.ReplyPreviewAdapter

  alias Ankole.Plugins.DingTalkAdapter.Config
  alias Ankole.Plugins.DingTalkAdapter.InteractiveCard
  alias Ankole.Plugins.DingTalkAdapter.Markdown
  alias Ankole.Plugins.DingTalkAdapter.Outbox
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.ReplyPresentation
  alias Ankole.SignalsGateway.ReplyPreviewAdapter.Request
  alias DingTalkOpenAPI.Card
  alias DingTalkOpenAPI.Error
  alias DingTalkOpenAPI.Robot

  @checkpoint_version 2
  # Conservative single-card source budget; the platform recommends ≤3K total per
  # card, so the chain rolls to a continuation card well before that.
  @page_budget_bytes 2_500
  # Degraded plain messages ride msgParam (≤15000 bytes); same budget as Outbox.
  @plain_budget_bytes 10_000
  @answer_key "answer"
  # While a transient thought is visible the checkpoint leases its cleanup so
  # the host sweeper can strip it after a crash (same lease as Lark CardKit).
  @thought_lease_seconds 9 * 60

  @impl true
  def open(%Request{} = request), do: request |> reconcile(false, false) |> normalize_result()

  @impl true
  def update(%Request{} = request), do: request |> reconcile(false, false) |> normalize_result()

  @impl true
  def finalize(%Request{} = request), do: request |> reconcile(true, false) |> normalize_result()

  # Repaints the checkpointed presentation (thought-lease cleanup, resolved
  # interactions). The checkpointed presentation never carries a thought, so the
  # forced structural repaint strips stale reasoning before anything continues.
  @impl true
  def refresh(%Request{} = request) do
    final? = ReplyPresentation.terminal_state?(request.presentation)
    request |> reconcile(final?, true) |> normalize_result()
  end

  # --- core reconcile ------------------------------------------------------

  defp reconcile(%Request{} = request, final?, repaint?) do
    with {:ok, event} <- fresh_event(request.actor_event),
         {:ok, config} <- config_for_event(event) do
      checkpoint = current_checkpoint(event, request)
      presentation = ReplyPresentation.normalize(request.presentation)
      template_id = card_template_id(config)

      cond do
        checkpoint["degraded"] == true ->
          degrade(event, config, presentation, checkpoint, request, final?, :degraded)

        is_nil(template_id) ->
          degrade(
            event,
            config,
            presentation,
            checkpoint,
            request,
            final?,
            :card_template_missing
          )

        true ->
          case reconcile_card(
                 event,
                 config,
                 template_id,
                 presentation,
                 checkpoint,
                 request,
                 final?,
                 repaint?
               ) do
            {:error, %Error{reason: :content_rejected} = error} ->
              mark_degraded(event, checkpoint, presentation, request, error.reason)
              degrade(event, config, presentation, checkpoint, request, final?, error.reason)

            {:error, :answer_rewrite_after_rollover = reason} ->
              mark_degraded(event, checkpoint, presentation, request, reason)
              degrade(event, config, presentation, checkpoint, request, final?, reason)

            other ->
              other
          end
      end
    end
  end

  # Degrade once, and only on the durable terminal path. A transient working
  # sync must never post provider messages — returning the non-retryable
  # cardkit_plain_text_fallback error makes the gateway disable the preview for
  # the rest of the turn while the outbox still delivers the final reply.
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

  # --- card path -----------------------------------------------------------

  defp reconcile_card(
         event,
         config,
         template_id,
         presentation,
         checkpoint,
         request,
         final?,
         repaint?
       ) do
    client = Config.client(config)
    robot_code = Config.effective_robot_code(config)
    answer = answer_source(presentation, final?)

    with {:ok, space} <- resolve_space(event),
         {:ok, pages} <- plan_pages(checkpoint, answer),
         {:ok, page_records, thought_digest} <-
           reconcile_pages(
             client,
             template_id,
             robot_code,
             space,
             event,
             presentation,
             pages,
             checkpoint,
             final?,
             repaint?
           ) do
      checkpoint =
        build_card_checkpoint(
          checkpoint,
          page_records,
          thought_digest,
          presentation,
          request,
          space,
          final?
        )

      with {:ok, _event} <- Actors.put_reply_preview_checkpoint(event.id, checkpoint) do
        {:ok, delivery_result(event, page_records, checkpoint)}
      end
    end
  end

  # Sealed pages are pinned byte-exact source slices; only the remainder after
  # the sealed prefix is re-split, so growth never moves an already-sealed
  # boundary. An answer that no longer extends the sealed prefix is a rewrite —
  # sealed cards cannot be unwritten, so the reply degrades to plain text.
  defp plan_pages(checkpoint, answer) do
    sealed = sealed_records(checkpoint)
    prefix = Enum.map_join(sealed, "", & &1["source"])

    cond do
      prefix == "" ->
        {:ok, planned_pages(Markdown.split(answer, @page_budget_bytes), 0)}

      String.starts_with?(answer, prefix) ->
        remainder = binary_part(answer, byte_size(prefix), byte_size(answer) - byte_size(prefix))

        base =
          Enum.map(sealed, &%{index: &1["index"], source: &1["source"], pinned_sealed?: true})

        case remainder do
          "" ->
            {:ok, base}

          _grown ->
            {:ok,
             base ++ planned_pages(Markdown.split(remainder, @page_budget_bytes), length(sealed))}
        end

      true ->
        {:error, :answer_rewrite_after_rollover}
    end
  end

  defp planned_pages(chunks, start_index) do
    chunks
    |> Enum.with_index(start_index)
    |> Enum.map(fn {source, index} -> %{index: index, source: source, pinned_sealed?: false} end)
  end

  defp reconcile_pages(
         client,
         template_id,
         robot_code,
         space,
         event,
         presentation,
         pages,
         checkpoint,
         final?,
         repaint?
       ) do
    ledger = ledger_by_index(checkpoint)
    created = created_out_track_ids(checkpoint)
    last_index = pages |> List.last() |> Map.fetch!(:index)
    page_count = length(pages)
    state = presentation["state"]

    pages
    |> Enum.reduce_while({:ok, [], false, nil}, fn page, {:ok, records, fence_open?, _digest} ->
      out_track_id = page_out_track_id(event, page.index)
      tail? = page.index == last_index
      created? = MapSet.member?(created, out_track_id)
      # Finalize seals the tail into the native finished state, except for
      # `awaiting_input`, which must stay open so template buttons remain live.
      seal? = page.pinned_sealed? or not tail? or (final? and state != "awaiting_input")
      error? = tail? and final? and state == "failed"
      prior = Map.get(ledger, page.index)
      display = Markdown.display_chunk(page.source, fence_open?)
      unchanged? = unchanged_page?(prior, page.source, seal?)
      thought = thought_write(checkpoint, presentation, tail?, created?, final?)

      card = %{tail?: tail?, page_index: page.index, page_count: page_count}

      # A page that seals receives one structural repaint for its continuation
      # label and cleared transient fields. The streaming update drives the
      # native state transition. An already-sealed page never writes again.
      commit? = (tail? and (final? or repaint?)) or (seal? and not sealed_page?(prior))

      write =
        with :ok <-
               maybe_create(
                 client,
                 template_id,
                 robot_code,
                 space,
                 out_track_id,
                 presentation,
                 display,
                 card,
                 created?
               ),
             :ok <-
               maybe_stream(client, out_track_id, display, page.source, seal?, error?, unchanged?),
             :ok <- maybe_stream_thought(client, out_track_id, thought),
             :ok <-
               maybe_write_terminal(
                 client,
                 out_track_id,
                 presentation,
                 display,
                 card,
                 commit?
               ) do
          :ok
        end

      case write do
        :ok ->
          record = %{
            "index" => page.index,
            "out_track_id" => out_track_id,
            "source" => page.source,
            "sealed" => seal?
          }

          digest = if tail?, do: written_thought_digest(checkpoint, thought), else: nil

          {:cont, {:ok, [record | records], next_fence_state(fence_open?, page.source), digest}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, records, _fence_open?, digest} -> {:ok, Enum.reverse(records), digest}
      {:error, _reason} = error -> error
    end
  end

  # The transient thought rides its own streamed variable on the tail card. The
  # checkpoint records a digest of the last written value, so an unchanged
  # thought costs no provider write and a fresh reconcile after restart knows
  # what the card currently shows. Terminal and repaint writes blank it through
  # the structural update instead.
  defp thought_write(_checkpoint, _presentation, false, _created?, _final?), do: :skip
  defp thought_write(_checkpoint, _presentation, _tail?, _created?, true), do: :skip

  defp thought_write(checkpoint, presentation, true, created?, false) do
    thought = text_or_empty(presentation["thought"])
    digest = thought_digest(thought)

    cond do
      created? == false -> {:written, digest}
      checkpoint["thought_digest"] == digest -> :skip
      thought == "" and is_nil(checkpoint["thought_digest"]) -> :skip
      true -> {:stream, thought, digest}
    end
  end

  defp maybe_stream_thought(_client, _out_track_id, :skip), do: :ok
  defp maybe_stream_thought(_client, _out_track_id, {:written, _digest}), do: :ok

  defp maybe_stream_thought(client, out_track_id, {:stream, thought, _digest}) do
    params = %{
      "outTrackId" => out_track_id,
      "guid" => guid(out_track_id, thought, false, false) <> "-t",
      "key" => "thought",
      "content" => thought,
      "isFull" => true,
      "isFinalize" => false,
      "isError" => false
    }

    case Card.streaming_update(client, params) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp written_thought_digest(checkpoint, :skip), do: checkpoint["thought_digest"]
  defp written_thought_digest(_checkpoint, {:written, digest}), do: digest
  defp written_thought_digest(_checkpoint, {:stream, _thought, digest}), do: digest

  defp thought_digest(""), do: nil

  defp thought_digest(thought) do
    :crypto.hash(:sha256, thought) |> Base.encode16(case: :lower) |> String.slice(0, 16)
  end

  defp unchanged_page?(%{"source" => source, "sealed" => sealed}, source, sealed), do: true
  defp unchanged_page?(_prior, _source, _seal), do: false

  defp sealed_page?(%{"sealed" => true}), do: true
  defp sealed_page?(_prior), do: false

  defp next_fence_state(open_before?, source) do
    Markdown.fence_open?(if(open_before?, do: "```\n", else: "") <> source)
  end

  defp maybe_create(
         _client,
         _template_id,
         _robot_code,
         _space,
         _otid,
         _presentation,
         _display,
         _card,
         true
       ),
       do: :ok

  defp maybe_create(
         client,
         template_id,
         robot_code,
         space,
         out_track_id,
         presentation,
         display,
         card,
         false
       ) do
    params =
      %{
        "cardTemplateId" => template_id,
        "outTrackId" => out_track_id,
        "callbackType" => "STREAM",
        "cardData" => %{"cardParamMap" => card_param_map(presentation, display, card)}
      }
      |> Map.merge(InteractiveCard.create_model(space))
      |> Map.merge(InteractiveCard.deliver_model(space, robot_code))

    case Card.create_and_deliver(client, params) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # An unchanged page (same source, same sealed state) gets no provider write:
  # sealed cards are immutable and repeated identical streams would only lean on
  # unverified platform guid dedup.
  defp maybe_stream(_client, _out_track_id, _display, _source, _seal, _error?, true), do: :ok

  defp maybe_stream(client, out_track_id, display, source, seal?, error?, false) do
    params = %{
      "outTrackId" => out_track_id,
      "guid" => guid(out_track_id, source, seal?, error?),
      "key" => @answer_key,
      "content" => display,
      "isFull" => true,
      "isFinalize" => seal?,
      "isError" => error?
    }

    case Card.streaming_update(client, params) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp maybe_write_terminal(_client, _out_track_id, _presentation, _display, _card, false),
    do: :ok

  # The instance write carries only this page's display slice — earlier pages
  # already hold their sealed slices, so writing the full answer here would
  # duplicate content and blow the per-card budget. `updateCardDataByKey` keeps
  # it a merge: a full replacement would clear the variables this map omits.
  defp maybe_write_terminal(client, out_track_id, presentation, display, card, true) do
    params = %{
      "outTrackId" => out_track_id,
      "cardData" => %{"cardParamMap" => terminal_param_map(presentation, display, card)},
      "cardUpdateOptions" => %{"updateCardDataByKey" => true}
    }

    case Card.update_instance(client, params) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # --- rendering -----------------------------------------------------------

  defp card_param_map(presentation, display_answer, card) do
    %{
      "state" => state_text(presentation, card),
      "answer" => display_answer,
      "thought" => text_or_empty(presentation["thought"]),
      "plan" => render_plan(presentation["plan"]),
      "activity" => render_activity(presentation["activities"]),
      "results" => render_results(presentation["results"]),
      "receipts" => render_receipts(presentation["receipts"]),
      "actions" => InteractiveCard.render_presentation_actions(presentation["actions"]),
      "meta" => render_meta(presentation, card)
    }
  end

  # A sealed page keeps no transient areas: the thinking draft and the running
  # activity list belong to a turn that is no longer writing into this card.
  defp terminal_param_map(presentation, display_answer, card) do
    params =
      presentation
      |> card_param_map(display_answer, card)
      |> Map.put("thought", "")

    if presentation["state"] == "continued" do
      params
    else
      Map.put(params, "activity", "")
    end
  end

  # A card the chain rolled past holds a finished slice of a longer answer, so
  # its status line points at the continuation rather than the turn's live state.
  defp state_text(_presentation, %{tail?: false}), do: "回答继续于下一张卡片"

  # While the turn works, the live tool label is a better status line than a
  # fixed word, matching the Feishu card.
  defp state_text(%{"state" => "working"} = presentation, _card) do
    case get_in(presentation, ["meta", "status"]) do
      status when is_binary(status) and status != "" -> status
      _absent -> "输入中"
    end
  end

  defp state_text(%{"state" => "completed"}, _card), do: "已完成"

  defp state_text(%{"state" => "continued"}, _card),
    do: "已暂停，后续处理续接于下一张卡片"

  defp state_text(%{"state" => "failed"}, _card), do: "出错"
  defp state_text(%{"state" => "stopped"}, _card), do: "已停止"
  defp state_text(%{"state" => "awaiting_input"}, _card), do: "等待输入"
  defp state_text(_presentation, _card), do: ""

  defp render_plan(%{"items" => items} = plan) when is_list(items) and items != [] do
    summary = plan["summary"] || %{}
    completed = summary["completed"] || 0
    total = summary["total"] || length(items)

    lines =
      Enum.map_join(items, "\n", fn item ->
        "- #{status_mark(item["status"])} #{item["content"] || ""}"
      end)

    "执行计划 · #{completed}/#{total}\n#{lines}"
  end

  defp render_plan(_plan), do: ""

  defp status_mark("completed"), do: "[x]"
  defp status_mark("cancelled"), do: "[-]"
  defp status_mark(_status), do: "[ ]"

  defp render_activity(activities) when is_map(activities) and map_size(activities) > 0 do
    activities
    |> Map.values()
    |> Enum.sort_by(&(&1["revision"] || 0))
    |> Enum.map_join("\n", fn activity ->
      "- #{activity_mark(activity["phase"])} #{activity["label"] || ""}"
    end)
  end

  defp render_activity(_activities), do: ""

  defp activity_mark("completed"), do: "✓"
  defp activity_mark("failed"), do: "✗"
  defp activity_mark(_phase), do: "…"

  defp render_results(items) when is_list(items) and items != [] do
    Enum.map_join(items, "\n", fn item -> "- #{item["title"] || item["kind"] || "result"}" end)
  end

  defp render_results(_items), do: ""

  defp render_receipts(items) when is_list(items) and items != [] do
    Enum.map_join(items, "\n", fn item ->
      scope = if item["scope"], do: "（#{item["scope"]}）", else: ""
      "- ✅ #{item["summary"] || ""}#{scope}"
    end)
  end

  defp render_receipts(_items), do: ""

  # Curated metadata, never the raw presentation keys: why this reply exists,
  # which card of the chain it is, and the counters worth a reader's attention.
  # `meta.status` stays out — it drives the state line instead.
  defp render_meta(presentation, card) do
    meta = presentation["meta"] || %{}

    [
      trigger_note(presentation["trigger_context"], card),
      page_note(card),
      count_note(meta["memory_source_count"], &"#{&1} 条记忆来源"),
      count_note(meta["attachment_count"], &"已附上 #{&1} 个文件"),
      elapsed_note(meta["elapsed_ms"])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp trigger_note(
         %{"kind" => "background_agent_job_failure", "title" => title} = context,
         %{page_index: 0}
       )
       when is_binary(title) do
    case context["summary"] do
      summary when is_binary(summary) and summary != "" ->
        "后台 Agent 任务「#{title}」失败：#{summary}"

      _absent ->
        "后台 Agent 任务「#{title}」失败"
    end
  end

  defp trigger_note(_context, _card), do: nil

  defp page_note(%{page_index: index, page_count: count}) when count > 1,
    do: "第 #{index + 1}/#{count} 张"

  defp page_note(_card), do: nil

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

  defp text_or_empty(text) when is_binary(text), do: text
  defp text_or_empty(_other), do: ""

  # --- space (group / DM) --------------------------------------------------

  defp resolve_space(%ActorEvent{signal_channel_id: signal_channel_id}) do
    conversation_id = decode_channel(signal_channel_id)

    case Repo.get(Channel, signal_channel_id) do
      %Channel{kind: :im_dm, metadata: metadata} ->
        case metadata["dm_user_id"] do
          user_id when is_binary(user_id) -> {:ok, {:dm, user_id}}
          _missing -> {:error, :dm_recipient_unknown}
        end

      _channel_or_nil ->
        {:ok, {:group, conversation_id}}
    end
  end

  defp decode_channel("dingtalk:" <> encoded), do: URI.decode(encoded)
  defp decode_channel(value), do: value

  # --- checkpoint ----------------------------------------------------------

  defp current_checkpoint(%ActorEvent{reply_preview_checkpoint: checkpoint}, _request)
       when is_map(checkpoint),
       do: checkpoint

  defp current_checkpoint(_event, %Request{checkpoint: checkpoint}) when is_map(checkpoint),
    do: checkpoint

  defp current_checkpoint(_event, _request), do: %{}

  defp sealed_records(checkpoint) do
    checkpoint
    |> Map.get("pages", [])
    |> Enum.filter(&(is_map(&1) and &1["sealed"] == true and is_binary(&1["source"])))
    |> Enum.sort_by(& &1["index"])
  end

  defp ledger_by_index(checkpoint) do
    checkpoint
    |> Map.get("pages", [])
    |> Enum.filter(&is_map/1)
    |> Map.new(&{&1["index"], &1})
  end

  defp created_out_track_ids(checkpoint) do
    checkpoint
    |> Map.get("pages", [])
    |> Enum.map(&Map.get(&1, "out_track_id"))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp build_card_checkpoint(
         existing,
         page_records,
         thought_digest,
         presentation,
         request,
         {kind, target},
         final?
       ) do
    existing
    |> Map.merge(%{
      "streaming_state" => if(final?, do: "closed", else: "open"),
      "answer_content" => presentation["answer"] || "",
      "pages" => page_records,
      "space_kind" => Atom.to_string(kind),
      "space_target" => target
    })
    |> put_or_delete("thought_digest", if(final?, do: nil, else: thought_digest))
    |> merge_common(presentation, request, final?)
  end

  defp put_or_delete(map, key, nil), do: Map.delete(map, key)
  defp put_or_delete(map, key, value), do: Map.put(map, key, value)

  # Checkpoint fields shared by the card and degraded paths. The merge preserves
  # keys owned by the host (interaction ledger, refresh bookkeeping) except the
  # refresh flags this write just satisfied, and always carries the last
  # renderer-safe presentation so restart recovery and thought-lease refreshes
  # can repaint the surface.
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
    |> put_text("subject_uid", subject_uid)
    |> put_text("conversation_id", conversation_id)
  end

  defp put_text(map, _key, value) when not is_binary(value), do: map
  defp put_text(map, key, value), do: Map.put(map, key, value)

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
    first_out_track_id =
      page_records |> List.first() |> then(&(&1 && &1["out_track_id"]))

    %{
      created_source_entry_id: event.reply_preview_source_entry_id || first_out_track_id,
      reply_preview_checkpoint: checkpoint,
      recovery_state: %{
        "streaming_state" => checkpoint["streaming_state"],
        "pages" => page_records
      }
    }
  end

  # --- degraded plain delivery ----------------------------------------------

  # Terminal-only fallback: the durable reply intent is still delivered, just
  # without a card. Chunks ride the same Markdown split budget as Outbox text,
  # and each delivered chunk is ledgered in the checkpoint so an outbox retry
  # resumes after the last recorded chunk instead of re-sending it.
  defp plain_text_delivery(event, config, presentation, checkpoint, request) do
    client = Config.client(config)
    robot_code = Config.effective_robot_code(config)

    text =
      presentation
      |> ReplyPresentation.fallback_text()
      |> Markdown.to_dingtalk()
      |> blank_to_space()

    chunks = text |> Markdown.split(@plain_budget_bytes) |> Markdown.display_chunks()
    ledger = plain_chunk_ledger(checkpoint)

    with {:ok, space} <- resolve_space(event) do
      {records, failure} = deliver_plain_chunks(client, robot_code, space, chunks, ledger)

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
               created_source_entry_id: first_process_query_key(records),
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

  defp deliver_plain_chunks(client, robot_code, space, chunks, ledger) do
    chunks
    |> Enum.with_index()
    |> Enum.reduce_while({[], nil}, fn {chunk, index}, {records, nil} ->
      case Map.get(ledger, index) do
        %{"source" => ^chunk} = record ->
          {:cont, {[record | records], nil}}

        _missing_or_changed ->
          case send_plain_chunk(client, robot_code, space, chunk) do
            {:ok, process_query_key} ->
              record = %{
                "index" => index,
                "source" => chunk,
                "process_query_key" => process_query_key
              }

              {:cont, {[record | records], nil}}

            {:error, _reason} = error ->
              {:halt, {records, error}}
          end
      end
    end)
    |> then(fn {records, failure} -> {Enum.reverse(records), failure} end)
  end

  defp send_plain_chunk(client, robot_code, space, chunk) do
    msg_key = if Markdown.formatted?(chunk), do: "sampleMarkdown", else: "sampleText"

    msg_param =
      case msg_key do
        "sampleMarkdown" -> %{"title" => "AI", "text" => chunk}
        "sampleText" -> %{"content" => chunk}
      end

    result =
      case space do
        {:dm, user_id} ->
          Robot.batch_send_oto(client,
            robot_code: robot_code,
            user_ids: [user_id],
            msg_key: msg_key,
            msg_param: msg_param
          )

        {:group, conversation_id} ->
          Robot.send_group_message(client,
            open_conversation_id: conversation_id,
            robot_code: robot_code,
            msg_key: msg_key,
            msg_param: msg_param
          )
      end

    case result do
      {:ok, %{"processQueryKey" => pqk}} when is_binary(pqk) -> {:ok, pqk}
      {:ok, _body} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  defp plain_chunk_ledger(checkpoint) do
    checkpoint
    |> Map.get("plain_chunks", [])
    |> Enum.filter(&is_map/1)
    |> Map.new(&{&1["index"], &1})
  end

  defp first_process_query_key(records) do
    Enum.find_value(records, fn record ->
      case record["process_query_key"] do
        pqk when is_binary(pqk) -> pqk
        _absent -> nil
      end
    end)
  end

  # --- helpers -------------------------------------------------------------

  defp card_template_id(config) do
    case Map.get(config, "cardTemplateId") do
      id when is_binary(id) -> if String.trim(id) == "", do: nil, else: id
      _absent -> nil
    end
  end

  defp page_out_track_id(%ActorEvent{id: id}, index), do: "ankole:#{id}:#{index}"

  # A content-derived guid means an identical retry reuses the same idempotency
  # key while any real change gets a new one.
  defp guid(out_track_id, source, seal?, error?) do
    :crypto.hash(:sha256, "#{out_track_id}:#{seal?}:#{error?}:#{source}")
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
  end

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

  # Provider errors surface classified (retryable / operator_action_required /
  # permanent) so the gateway can retry, block, or stop; deterministic degrades
  # already returned the non-retryable cardkit_plain_text_fallback shape from
  # inside reconcile.
  defp normalize_result({:error, %Error{} = error}),
    do: Outbox.normalize_delivery_result({:error, error})

  defp normalize_result(result), do: result
end
