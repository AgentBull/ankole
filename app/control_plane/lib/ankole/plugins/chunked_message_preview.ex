defmodule Ankole.Plugins.ChunkedMessagePreview do
  @moduledoc """
  Owns the durable message ledger for chunked reply previews.

  A provider callback changes one message. This module then checkpoints that
  change before it starts the next provider operation. A retry can therefore
  continue from the last confirmed message without creating an untracked
  chunk.
  """

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.ReplyInteractionState
  alias Ankole.SignalsGateway.ReplyPresentation
  alias Ankole.SignalsGateway.ReplyPreviewAdapter.Request

  @type provider_context :: term()
  @type provider_response :: term()
  @type message_record :: %{String.t() => term()}
  @type error_stage :: :render | :upsert | :checkpoint | :source_entry | :delete

  @callback render_chunks(ReplyPresentation.t(), Request.t()) ::
              {:ok, [term()], provider_context(), String.t() | nil} | {:error, term()}
  @callback upsert_message(
              provider_context(),
              ActorEvent.t(),
              message_record() | nil,
              term(),
              non_neg_integer()
            ) ::
              {:ok, message_record(), provider_response(), String.t() | nil} | {:error, term()}
  @callback delete_message(provider_context(), ActorEvent.t(), message_record()) ::
              :ok | {:error, term()}
  @callback classify_error(term(), error_stage(), boolean()) :: term()

  @spec reconcile(Request.t(), module(), String.t()) :: {:ok, map()} | {:error, term()}
  def reconcile(%Request{actor_event: %ActorEvent{}} = request, provider, adapter_id)
      when is_atom(provider) and is_binary(adapter_id) and adapter_id != "" do
    checkpoint = request.checkpoint || %{}

    presentation =
      request.presentation
      |> ReplyPresentation.normalize()
      |> ReplyInteractionState.project(checkpoint)

    case provider.render_chunks(presentation, request) do
      {:ok, [_ | _] = chunks, context, default_thread_id} ->
        reconcile_chunks(
          request,
          provider,
          adapter_id,
          context,
          default_thread_id,
          checkpoint,
          presentation,
          chunks
        )

      {:ok, [], _context, _default_thread_id} ->
        failure(provider, :empty_reply_preview_chunks, :render, false)

      {:error, reason} ->
        failure(provider, reason, :render, false)

      invalid ->
        failure(provider, {:invalid_chunk_renderer_result, invalid}, :render, false)
    end
  end

  def reconcile(_request, _provider, _adapter_id),
    do: {:error, :invalid_chunked_message_preview_request}

  @spec surface_ids(map()) :: [{:entry, String.t()}]
  def surface_ids(checkpoint) when is_map(checkpoint) do
    Enum.map(message_records(checkpoint), &{:entry, &1["message_id"]})
  end

  def surface_ids(_checkpoint), do: []

  @spec surface_open?(map()) :: boolean()
  def surface_open?(checkpoint) when is_map(checkpoint),
    do: checkpoint["streaming_state"] != "closed"

  def surface_open?(_checkpoint), do: false

  defp reconcile_chunks(
         request,
         provider,
         adapter_id,
         context,
         default_thread_id,
         checkpoint,
         presentation,
         chunks
       ) do
    existing = checkpoint |> message_records() |> Map.new(&{&1["index"], &1})

    with {:ok, records, responses, changed?, provider_thread_id} <-
           upsert_chunks(
             request,
             provider,
             adapter_id,
             context,
             default_thread_id,
             checkpoint,
             presentation,
             chunks,
             existing
           ),
         {:ok, records} <-
           delete_surplus(
             request,
             provider,
             adapter_id,
             context,
             checkpoint,
             presentation,
             length(chunks),
             records,
             existing,
             changed?
           ) do
      messages = records |> retained_records(length(chunks)) |> sorted_message_records()
      first_id = first_message_id(messages)
      checkpoint = build_checkpoint(checkpoint, messages, presentation, request, adapter_id)

      with :ok <-
             record_source_entry(
               provider,
               request.actor_event,
               first_id,
               provider_thread_id,
               changed?
             ) do
        {:ok,
         %{
           created_source_entry_id: first_id,
           provider_thread_id: provider_thread_id,
           reply_preview_checkpoint: checkpoint,
           raw_payload: %{"messages" => Enum.reverse(responses)},
           recovery_state: %{
             "message_id" => first_id,
             "messages" => messages,
             "streaming_state" => checkpoint["streaming_state"]
           }
         }
         |> maybe_put_payload(request.outbox)}
      end
    end
  end

  defp upsert_chunks(
         request,
         provider,
         adapter_id,
         context,
         default_thread_id,
         checkpoint,
         presentation,
         chunks,
         existing
       ) do
    chunks
    |> Enum.with_index()
    |> Enum.reduce_while(
      {:ok, existing, [], false, default_thread_id},
      fn {chunk, index}, {:ok, records, responses, changed?, provider_thread_id} ->
        current = Map.get(records, index)

        case provider.upsert_message(context, request.actor_event, current, chunk, index) do
          {:ok, %{"message_id" => message_id} = message, response, response_thread_id}
          when is_binary(message_id) and message_id != "" ->
            message = Map.put(message, "index", index)
            records = Map.put(records, index, message)
            provider_thread_id = provider_thread_id || response_thread_id

            case stage_checkpoint(
                   request,
                   provider,
                   adapter_id,
                   checkpoint,
                   records,
                   presentation,
                   provider_thread_id
                 ) do
              :ok ->
                {:cont, {:ok, records, [response | responses], true, provider_thread_id}}

              {:error, _reason} = error ->
                {:halt, error}
            end

          {:ok, invalid_message, _response, _response_thread_id} ->
            {:halt,
             failure(
               provider,
               {:invalid_message_record, invalid_message},
               :upsert,
               changed?
             )}

          {:error, reason} ->
            {:halt, failure(provider, reason, :upsert, changed?)}

          invalid ->
            {:halt,
             failure(provider, {:invalid_message_upsert_result, invalid}, :upsert, changed?)}
        end
      end
    )
  end

  defp stage_checkpoint(
         request,
         provider,
         adapter_id,
         checkpoint,
         records,
         presentation,
         provider_thread_id
       ) do
    staged =
      checkpoint
      |> build_checkpoint(sorted_message_records(records), presentation, request, adapter_id)

    case Actors.put_reply_preview_checkpoint(request.actor_event.id, staged) do
      {:ok, _event} ->
        case first_message_id(sorted_message_records(records)) do
          id when is_binary(id) ->
            record_source_entry(provider, request.actor_event, id, provider_thread_id, true)

          nil ->
            :ok
        end

      {:error, reason} ->
        failure(provider, reason, :checkpoint, true)
    end
  end

  defp delete_surplus(
         request,
         provider,
         adapter_id,
         context,
         checkpoint,
         presentation,
         retained_count,
         records,
         existing,
         changed?
       ) do
    existing
    |> Enum.filter(fn {index, _message} -> index >= retained_count end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, records}, fn {index, message}, {:ok, records} ->
      case provider.delete_message(context, request.actor_event, message) do
        :ok ->
          records = Map.delete(records, index)

          case stage_checkpoint(
                 request,
                 provider,
                 adapter_id,
                 checkpoint,
                 records,
                 presentation,
                 nil
               ) do
            :ok -> {:cont, {:ok, records}}
            {:error, _reason} = error -> {:halt, error}
          end

        {:error, reason} ->
          {:halt, failure(provider, reason, :delete, changed?)}

        invalid ->
          {:halt, failure(provider, {:invalid_message_delete_result, invalid}, :delete, changed?)}
      end
    end)
  end

  defp record_source_entry(provider, event, source_entry_id, provider_thread_id, changed?)
       when is_binary(source_entry_id) do
    case Actors.record_reply_preview_source_entry(
           event.id,
           source_entry_id,
           provider_thread_id
         ) do
      :ok -> :ok
      {:error, reason} -> failure(provider, reason, :source_entry, changed?)
    end
  end

  defp record_source_entry(_provider, _event, nil, _provider_thread_id, _changed?),
    do: :ok

  defp build_checkpoint(checkpoint, messages, presentation, request, adapter_id) do
    previous = checkpoint["presentation"]
    terminal? = request.mode == :terminal or ReplyPresentation.terminal_state?(presentation)

    checkpoint
    |> Map.merge(%{
      "schema_version" => 1,
      "adapter" => adapter_id,
      "subject_uid" => request.subject_uid || checkpoint["subject_uid"],
      "conversation_id" => request.conversation_id || checkpoint["conversation_id"],
      "message_id" => first_message_id(messages),
      "messages" => messages,
      "presentation" => ReplyPresentation.checkpoint(presentation),
      "streaming_state" => if(terminal?, do: "closed", else: "open")
    })
    |> put_previous_presentation(previous, presentation)
    |> Map.delete("refresh_pending")
    |> Map.delete("refresh_reason")
    |> Map.delete("recovery_state")
  end

  defp put_previous_presentation(checkpoint, previous, presentation) when is_map(previous) do
    if ReplyPresentation.normalize(previous) == ReplyPresentation.normalize(presentation) do
      Map.delete(checkpoint, "previous_presentation")
    else
      Map.put(checkpoint, "previous_presentation", ReplyPresentation.checkpoint(previous))
    end
  end

  defp put_previous_presentation(checkpoint, _previous, _presentation),
    do: Map.delete(checkpoint, "previous_presentation")

  defp message_records(%{"messages" => messages}) when is_list(messages) do
    messages
    |> Enum.filter(fn
      %{"index" => index, "message_id" => message_id}
      when is_integer(index) and index >= 0 and is_binary(message_id) and message_id != "" ->
        true

      _invalid ->
        false
    end)
    |> Enum.sort_by(& &1["index"])
  end

  defp message_records(%{"message_id" => message_id})
       when is_binary(message_id) and message_id != "",
       do: [%{"index" => 0, "message_id" => message_id}]

  defp message_records(_checkpoint), do: []

  defp retained_records(records, retained_count) do
    Map.filter(records, fn {index, _message} -> index < retained_count end)
  end

  defp sorted_message_records(records) do
    records
    |> Map.values()
    |> Enum.sort_by(& &1["index"])
  end

  defp first_message_id([%{"message_id" => message_id} | _rest]), do: message_id
  defp first_message_id(_messages), do: nil

  defp maybe_put_payload(result, %{} = outbox), do: Map.put(result, :payload, outbox.payload)
  defp maybe_put_payload(result, _outbox), do: result

  defp failure(provider, reason, stage, changed?) do
    {:error, provider.classify_error(reason, stage, changed?)}
  end
end
