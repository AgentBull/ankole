defmodule Ankole.Plugins.LarkAdapter.CardKit do
  @moduledoc """
  Crash-recoverable CardKit reply lifecycle for Lark / Feishu.

  PostgreSQL owns the provider handle, the acknowledged semantic projection,
  and the global CardKit sequence high-water mark. Live processes are only
  debouncers: after a control-plane restart the same card is adopted and a
  strictly higher sequence is leased before the next mutation.
  """

  @behaviour Ankole.SignalsGateway.ReplyPreviewAdapter

  alias Ankole.Plugins.LarkAdapter.CardKit.CardChain
  alias Ankole.Plugins.LarkAdapter.CardKit.ErrorPolicy
  alias Ankole.Plugins.LarkAdapter.CardKit.ImageResolver
  alias Ankole.Plugins.LarkAdapter.CardKit.Renderer
  alias Ankole.Plugins.LarkAdapter.CardKit.WriteLimiter
  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.Plugins.LarkAdapter.Outbox, as: LarkOutbox
  alias Ankole.Logging
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.ReplyPresentation
  alias Ankole.SignalsGateway.ReplyPreviewAdapter.Request
  alias FeishuOpenAPI.Error

  @checkpoint_version 1
  @stream_lease_seconds 9 * 60
  @replacement_limit 1
  @card_id_retry_delays_ms [250, 750, 1_500, 3_000, 5_000]

  @impl true
  def open(%Request{} = request),
    do: request |> open_result() |> normalize_lifecycle_result()

  defp open_result(%Request{} = request) do
    with {:ok, event} <- fresh_event(request.actor_event),
         {:ok, config} <- config_for_event(event),
         client <- Config.client(config),
         request_fun <- &FeishuOpenAPI.request/4,
         {:ok, render_request, image_state} <-
           resolve_render_request(event, %{}, request, client),
         pages <- CardChain.pages(render_request.presentation),
         first_page <- CardChain.page_at(pages, 0),
         first_tail? <- length(pages) == 1,
         render_opts <- CardChain.page_opts(first_page, 0, length(pages), first_tail?),
         {:ok, card} <-
           Renderer.render(
             render_request.presentation,
             Keyword.put(render_opts, :mode, request.mode)
           ),
         {:ok, card_id} <- create_card(client, card, request_fun),
         {:ok, checkpoint} <-
           checkpoint_created_card(
             event,
             request,
             render_request,
             image_state,
             card_id,
             first_page,
             first_tail?,
             render_opts
           ),
         {:ok, checkpoint, send_result} <-
           ensure_card_sent(event, checkpoint, client, request_fun),
         {:ok, checkpoint, chain_result} <-
           ensure_page_chain(
             event,
             checkpoint,
             render_request,
             request.presentation,
             pages,
             client,
             request_fun
           ),
         {:ok, event} <- Actors.put_reply_preview_checkpoint(event.id, checkpoint) do
      {:ok,
       delivery_result(
         event.reply_preview_source_entry_id || first_message_id(checkpoint),
         checkpoint
       )
       |> Map.merge(send_result)
       |> Map.merge(chain_result)}
    end
  end

  @impl true
  def update(%Request{} = request) do
    with {:ok, event} <- fresh_event(request.actor_event),
         checkpoint when is_map(checkpoint) <- event.reply_preview_checkpoint,
         card_id when is_binary(card_id) <- checkpoint["card_id"] do
      do_update(event, checkpoint, card_id, request)
    else
      nil -> open_result(request)
      {:error, _reason} = error -> error
      _missing_card_id -> open_result(request)
    end
    |> normalize_lifecycle_result()
  end

  @impl true
  def finalize(%Request{} = request) do
    case finalize_result(request) do
      {:error, :cardkit_soft_budget_exceeded} ->
        plain_text_fallback(request.actor_event, request)

      {:error, %Error{} = error} ->
        case ErrorPolicy.action(error) do
          :plain_text_fallback -> plain_text_fallback(request.actor_event, request)
          _action -> normalize_lifecycle_result({:error, error})
        end

      result ->
        normalize_lifecycle_result(result)
    end
  end

  @impl true
  def refresh(%Request{} = request) do
    with {:ok, event} <- fresh_event(request.actor_event),
         %{"card_id" => card_id, "refresh_pending" => true} = checkpoint
         when is_binary(card_id) <- event.reply_preview_checkpoint,
         {:ok, config} <- config_for_event(event),
         client <- Config.client(config),
         request_fun <- &FeishuOpenAPI.request/4,
         request <- refresh_request(request, event, checkpoint),
         request <- apply_checkpoint_images(request, checkpoint),
         pages <- CardChain.pages(request.presentation),
         {active_page, render_opts} <- active_render_context(pages, checkpoint),
         {:ok, actions, close_streaming?} <-
           refresh_actions(request, checkpoint, render_opts),
         :ok <- apply_refresh_actions(event, card_id, actions, client, request_fun),
         checkpoint <-
           refreshed_checkpoint(
             checkpoint,
             request.presentation,
             close_streaming?,
             render_opts,
             active_page
           ),
         {:ok, _event} <- Actors.put_reply_preview_checkpoint(event.id, checkpoint) do
      {:ok, delivery_result(first_message_id(checkpoint), checkpoint)}
    else
      %{} -> {:error, :reply_preview_refresh_not_pending}
      nil -> {:error, :reply_preview_refresh_not_pending}
      {:error, _reason} = error -> error
    end
    |> normalize_lifecycle_result()
  end

  defp finalize_result(%Request{} = request) do
    request = %{request | mode: :terminal}

    with {:ok, event} <- fresh_event(request.actor_event) do
      case event.reply_preview_checkpoint do
        %{
          "streaming_state" => "closed",
          "message_id" => message_id,
          "card_id" => card_id
        } = checkpoint
        when is_binary(message_id) and is_binary(card_id) ->
          if terminal_checkpoint_matches?(checkpoint, request.presentation) do
            {:ok, delivery_result(message_id, checkpoint)}
          else
            do_finalize(event, checkpoint, card_id, request)
          end

        %{"card_id" => card_id} = checkpoint when is_binary(card_id) ->
          do_finalize(event, checkpoint, card_id, request)

        _checkpoint ->
          case open_result(request) do
            {:error, :cardkit_soft_budget_exceeded} ->
              plain_text_fallback(event, request)

            result ->
              result
          end
      end
    end
  end

  defp do_update(event, checkpoint, _card_id, request) do
    with {:ok, config} <- config_for_event(event),
         client <- Config.client(config),
         request_fun <- &FeishuOpenAPI.request/4,
         {:ok, checkpoint, send_result} <-
           ensure_card_sent(event, checkpoint, client, request_fun),
         {:ok, render_request, image_state} <-
           resolve_render_request(event, checkpoint, request, client),
         {:ok, checkpoint} <- persist_markdown_images(event, checkpoint, image_state),
         pages <- CardChain.pages(render_request.presentation),
         {:ok, checkpoint, chain_result} <-
           ensure_page_chain(
             event,
             checkpoint,
             render_request,
             request.presentation,
             pages,
             client,
             request_fun
           ),
         %{"card_id" => card_id} <- CardChain.active_card(checkpoint),
         {active_page, render_opts} <- active_render_context(pages, checkpoint),
         {:ok, checkpoint} <-
           arm_transient_element_cleanup(
             event,
             checkpoint,
             render_request.presentation,
             render_opts
           ),
         {:ok, answer_content, actions, streaming_state} <-
           update_mutations(render_request, checkpoint, render_opts),
         :ok <-
           maybe_reopen_working_stream(
             event,
             checkpoint,
             card_id,
             streaming_state,
             render_request,
             client,
             request_fun,
             render_opts
           ),
         {:ok, checkpoint} <-
           apply_working_content(
             event,
             checkpoint,
             card_id,
             answer_content,
             streaming_state,
             render_request,
             client,
             request_fun,
             render_opts
           ),
         :ok <-
           apply_working_actions(
             event,
             card_id,
             actions,
             streaming_state,
             render_request,
             client,
             request_fun
           ),
         {:ok, checkpoint} <-
           persist_acknowledged_checkpoint(
             event,
             checkpoint,
             request.presentation,
             streaming_state,
             render_opts,
             active_page
           ) do
      {:ok,
       delivery_result(first_message_id(checkpoint), checkpoint)
       |> Map.merge(send_result)
       |> Map.merge(chain_result)}
    else
      {:error, %Error{} = error} -> recover_update(error, event, checkpoint, request)
      {:error, _reason} = error -> error
    end
  end

  defp do_finalize(event, checkpoint, _card_id, request) do
    with {:ok, config} <- config_for_event(event),
         client <- Config.client(config),
         request_fun <- &FeishuOpenAPI.request/4,
         {:ok, checkpoint, send_result} <-
           ensure_card_sent(event, checkpoint, client, request_fun),
         {:ok, render_request, image_state} <-
           resolve_render_request(event, checkpoint, request, client),
         {:ok, checkpoint} <- persist_markdown_images(event, checkpoint, image_state),
         pages <- CardChain.pages(render_request.presentation),
         {:ok, checkpoint, chain_result} <-
           ensure_page_chain(
             event,
             checkpoint,
             render_request,
             request.presentation,
             pages,
             client,
             request_fun
           ),
         %{"card_id" => card_id} <- CardChain.active_card(checkpoint),
         {active_page, render_opts} <- active_render_context(pages, checkpoint),
         :ok <-
           close_terminal_stream(
             event,
             checkpoint,
             card_id,
             render_request.presentation,
             client,
             request_fun
           ),
         {:ok, actions} <- terminal_actions(render_request, checkpoint, render_opts),
         :ok <- apply_terminal_actions(event, card_id, actions, client, request_fun),
         checkpoint <-
           terminal_checkpoint(checkpoint, request.presentation, render_opts, active_page),
         {:ok, _event} <- Actors.put_reply_preview_checkpoint(event.id, checkpoint) do
      {:ok,
       delivery_result(first_message_id(checkpoint), checkpoint)
       |> Map.merge(send_result)
       |> Map.merge(chain_result)}
    else
      {:error, %Error{} = error} ->
        recover_finalize(error, event, checkpoint, request)

      {:error, :cardkit_soft_budget_exceeded} ->
        plain_text_fallback(event, request)

      {:error, :cardkit_answer_rewrite_after_rollover} ->
        plain_text_fallback(event, request)

      {:error, _reason} = error ->
        error
    end
  end

  defp resolve_render_request(event, checkpoint, request, client) do
    image_state = Map.get(checkpoint, "markdown_images", %{})

    with {:ok, presentation, image_state} <-
           ImageResolver.resolve(request.presentation, event.agent_uid, image_state, client) do
      previous_presentation =
        case request.previous_presentation do
          previous when is_map(previous) -> ImageResolver.apply_resolved(previous, image_state)
          _missing -> nil
        end

      {:ok, %{request | presentation: presentation, previous_presentation: previous_presentation},
       image_state}
    end
  end

  defp apply_checkpoint_images(request, checkpoint) do
    image_state = Map.get(checkpoint, "markdown_images", %{})

    %{
      request
      | presentation: ImageResolver.apply_resolved(request.presentation, image_state),
        previous_presentation:
          case request.previous_presentation do
            previous when is_map(previous) -> ImageResolver.apply_resolved(previous, image_state)
            _missing -> nil
          end
    }
  end

  defp persist_markdown_images(event, checkpoint, image_state) do
    if checkpoint["markdown_images"] == image_state do
      {:ok, checkpoint}
    else
      checkpoint = Map.put(checkpoint, "markdown_images", image_state)

      with {:ok, _event} <- Actors.put_reply_preview_checkpoint(event.id, checkpoint) do
        {:ok, checkpoint}
      end
    end
  end

  defp apply_working_actions(_event, _card_id, [], _state, _request, _client, _request_fun),
    do: :ok

  defp apply_working_actions(
         event,
         card_id,
         actions,
         streaming_state,
         request,
         client,
         request_fun
       ) do
    case apply_batch_mutation(
           event,
           card_id,
           actions,
           "working",
           client,
           request_fun
         ) do
      :ok ->
        :ok

      {:error, %Error{} = error} ->
        if ErrorPolicy.action(error) == :reopen_stream and streaming_state == "open" do
          with :ok <-
                 reopen_stream(event, card_id, request.presentation, client, request_fun),
               :ok <-
                 apply_batch_mutation(
                   event,
                   card_id,
                   actions,
                   "working",
                   client,
                   request_fun
                 ) do
            :ok
          end
        else
          {:error, error}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp apply_working_content(
         _event,
         checkpoint,
         _card_id,
         nil,
         _streaming_state,
         _request,
         _client,
         _request_fun,
         _render_opts
       ),
       do: {:ok, checkpoint}

  defp apply_working_content(
         event,
         checkpoint,
         card_id,
         content,
         streaming_state,
         request,
         client,
         request_fun,
         _render_opts
       ) do
    case apply_content_mutation(event, card_id, content, client, request_fun) do
      :ok ->
        persist_acknowledged_answer_content(event, checkpoint, content)

      {:error, %Error{} = error} ->
        if ErrorPolicy.action(error) == :reopen_stream and streaming_state == "open" do
          with :ok <- reopen_stream(event, card_id, request.presentation, client, request_fun),
               :ok <- apply_content_mutation(event, card_id, content, client, request_fun) do
            persist_acknowledged_answer_content(event, checkpoint, content)
          end
        else
          {:error, error}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp maybe_reopen_working_stream(
         event,
         checkpoint,
         card_id,
         "open",
         request,
         client,
         request_fun,
         _render_opts
       ) do
    if checkpoint["streaming_state"] == "open" do
      :ok
    else
      reopen_stream(event, card_id, request.presentation, client, request_fun)
    end
  end

  defp maybe_reopen_working_stream(
         _event,
         _checkpoint,
         _card_id,
         "closed",
         _request,
         _client,
         _request_fun,
         _render_opts
       ),
       do: :ok

  defp reopen_stream(event, card_id, presentation, client, request_fun) do
    apply_batch_mutation(
      event,
      card_id,
      [streaming_setting_action(true, presentation)],
      "reopen",
      client,
      request_fun
    )
  end

  defp close_terminal_stream(event, checkpoint, card_id, presentation, client, request_fun) do
    if checkpoint["streaming_state"] == "open" do
      apply_batch_mutation(
        event,
        card_id,
        [streaming_setting_action(false, presentation)],
        "terminal_close",
        client,
        request_fun
      )
    else
      :ok
    end
  end

  defp apply_terminal_actions(_event, _card_id, [], _client, _request_fun), do: :ok

  defp apply_terminal_actions(event, card_id, actions, client, request_fun) do
    apply_batch_mutation(event, card_id, actions, "terminal", client, request_fun)
  end

  defp recover_update(error, event, checkpoint, request) do
    log_recovery(:update, error, event, checkpoint, request)

    case ErrorPolicy.action(error) do
      :replace_card ->
        replace_card(event, checkpoint, request)

      :plain_text_fallback ->
        {:error, {:cardkit_plain_text_fallback, ErrorPolicy.provider_error(error)}}

      :operator_action_required ->
        {:error, {:reply_delivery, :operator_action_required, ErrorPolicy.provider_error(error)}}

      _retry ->
        {:error, {:reply_delivery, :retryable, ErrorPolicy.provider_error(error)}}
    end
  end

  defp recover_finalize(error, event, checkpoint, request) do
    log_recovery(:finalize, error, event, checkpoint, request)

    case ErrorPolicy.action(error) do
      :replace_card ->
        replace_card(event, checkpoint, request)

      :plain_text_fallback ->
        plain_text_fallback(event, request)

      :operator_action_required ->
        {:error, {:reply_delivery, :operator_action_required, ErrorPolicy.provider_error(error)}}

      _retry ->
        {:error, {:reply_delivery, :retryable, ErrorPolicy.provider_error(error)}}
    end
  end

  defp log_recovery(stage, error, event, checkpoint, request) do
    Logging.warning(
      "lark_adapter.cardkit.recovery",
      "Lark CardKit provider operation requires recovery",
      %{
        actor_event_id: event.id,
        card_id: checkpoint["card_id"],
        mode: request.mode,
        operation: stage,
        provider_error: ErrorPolicy.provider_error(error),
        recovery_action: ErrorPolicy.action(error)
      }
    )
  end

  defp replace_card(event, checkpoint, request) do
    replacements = non_negative_integer(checkpoint["replacement_count"])

    if replacements >= @replacement_limit do
      if request.mode == :terminal do
        plain_text_fallback(event, request)
      else
        {:error, :cardkit_replacement_exhausted}
      end
    else
      replacement_checkpoint = %{
        "schema_version" => @checkpoint_version,
        "adapter" => "lark",
        "replacement_count" => replacements + 1,
        "replaced_card_id" => checkpoint["card_id"],
        "replaced_message_id" => checkpoint["message_id"],
        "streaming_state" => "replaced",
        "presentation" => ReplyPresentation.checkpoint(request.presentation),
        "subject_uid" => request.subject_uid || checkpoint["subject_uid"],
        "conversation_id" => request.conversation_id || checkpoint["conversation_id"]
      }

      with {:ok, _event} <- Actors.put_reply_preview_checkpoint(event.id, replacement_checkpoint) do
        open_result(%{request | checkpoint: replacement_checkpoint})
      end
    end
  end

  defp checkpoint_created_card(
         event,
         request,
         render_request,
         image_state,
         card_id,
         page,
         tail?,
         render_opts
       ) do
    now = DateTime.utc_now(:microsecond)
    previous = event.reply_preview_checkpoint || request.checkpoint || %{}

    element_ids =
      Renderer.element_ids(
        render_request.presentation,
        Keyword.put(render_opts, :mode, request.mode)
      )

    stream_open? = request.mode != :terminal and tail?
    stream_deadline_at = if(stream_open?, do: stream_deadline(), else: nil)
    card_state = if(stream_open?, do: "open", else: if(tail?, do: "closed", else: "sealed"))

    card =
      CardChain.card_record(
        0,
        card_id,
        previous["message_uuid"] || card_message_uuid(event.id, 0),
        page,
        card_state,
        element_ids
      )

    checkpoint =
      %{
        "schema_version" => @checkpoint_version,
        "adapter" => "lark",
        "subject_uid" => request.subject_uid || previous["subject_uid"],
        "conversation_id" => request.conversation_id || previous["conversation_id"],
        "stream_deadline_at" => stream_deadline_at,
        "opened_at" => DateTime.to_iso8601(now),
        "replacement_count" => non_negative_integer(previous["replacement_count"]),
        "presentation" => ReplyPresentation.checkpoint(request.presentation),
        "markdown_images" => image_state
      }
      |> CardChain.initialize(card)
      |> put_cleanup_at(element_ids, stream_deadline_at)

    with {:ok, _event} <- Actors.put_reply_preview_checkpoint(event.id, checkpoint) do
      {:ok, checkpoint}
    end
  end

  # A CardKit mutation can reach Feishu while its HTTP result or the following
  # checkpoint write is lost. Stage a conservative element/cleanup lease before
  # sending any mutation that may expose transient thought. The checkpoint may
  # therefore name an element Feishu never committed; `apply_batch_mutation/6`
  # makes cleanup idempotent before it submits any critical content mutation.
  defp arm_transient_element_cleanup(event, checkpoint, presentation, render_opts) do
    current_ids = Renderer.element_ids(presentation, Keyword.put(render_opts, :mode, :working))

    if "thought" in current_ids and
         ("thought" not in Map.get(checkpoint, "element_ids", []) or
            not is_binary(checkpoint["cleanup_at"])) do
      deadline = checkpoint["stream_deadline_at"] || stream_deadline()

      staged_checkpoint =
        checkpoint
        |> update_active_card(fn card ->
          Map.put(
            card,
            "element_ids",
            (Map.get(card, "element_ids", []) ++ ["thought"]) |> Enum.uniq()
          )
        end)
        |> Map.put("stream_deadline_at", deadline)
        |> Map.put("cleanup_at", deadline)

      with {:ok, _event} <- Actors.put_reply_preview_checkpoint(event.id, staged_checkpoint) do
        {:ok, staged_checkpoint}
      end
    else
      {:ok, checkpoint}
    end
  end

  defp ensure_card_sent(event, checkpoint, client, request_fun) do
    case CardChain.active_card(checkpoint) do
      %{"message_id" => message_id} when is_binary(message_id) and message_id != "" ->
        with {:ok, checkpoint} <- complete_sent_rollover(event, checkpoint) do
          {:ok, checkpoint, %{created_source_entry_id: message_id}}
        end

      _unsent ->
        with {:ok, checkpoint, result} <-
               send_active_card(event, checkpoint, client, request_fun),
             {:ok, checkpoint} <- complete_sent_rollover(event, checkpoint) do
          {:ok, checkpoint, result}
        end
    end
  end

  defp complete_sent_rollover(event, checkpoint) do
    active = CardChain.active_card(checkpoint)
    rollover = checkpoint["pending_rollover"]

    if is_map(rollover) and rollover["phase"] == "send" and
         rollover["to_index"] == active["index"] and is_binary(active["message_id"]) do
      checkpoint = Map.delete(checkpoint, "pending_rollover")

      with {:ok, _event} <- Actors.put_reply_preview_checkpoint(event.id, checkpoint) do
        {:ok, checkpoint}
      end
    else
      {:ok, checkpoint}
    end
  end

  defp send_active_card(event, checkpoint, client, request_fun) do
    active_index = CardChain.active_index(checkpoint)

    with operation_result <-
           if(active_index == 0,
             do: Outbox.outbox_operation_for_actor_event(event),
             else: {:ok, :post}
           ),
         {:ok, operation} <- operation_result,
         {:ok, result} <-
           send_card_reference_with_retry(
             client,
             event,
             checkpoint,
             operation,
             request_fun,
             @card_id_retry_delays_ms,
             &Process.sleep/1
           ),
         message_id when is_binary(message_id) <- result[:created_source_entry_id],
         checkpoint <-
           update_active_card(checkpoint, fn card -> Map.put(card, "message_id", message_id) end),
         {:ok, _event} <- Actors.put_reply_preview_checkpoint(event.id, checkpoint),
         :ok <- maybe_record_first_source_entry(event.id, active_index, message_id) do
      {:ok, checkpoint, result}
    else
      nil -> {:error, :cardkit_message_id_missing}
      {:error, _reason} = error -> error
    end
  end

  defp maybe_record_first_source_entry(actor_event_id, 0, message_id),
    do: Actors.record_reply_preview_source_entry(actor_event_id, message_id)

  defp maybe_record_first_source_entry(_actor_event_id, _index, _message_id), do: :ok

  defp ensure_page_chain(
         event,
         checkpoint,
         request,
         durable_presentation,
         pages,
         client,
         request_fun
       ) do
    checkpoint = CardChain.sync_active(checkpoint)

    with :ok <- validate_page_count(checkpoint, pages),
         :ok <- validate_sealed_prefix(checkpoint, request.presentation["answer"] || "") do
      if length(CardChain.cards(checkpoint)) >= length(pages) do
        {:ok, checkpoint, %{}}
      else
        with {:ok, checkpoint} <-
               seal_active_page(
                 event,
                 checkpoint,
                 request,
                 durable_presentation,
                 pages,
                 client,
                 request_fun
               ),
             {:ok, checkpoint} <-
               create_and_send_next_page(
                 event,
                 checkpoint,
                 request,
                 durable_presentation,
                 pages,
                 client,
                 request_fun
               ) do
          ensure_page_chain(
            event,
            checkpoint,
            request,
            durable_presentation,
            pages,
            client,
            request_fun
          )
        end
      end
    end
  end

  defp seal_active_page(
         event,
         checkpoint,
         request,
         durable_presentation,
         pages,
         client,
         request_fun
       ) do
    active = CardChain.active_card(checkpoint)

    if active["state"] in ["sealed", "closed"] do
      {:ok, checkpoint}
    else
      index = active["index"]
      page = CardChain.page_at(pages, index)
      count = length(pages)

      rollover = %{
        "from_index" => index,
        "to_index" => index + 1,
        "phase" => "seal",
        "answer_digest" => CardChain.digest(page.source)
      }

      staged = Map.put(checkpoint, "pending_rollover", rollover)

      previous =
        checkpoint["presentation"] || request.previous_presentation || ReplyPresentation.new()

      previous_opts = [
        answer: active["answer_content"] || " ",
        page_index: index,
        page_count: count,
        page_tail: true
      ]

      current_opts = CardChain.page_opts(page, index, count, false)

      with {:ok, _event} <- Actors.put_reply_preview_checkpoint(event.id, staged),
           {:ok, actions} <-
             Renderer.batch_actions(previous, request.presentation,
               mode: :working,
               previous: previous_opts,
               current: current_opts
             ),
           :ok <-
             apply_batch_mutation(
               event,
               active["card_id"],
               actions ++ [streaming_setting_action(false, request.presentation)],
               "seal_page:#{index}",
               client,
               request_fun
             ),
           element_ids <-
             Renderer.element_ids(
               request.presentation,
               Keyword.put(current_opts, :mode, :working)
             ),
           checkpoint <-
             staged
             |> CardChain.update_card(index, fn card ->
               card
               |> put_acknowledged_page(page, page.content)
               |> Map.put("state", "sealed")
               |> Map.put("streaming_state", "closed")
               |> Map.put("element_ids", element_ids)
             end)
             |> Map.put("presentation", ReplyPresentation.checkpoint(durable_presentation))
             |> put_in(["pending_rollover", "phase"], "create")
             |> Map.delete("pending_mutation")
             |> Map.delete("cleanup_at")
             |> Map.put("stream_deadline_at", nil),
           {:ok, _event} <- Actors.put_reply_preview_checkpoint(event.id, checkpoint) do
        {:ok, checkpoint}
      end
    end
  end

  defp create_and_send_next_page(
         event,
         checkpoint,
         request,
         durable_presentation,
         pages,
         client,
         request_fun
       ) do
    next_index = length(CardChain.cards(checkpoint))
    page = CardChain.page_at(pages, next_index)
    count = length(pages)
    tail? = next_index == count - 1
    stream_open? = request.mode != :terminal and tail?
    state = if(stream_open?, do: "open", else: if(tail?, do: "closed", else: "sealed"))
    render_opts = CardChain.page_opts(page, next_index, count, tail?)

    rollover = %{
      "from_index" => max(next_index - 1, 0),
      "to_index" => next_index,
      "phase" => "create",
      "answer_digest" => CardChain.digest(page.source),
      "message_uuid" => card_message_uuid(event.id, next_index)
    }

    staged = Map.put(checkpoint, "pending_rollover", rollover)

    with {:ok, _event} <- Actors.put_reply_preview_checkpoint(event.id, staged),
         {:ok, card_json} <-
           Renderer.render(request.presentation, Keyword.put(render_opts, :mode, request.mode)),
         {:ok, card_id} <- create_card(client, card_json, request_fun),
         element_ids <-
           Renderer.element_ids(
             request.presentation,
             Keyword.put(render_opts, :mode, request.mode)
           ),
         card <-
           CardChain.card_record(
             next_index,
             card_id,
             rollover["message_uuid"],
             page,
             state,
             element_ids
           ),
         checkpoint <-
           staged
           |> CardChain.append(card)
           |> Map.put("presentation", ReplyPresentation.checkpoint(durable_presentation))
           |> Map.put("pending_rollover", Map.put(rollover, "phase", "send"))
           |> then(fn checkpoint ->
             if stream_open? do
               deadline = stream_deadline()

               checkpoint
               |> Map.put("stream_deadline_at", deadline)
               |> put_cleanup_at(element_ids, deadline)
             else
               checkpoint
               |> Map.put("stream_deadline_at", nil)
               |> Map.delete("cleanup_at")
             end
           end),
         {:ok, _event} <- Actors.put_reply_preview_checkpoint(event.id, checkpoint),
         {:ok, checkpoint, _result} <-
           ensure_card_sent(event, checkpoint, client, request_fun),
         checkpoint <- Map.delete(checkpoint, "pending_rollover"),
         {:ok, _event} <- Actors.put_reply_preview_checkpoint(event.id, checkpoint) do
      {:ok, checkpoint}
    end
  end

  defp validate_sealed_prefix(checkpoint, answer) do
    prefix = CardChain.sealed_prefix(checkpoint)

    if prefix == "" or String.starts_with?(answer, prefix),
      do: :ok,
      else: {:error, :cardkit_answer_rewrite_after_rollover}
  end

  defp validate_page_count(checkpoint, pages) do
    if length(CardChain.cards(checkpoint)) <= length(pages),
      do: :ok,
      else: {:error, :cardkit_answer_rewrite_after_rollover}
  end

  defp active_render_context(pages, checkpoint) do
    index = CardChain.active_index(checkpoint)
    page = CardChain.page_at(pages, index)
    {page, CardChain.page_opts(page, index, length(pages), true)}
  end

  defp update_active_card(checkpoint, fun) when is_function(fun, 1) do
    CardChain.update_card(checkpoint, CardChain.active_index(checkpoint), fun)
  end

  defp first_message_id(checkpoint) do
    checkpoint
    |> CardChain.cards()
    |> Enum.find_value(fn card ->
      case card["message_id"] do
        message_id when is_binary(message_id) and message_id != "" -> message_id
        _missing -> nil
      end
    end)
  end

  defp send_card_reference_with_retry(
         client,
         event,
         checkpoint,
         operation,
         request_fun,
         retry_delays,
         sleep_fun
       ) do
    case send_card_reference(client, event, checkpoint, operation, request_fun) do
      {:error, %Error{} = error} = result ->
        case {invalid_card_id_visibility_error?(error), retry_delays} do
          {true, [delay_ms | remaining]} ->
            sleep_fun.(delay_ms)

            send_card_reference_with_retry(
              client,
              event,
              checkpoint,
              operation,
              request_fun,
              remaining,
              sleep_fun
            )

          _not_retryable ->
            result
        end

      result ->
        result
    end
  end

  defp create_card(client, card, request_fun) do
    case cardkit_request(
           client,
           :post,
           "cardkit/v1/cards",
           [body: %{type: "card_json", data: Ankole.JSON.encode!(card)}],
           request_fun
         ) do
      {:ok, %{"data" => %{"card_id" => card_id}}}
      when is_binary(card_id) and card_id != "" ->
        {:ok, card_id}

      {:ok, _body} ->
        {:error, :cardkit_card_id_missing}

      {:error, _reason} = error ->
        error
    end
  end

  defp send_card_reference(client, event, checkpoint, operation, request_fun),
    do: send_message(client, event, operation, card_message_body(checkpoint), request_fun)

  defp card_message_body(checkpoint) do
    %{
      msg_type: "interactive",
      content: Ankole.JSON.encode!(%{type: "card", data: %{card_id: checkpoint["card_id"]}}),
      uuid: checkpoint["message_uuid"]
    }
  end

  defp normalize_message_result(%{"data" => data} = body, operation) when is_map(data) do
    case data["message_id"] do
      message_id when is_binary(message_id) and message_id != "" ->
        {:ok,
         %{
           created_source_entry_id: message_id,
           provider_thread_id: data["root_id"],
           delivered_operation: operation,
           raw_payload: body
         }
         |> Enum.reject(fn {_key, value} -> is_nil(value) end)
         |> Map.new()}

      _message_id ->
        {:error, :cardkit_message_id_missing}
    end
  end

  defp normalize_message_result(_body, _operation), do: {:error, :cardkit_message_id_missing}

  defp put_reply_target({:ok, result}, source_entry_id),
    do: {:ok, Map.put(result, :reply_to_source_entry_id, source_entry_id)}

  defp put_reply_target(result, _source_entry_id), do: result

  defp update_mutations(request, checkpoint, render_opts) do
    previous =
      checkpoint["presentation"] || request.previous_presentation || ReplyPresentation.new()

    previous_opts = Keyword.put(render_opts, :answer, checkpoint["answer_content"] || " ")

    with {:ok, actions} <-
           Renderer.batch_actions(previous, request.presentation,
             mode: :working,
             previous: previous_opts,
             current: render_opts
           ) do
      answer_content =
        if prefix_answer_growth?(checkpoint, request.presentation, render_opts) do
          Renderer.answer_content(
            request.presentation,
            Keyword.put(render_opts, :mode, :working)
          )
        end

      actions = if answer_content, do: remove_answer_update(actions), else: actions

      actions =
        merge_stale_element_deletes(
          actions,
          checkpoint,
          request.presentation,
          :working,
          render_opts
        )

      streaming_state = working_streaming_state(checkpoint, request.presentation, render_opts)

      actions =
        case {checkpoint["streaming_state"], streaming_state} do
          {"open", "closed"} ->
            actions ++ [streaming_setting_action(false, request.presentation)]

          _unchanged ->
            actions
        end

      {:ok, answer_content, actions, streaming_state}
    end
  end

  defp prefix_answer_growth?(checkpoint, current, render_opts) do
    previous_answer = checkpoint["answer_content"] || ""
    current_answer = Renderer.answer_content(current, Keyword.put(render_opts, :mode, :working))

    is_binary(previous_answer) and is_binary(current_answer) and current_answer != "" and
      current_answer != previous_answer and String.starts_with?(current_answer, previous_answer)
  end

  defp remove_answer_update(actions) do
    Enum.reject(actions, fn action ->
      action["action"] == "update_element" and
        get_in(action, ["params", "element_id"]) == "answer"
    end)
  end

  defp terminal_actions(request, checkpoint, render_opts) do
    previous =
      checkpoint["presentation"] || request.previous_presentation || ReplyPresentation.new()

    previous_opts = Keyword.put(render_opts, :answer, checkpoint["answer_content"] || " ")

    with {:ok, actions} <-
           Renderer.batch_actions(previous, request.presentation,
             mode: :terminal,
             previous: previous_opts,
             current: render_opts
           ) do
      actions =
        merge_stale_element_deletes(
          actions,
          checkpoint,
          request.presentation,
          :terminal,
          render_opts
        )

      {:ok, actions}
    end
  end

  defp refresh_request(request, event, checkpoint) do
    presentation = ReplyPresentation.normalize(checkpoint["presentation"] || request.presentation)

    %{
      request
      | actor_event: event,
        presentation: presentation,
        previous_presentation:
          checkpoint["previous_presentation"] || request.previous_presentation,
        checkpoint: checkpoint,
        mode:
          if(ReplyPresentation.terminal_state?(presentation), do: :terminal, else: request.mode)
    }
  end

  defp refresh_actions(request, checkpoint, render_opts) do
    previous = request.previous_presentation || ReplyPresentation.new()
    previous_opts = Keyword.put(render_opts, :answer, checkpoint["answer_content"] || " ")

    with {:ok, actions} <-
           Renderer.batch_actions(previous, request.presentation,
             mode: request.mode,
             previous_element_ids: checkpoint["element_ids"],
             previous: previous_opts,
             current: render_opts
           ) do
      actions =
        merge_stale_element_deletes(
          actions,
          checkpoint,
          request.presentation,
          request.mode,
          render_opts
        )

      close_streaming? =
        request.mode == :terminal or checkpoint["refresh_reason"] == "thought_cleanup"

      actions =
        if close_streaming? do
          actions ++ [streaming_setting_action(false, request.presentation)]
        else
          actions
        end

      {:ok, actions, close_streaming?}
    end
  end

  defp apply_refresh_actions(_event, _card_id, [], _client, _request_fun), do: :ok

  defp apply_refresh_actions(event, card_id, actions, client, request_fun) do
    apply_batch_mutation(event, card_id, actions, "refresh", client, request_fun)
  end

  defp apply_batch_mutation(event, card_id, actions, purpose, client, request_fun) do
    {delete_actions, critical_actions} =
      Enum.split_with(actions, &(&1["action"] == "delete_elements"))

    delete_ids =
      delete_actions
      |> Enum.flat_map(&(get_in(&1, ["params", "element_ids"]) || []))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.sort()

    with :ok <-
           apply_delete_mutation(event, card_id, delete_ids, purpose, client, request_fun),
         :ok <-
           apply_batch_mutation_raw(
             event,
             card_id,
             critical_actions,
             purpose,
             client,
             request_fun
           ) do
      :ok
    end
  end

  defp apply_delete_mutation(_event, _card_id, [], _purpose, _client, _request_fun), do: :ok

  defp apply_delete_mutation(event, card_id, element_ids, purpose, client, request_fun) do
    action = delete_elements_action(element_ids)

    case apply_batch_mutation_raw(
           event,
           card_id,
           [action],
           "#{purpose}:cleanup",
           client,
           request_fun
         ) do
      :ok ->
        :ok

      {:error, %Error{code: 300_314}} ->
        Enum.reduce_while(element_ids, :ok, fn element_id, :ok ->
          case apply_batch_mutation_raw(
                 event,
                 card_id,
                 [delete_elements_action([element_id])],
                 "#{purpose}:cleanup:#{element_id}",
                 client,
                 request_fun
               ) do
            :ok -> {:cont, :ok}
            {:error, %Error{code: 300_314}} -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end
        end)

      {:error, _reason} = error ->
        error
    end
  end

  defp delete_elements_action(element_ids) do
    %{"action" => "delete_elements", "params" => %{"element_ids" => element_ids}}
  end

  defp apply_batch_mutation_raw(
         _event,
         _card_id,
         [],
         _purpose,
         _client,
         _request_fun
       ),
       do: :ok

  defp apply_batch_mutation_raw(event, card_id, actions, purpose, client, request_fun) do
    actions_json = Ankole.JSON.encode!(actions)
    actions_digest = :crypto.hash(:sha256, actions_json) |> Base.encode16(case: :lower)

    with {:ok, %{"sequence" => sequence, "uuid" => uuid} = mutation} <-
           Actors.prepare_reply_preview_mutation(
             event.id,
             purpose,
             actions_digest,
             Ecto.UUID.generate()
           ) do
      client
      |> batch_update_json(card_id, actions_json, sequence, uuid, request_fun)
      |> acknowledge_replayed_mutation(mutation)
    end
  end

  defp apply_content_mutation(event, card_id, content, client, request_fun) do
    content_digest = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    with {:ok, %{"sequence" => sequence, "uuid" => uuid} = mutation} <-
           Actors.prepare_reply_preview_mutation(
             event.id,
             "answer_content",
             content_digest,
             Ecto.UUID.generate()
           ) do
      cardkit_request(
        client,
        :put,
        "cardkit/v1/cards/:card_id/elements/:element_id/content",
        [
          path_params: %{card_id: card_id, element_id: "answer"},
          body: %{content: content, sequence: sequence, uuid: uuid}
        ],
        request_fun
      )
      |> case do
        {:ok, _body} -> :ok
        {:error, _reason} = error -> error
      end
      |> acknowledge_replayed_mutation(mutation)
    end
  end

  # A process may die after Feishu commits a mutation but before PostgreSQL
  # records the acknowledgement. UUID conflict proves that exact persisted
  # mutation was consumed. A sequence conflict is equally conclusive only while
  # the replayed sequence is still our single-writer high-water mark.
  defp acknowledge_replayed_mutation(
         {:error, %Error{code: 200_770}},
         %{"reused" => true}
       ),
       do: :ok

  defp acknowledge_replayed_mutation(
         {:error, %Error{code: 300_317}},
         %{"reused" => true, "sequence_current" => true}
       ),
       do: :ok

  defp acknowledge_replayed_mutation(result, _mutation), do: result

  defp merge_stale_element_deletes(actions, checkpoint, presentation, mode, render_opts) do
    current_ids =
      presentation
      |> Renderer.element_ids(Keyword.put(render_opts, :mode, mode))
      |> MapSet.new()

    stale_ids =
      checkpoint
      |> Map.get("element_ids", [])
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()
      |> MapSet.difference(current_ids)
      |> MapSet.to_list()

    merge_delete_action(actions, stale_ids)
  end

  defp merge_delete_action(actions, []), do: actions

  defp merge_delete_action(actions, stale_ids) do
    {delete_actions, other_actions} =
      Enum.split_with(actions, &(&1["action"] == "delete_elements"))

    deleted_ids =
      delete_actions
      |> Enum.flat_map(&(get_in(&1, ["params", "element_ids"]) || []))
      |> Kernel.++(stale_ids)
      |> Enum.uniq()
      |> Enum.sort()

    [
      %{"action" => "delete_elements", "params" => %{"element_ids" => deleted_ids}}
      | other_actions
    ]
  end

  defp batch_update_json(client, card_id, actions_json, sequence, uuid, request_fun) do
    case cardkit_request(
           client,
           :post,
           "cardkit/v1/cards/:card_id/batch_update",
           [
             path_params: %{card_id: card_id},
             body: %{
               actions: actions_json,
               sequence: sequence,
               uuid: uuid
             }
           ],
           request_fun
         ) do
      {:ok, _body} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp cardkit_request(client, method, path, opts, request_fun) do
    with :ok <- WriteLimiter.wait(client.app_id) do
      request_fun.(client, method, path, opts)
    end
  end

  defp streaming_setting_action(streaming?, presentation) do
    %{
      "action" => "partial_update_setting",
      "params" => %{
        "settings" => %{
          "config" => %{
            "streaming_mode" => streaming?,
            "summary" => %{"content" => summary(presentation)}
          }
        }
      }
    }
  end

  defp persist_acknowledged_checkpoint(
         event,
         checkpoint,
         presentation,
         "open",
         render_opts,
         active_page
       ) do
    element_ids = Renderer.element_ids(presentation, Keyword.put(render_opts, :mode, :working))

    answer_content =
      Renderer.answer_content(presentation, Keyword.put(render_opts, :mode, :working))

    stream_deadline_at = stream_deadline()

    checkpoint =
      checkpoint
      |> Map.put("presentation", ReplyPresentation.checkpoint(presentation))
      |> update_active_card(fn card ->
        card
        |> put_acknowledged_page(active_page, answer_content)
        |> Map.put("element_ids", element_ids)
        |> Map.put("state", "open")
        |> Map.put("streaming_state", "open")
      end)
      |> Map.put("stream_deadline_at", stream_deadline_at)
      |> Map.delete("refresh_pending")
      |> Map.delete("refresh_reason")
      |> Map.delete("previous_presentation")
      |> Map.delete("pending_mutation")
      |> put_cleanup_at(element_ids, stream_deadline_at)

    with {:ok, _event} <- Actors.put_reply_preview_checkpoint(event.id, checkpoint) do
      {:ok, checkpoint}
    end
  end

  defp persist_acknowledged_checkpoint(
         event,
         checkpoint,
         presentation,
         "closed",
         render_opts,
         active_page
       ) do
    element_ids = Renderer.element_ids(presentation, Keyword.put(render_opts, :mode, :working))

    answer_content =
      Renderer.answer_content(presentation, Keyword.put(render_opts, :mode, :working))

    checkpoint =
      checkpoint
      |> Map.put("presentation", ReplyPresentation.checkpoint(presentation))
      |> update_active_card(fn card ->
        card
        |> put_acknowledged_page(active_page, answer_content)
        |> Map.put("element_ids", element_ids)
        |> Map.put("state", "closed")
        |> Map.put("streaming_state", "closed")
      end)
      |> Map.put("stream_deadline_at", nil)
      |> Map.delete("cleanup_at")
      |> Map.delete("refresh_pending")
      |> Map.delete("refresh_reason")
      |> Map.delete("previous_presentation")
      |> Map.delete("pending_mutation")

    with {:ok, _event} <- Actors.put_reply_preview_checkpoint(event.id, checkpoint) do
      {:ok, checkpoint}
    end
  end

  defp working_streaming_state(checkpoint, presentation, render_opts) do
    if thought_cleanup_due?(checkpoint, presentation, render_opts), do: "closed", else: "open"
  end

  defp thought_cleanup_due?(%{"cleanup_at" => cleanup_at}, presentation, render_opts)
       when is_binary(cleanup_at) do
    no_visible_thought? =
      "thought" not in Renderer.element_ids(
        presentation,
        Keyword.put(render_opts, :mode, :working)
      )

    case DateTime.from_iso8601(cleanup_at) do
      {:ok, deadline, _offset} ->
        no_visible_thought? and
          DateTime.compare(deadline, DateTime.utc_now(:microsecond)) in [:lt, :eq]

      {:error, _reason} ->
        false
    end
  end

  defp thought_cleanup_due?(_checkpoint, _presentation, _render_opts), do: false

  defp persist_acknowledged_answer_content(event, checkpoint, answer_content) do
    checkpoint =
      checkpoint
      |> update_active_card(&Map.put(&1, "answer_content", answer_content))
      |> Map.delete("pending_mutation")

    with {:ok, _event} <- Actors.put_reply_preview_checkpoint(event.id, checkpoint) do
      {:ok, checkpoint}
    end
  end

  defp terminal_checkpoint(checkpoint, presentation, render_opts, active_page) do
    answer_content =
      Renderer.answer_content(presentation, Keyword.put(render_opts, :mode, :terminal))

    element_ids = Renderer.element_ids(presentation, Keyword.put(render_opts, :mode, :terminal))

    checkpoint
    |> Map.put("presentation", ReplyPresentation.checkpoint(presentation))
    |> update_active_card(fn card ->
      card
      |> put_acknowledged_page(active_page, answer_content)
      |> Map.put("element_ids", element_ids)
      |> Map.put("state", "closed")
      |> Map.put("streaming_state", "closed")
    end)
    |> Map.put("stream_deadline_at", nil)
    |> Map.delete("cleanup_at")
    |> Map.delete("refresh_pending")
    |> Map.delete("refresh_reason")
    |> Map.delete("previous_presentation")
    |> Map.delete("pending_mutation")
    |> Map.put("closed_at", DateTime.utc_now(:microsecond) |> DateTime.to_iso8601())
  end

  defp terminal_checkpoint_matches?(checkpoint, presentation) do
    checkpoint_presentation = ReplyPresentation.normalize(checkpoint["presentation"])

    ReplyPresentation.terminal_state?(checkpoint_presentation) and
      ReplyPresentation.checkpoint(checkpoint_presentation) ==
        ReplyPresentation.checkpoint(presentation)
  end

  defp refreshed_checkpoint(
         checkpoint,
         presentation,
         close_streaming?,
         render_opts,
         active_page
       ) do
    mode = if ReplyPresentation.terminal_state?(presentation), do: :terminal, else: :working
    element_ids = Renderer.element_ids(presentation, Keyword.put(render_opts, :mode, mode))
    answer_content = Renderer.answer_content(presentation, Keyword.put(render_opts, :mode, mode))

    checkpoint
    |> Map.put("presentation", ReplyPresentation.checkpoint(presentation))
    |> update_active_card(fn card ->
      card
      |> put_acknowledged_page(active_page, answer_content)
      |> Map.put("element_ids", element_ids)
    end)
    |> Map.delete("refresh_pending")
    |> Map.delete("refresh_reason")
    |> Map.delete("previous_presentation")
    |> Map.delete("pending_mutation")
    |> Map.delete("cleanup_at")
    |> then(fn checkpoint ->
      if close_streaming? do
        checkpoint
        |> update_active_card(fn card ->
          card
          |> Map.put("state", "closed")
          |> Map.put("streaming_state", "closed")
        end)
        |> Map.put("stream_deadline_at", nil)
      else
        checkpoint
      end
    end)
  end

  defp put_acknowledged_page(card, page, answer_content) do
    card
    |> Map.put("answer_start_byte", page.start_byte)
    |> Map.put("answer_end_byte", page.end_byte)
    |> Map.put("answer_source", page.source)
    |> Map.put("answer_digest", CardChain.digest(page.source))
    |> Map.put("answer_content", answer_content)
  end

  defp put_cleanup_at(checkpoint, element_ids, deadline) do
    if "thought" in element_ids and is_binary(deadline) do
      Map.put(checkpoint, "cleanup_at", deadline)
    else
      Map.delete(checkpoint, "cleanup_at")
    end
  end

  defp plain_text_fallback(event, %Request{outbox: %OutboxEntry{} = outbox} = request) do
    with {:ok, config} <- config_for_event(event),
         client <- Config.client(config),
         request_fun <- &FeishuOpenAPI.request/4,
         {:ok, operation} <- Outbox.outbox_operation_for_actor_event(event),
         text <- ReplyPresentation.fallback_text(request.presentation),
         {operation, text} <- undelivered_plain_text(event, operation, text),
         {:ok, result} <-
           send_plain_text_chunks(
             client,
             event,
             operation,
             text,
             outbox.idempotency_key || "ai-reply:#{event.id}",
             request_fun
           ) do
      {:ok, Map.put(result, :delivered_operation, result[:delivered_operation] || operation)}
    end
  end

  defp plain_text_fallback(_event, _request),
    do: {:error, :cardkit_plain_text_fallback_requires_outbox}

  defp undelivered_plain_text(%ActorEvent{id: actor_event_id}, operation, text) do
    checkpoint =
      case Repo.get(ActorEvent, actor_event_id) do
        %ActorEvent{reply_preview_checkpoint: checkpoint} when is_map(checkpoint) -> checkpoint
        _missing -> %{}
      end

    active = CardChain.active_card(checkpoint)
    rollover = checkpoint["pending_rollover"]
    sealed_prefix = CardChain.sealed_prefix(checkpoint)

    if is_map(active) and not is_binary(active["message_id"]) and
         is_map(rollover) and rollover["phase"] == "send" and sealed_prefix != "" and
         String.starts_with?(text, sealed_prefix) do
      remaining =
        binary_part(text, byte_size(sealed_prefix), byte_size(text) - byte_size(sealed_prefix))

      if remaining == "", do: {operation, text}, else: {:post, remaining}
    else
      {operation, text}
    end
  end

  defp send_plain_text_chunks(client, event, operation, text, idempotency_key, request_fun) do
    text
    |> LarkOutbox.split_text()
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {chunk, index}, {:ok, results} ->
      checkpoint = %{
        "message_uuid" =>
          idempotency_key
          |> LarkOutbox.chunk_idempotency_key(index)
          |> LarkOutbox.provider_message_uuid()
      }

      chunk_operation = if index == 1, do: operation, else: :post

      case send_plain_text(client, event, checkpoint, chunk_operation, chunk, request_fun) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, results |> Enum.reverse() |> combine_plain_text_results()}
      {:error, _reason} = error -> error
    end
  end

  defp send_plain_text(client, event, checkpoint, operation, text, request_fun),
    do: send_message(client, event, operation, text_message_body(checkpoint, text), request_fun)

  defp send_message(client, event, :reply, body, request_fun) do
    case request_fun.(client, :post, "im/v1/messages/:message_id/reply",
           path_params: %{message_id: event.source_entry_id},
           body: Map.put(body, :reply_in_thread, false)
         ) do
      {:ok, response} ->
        response
        |> normalize_message_result(:reply)
        |> put_reply_target(event.source_entry_id)

      {:error, %Error{} = error} ->
        if LarkOutbox.target_gone_error?(error) do
          send_message(client, event, :post, body, request_fun)
        else
          {:error, error}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp send_message(client, event, _operation, body, request_fun) do
    request_fun.(client, :post, "im/v1/messages",
      query: [receive_id_type: "chat_id"],
      body: Map.put(body, :receive_id, chat_id(event.signal_channel_id))
    )
    |> case do
      {:ok, response} -> normalize_message_result(response, :post)
      {:error, _reason} = error -> error
    end
  end

  defp text_message_body(checkpoint, text) do
    %{
      msg_type: "text",
      content: Ankole.JSON.encode!(%{text: text}),
      uuid: checkpoint["message_uuid"]
    }
  end

  defp combine_plain_text_results([result]), do: result

  defp combine_plain_text_results([first | _rest] = results) do
    Map.put(first, :raw_payload, %{
      "split" => true,
      "chunks" => Enum.map(results, & &1[:raw_payload])
    })
  end

  defp delivery_result(message_id, checkpoint) do
    %{
      created_source_entry_id: message_id,
      reply_preview_checkpoint: checkpoint,
      recovery_state: %{
        "card_id" => checkpoint["card_id"],
        "message_id" => checkpoint["message_id"],
        "streaming_state" => checkpoint["streaming_state"],
        "active_card_index" => checkpoint["active_card_index"],
        "cards" => CardChain.cards(checkpoint)
      }
    }
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

  defp invalid_card_id_visibility_error?(%Error{code: 230_099, msg: message})
       when is_binary(message) do
    message
    |> String.downcase()
    |> String.contains?("cardid is invalid")
  end

  defp invalid_card_id_visibility_error?(_error), do: false

  defp summary(presentation) do
    presentation
    |> ReplyPresentation.fallback_text()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, 80)
  end

  defp stream_deadline do
    DateTime.utc_now(:microsecond)
    |> DateTime.add(@stream_lease_seconds, :second)
    |> DateTime.to_iso8601()
  end

  defp card_message_uuid(actor_event_id, index) do
    actor_event_id
    |> then(&"cardkit-message:#{&1}:#{index}")
    |> LarkOutbox.provider_message_uuid()
  end

  defp chat_id("lark:" <> encoded), do: URI.decode(encoded)
  defp chat_id(value), do: value

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: 0

  defp normalize_lifecycle_result({:error, %Error{} = error}) do
    case ErrorPolicy.action(error) do
      :plain_text_fallback ->
        {:error, {:cardkit_plain_text_fallback, ErrorPolicy.provider_error(error)}}

      :operator_action_required ->
        {:error, {:reply_delivery, :operator_action_required, ErrorPolicy.provider_error(error)}}

      _retry ->
        {:error, {:reply_delivery, :retryable, ErrorPolicy.provider_error(error)}}
    end
  end

  defp normalize_lifecycle_result(result), do: result
end
