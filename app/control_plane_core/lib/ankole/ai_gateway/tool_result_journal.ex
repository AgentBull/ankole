defmodule Ankole.AIGateway.ToolResultJournal do
  @moduledoc "Validates, deduplicates and commits client tool outputs against their Response calls."
  import Ecto.Query

  import Ankole.AIGateway.ResponseChain,
    only: [previous_response_id: 1, decode_response_id: 1, complete_message_for_subject: 3]

  alias Ankole.AIGateway.Conversations
  alias Ankole.AIGateway.Events
  alias Ankole.AIGateway.ResponseItems
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Principals

  @doc """
  Records valid tool results as a completed message-log row without opening a
  provider run. Results that cannot be paired safely are retained in an error
  quarantine row and returned as a structured error.

  The conversation driver uses the transaction form to record a whole round,
  consume applied input, and delete its receipts in one commit. The returned
  row becomes the next `previous_response_id`.
  """
  @spec record_tool_results_in_tx(module(), map()) ::
          {:ok, Message.t(), :inserted | :existing} | {:error, term()}
  def record_tool_results_in_tx(repo, attrs) when is_map(attrs) do
    raw_subject_uid = Map.fetch!(attrs, :subject_uid)
    previous_response_id = previous_response_id(attrs)
    request_items = Map.get(attrs, :request_items, Map.get(attrs, "request_items", []))

    extra_metadata =
      attrs
      |> Map.take([:metadata, "metadata"])
      |> case do
        %{metadata: m} when is_map(m) -> m
        %{"metadata" => m} when is_map(m) -> m
        _ -> %{}
      end

    with {:ok, subject_uid} <- Principals.normalize_uid(raw_subject_uid),
         :ok <- validate_tool_result_items(request_items),
         {:ok, previous_message_id} <- decode_response_id(previous_response_id),
         %Message{status: "complete"} = anchor <-
           complete_message_for_subject(repo, subject_uid, previous_message_id) do
      case reconcile_tool_result_items(anchor, request_items) do
        {:ok, reconciled_items} ->
          idempotency_key =
            tool_result_idempotency_key(subject_uid, previous_message_id, reconciled_items)

          merged_metadata =
            extra_metadata
            |> Map.merge(request_items_metadata(reconciled_items))
            |> Map.merge(%{
              "tool_result_journal" => true,
              "tool_result_idempotency_key" => idempotency_key
            })

          insert_tool_result_journal(
            repo,
            anchor,
            reconciled_items,
            merged_metadata,
            idempotency_key
          )

        {:quarantine, reason, details} ->
          quarantine_tool_result_items(
            repo,
            anchor,
            request_items,
            extra_metadata,
            reason,
            details
          )
      end
    else
      {:error, :invalid_response_id} -> {:error, :invalid_anchor}
      {:error, :invalid_uid} -> {:error, :invalid_conversation}
      {:error, _reason} = error -> error
      _not_found_or_invalid -> {:error, :invalid_anchor}
    end
  end

  defp insert_tool_result_journal(
         repo,
         %Message{} = anchor,
         request_items,
         merged_metadata,
         idempotency_key
       ) do
    case fetch_tool_result_journal(repo, anchor.subject_uid, idempotency_key) do
      {:ok, %Message{} = message} ->
        {:ok, message, :existing}

      {:error, :invalid_anchor} ->
        do_insert_tool_result_journal(
          repo,
          anchor,
          request_items,
          merged_metadata,
          idempotency_key
        )
    end
  end

  defp do_insert_tool_result_journal(
         repo,
         %Message{} = anchor,
         request_items,
         merged_metadata,
         idempotency_key
       ) do
    changeset =
      %Message{}
      |> Message.changeset(%{
        subject_uid: anchor.subject_uid,
        conversation_id: anchor.conversation_id,
        type: "message",
        status: "complete",
        previous_message_id: anchor.id,
        content: request_items,
        metadata: merged_metadata
      })

    case repo.insert(changeset) do
      {:ok, %Message{} = message} ->
        :ok = Conversations.touch_conversation_in_tx(repo, anchor.conversation_id)
        {:ok, message, :inserted}

      {:error, %Ecto.Changeset{} = changeset} ->
        if unique_constraint_error?(
             changeset,
             "ai_gateway_messages_tool_result_journal_key_index"
           ) do
          case fetch_tool_result_journal(repo, anchor.subject_uid, idempotency_key) do
            {:ok, %Message{} = message} ->
              {:ok, message, :existing}

            {:error, _reason} = error ->
              error
          end
        else
          {:error, changeset}
        end
    end
  end

  defp fetch_tool_result_journal(repo, subject_uid, idempotency_key) do
    # PostgreSQL needs this literal predicate to use the journal's partial index.
    case repo.one(
           from(message in Message,
             where: message.subject_uid == ^subject_uid,
             where: fragment("? \\? 'tool_result_idempotency_key'", message.metadata),
             where:
               fragment(
                 "?->>'tool_result_idempotency_key'",
                 message.metadata
               ) == ^idempotency_key
           )
         ) do
      %Message{} = message -> {:ok, message}
      nil -> {:error, :invalid_anchor}
    end
  end

  defp reconcile_tool_result_items(%Message{} = anchor, request_items) do
    with {:ok, deduplicated_items} <- deduplicate_tool_result_items(request_items) do
      output_items = Enum.filter(deduplicated_items, &tool_call_output_item?/1)

      invalid_outputs = Enum.reject(output_items, &ResponseItems.valid_client_output?/1)
      valid_outputs = output_items -- invalid_outputs
      {anchor_calls, anchor_ledger} = tool_calls_by_pair(anchor.content)
      executable_pair_keys = executable_tool_call_pair_keys(anchor_calls, anchor_ledger)

      orphan_call_ids =
        valid_outputs
        |> Enum.reject(&Map.has_key?(anchor_calls, ResponseItems.pair_key(&1)))
        |> Enum.map(&Map.get(&1, "call_id"))
        |> Enum.uniq()

      non_executable_call_ids =
        valid_outputs
        |> Enum.filter(
          &(Map.has_key?(anchor_calls, ResponseItems.pair_key(&1)) and
              not MapSet.member?(executable_pair_keys, ResponseItems.pair_key(&1)))
        )
        |> Enum.map(&Map.get(&1, "call_id"))
        |> Enum.uniq()

      mismatched_output_types = mismatched_tool_result_types(valid_outputs, anchor_calls)
      mismatched_tool_names = mismatched_tool_result_names(valid_outputs, anchor_calls)

      cond do
        invalid_outputs != [] ->
          {:quarantine, "invalid_tool_call_output",
           %{"invalid_output_count" => length(invalid_outputs)}}

        orphan_call_ids != [] ->
          {:quarantine, "orphan_tool_call_output", %{"orphan_call_ids" => orphan_call_ids}}

        non_executable_call_ids != [] ->
          {:quarantine, "non_executable_tool_call_output",
           %{"non_executable_call_ids" => non_executable_call_ids}}

        mismatched_output_types != [] ->
          {:quarantine, "tool_call_output_type_mismatch",
           %{"type_mismatches" => mismatched_output_types}}

        mismatched_tool_names != [] ->
          {:quarantine, "tool_call_output_name_mismatch",
           %{"name_mismatches" => mismatched_tool_names}}

        true ->
          {:ok, deduplicated_items}
      end
    end
  end

  defp deduplicate_tool_result_items(request_items) do
    request_items
    |> Enum.reduce_while({[], %{}}, fn
      item, {acc, seen} ->
        if ResponseItems.valid_client_output?(item) do
          pair_key = ResponseItems.pair_key(item)

          case Map.fetch(seen, pair_key) do
            :error ->
              {:cont, {[item | acc], Map.put(seen, pair_key, item)}}

            {:ok, ^item} ->
              {:cont, {acc, seen}}

            {:ok, _different_item} ->
              {:halt,
               {:quarantine, "conflicting_duplicate_tool_call_output",
                %{"conflicting_call_ids" => [Map.get(item, "call_id")]}}}
          end
        else
          {:cont, {[item | acc], seen}}
        end
    end)
    |> case do
      {items, _seen} -> {:ok, Enum.reverse(items)}
      {:quarantine, reason, details} -> {:quarantine, reason, details}
    end
  end

  defp tool_calls_by_pair(items) when is_list(items) do
    Enum.reduce(items, {%{}, ResponseItems.new()}, fn item, {calls, ledger} = acc ->
      if ResponseItems.call_item?(item) do
        case ResponseItems.reduce_with_key(ledger, item) do
          {:ok, ledger, _disposition, pair_key} ->
            calls =
              if ResponseItems.client_call_item?(item),
                do: Map.put(calls, pair_key, item),
                else: calls

            {calls, ledger}

          {:error, _reason} ->
            acc
        end
      else
        acc
      end
    end)
  end

  defp tool_calls_by_pair(_items), do: {%{}, ResponseItems.new()}

  defp executable_tool_call_pair_keys(anchor_calls, anchor_ledger) do
    Enum.reduce(anchor_calls, MapSet.new(), fn
      {pair_key, call}, acc ->
        if ResponseItems.executable_in_ledger?(anchor_ledger, call) do
          MapSet.put(acc, pair_key)
        else
          acc
        end
    end)
  end

  defp mismatched_tool_result_types(output_items, anchor_calls) do
    Enum.flat_map(output_items, fn item ->
      call_id = Map.get(item, "call_id")
      call = Map.get(anchor_calls, ResponseItems.pair_key(item))
      expected = call && ResponseItems.client_expected_output_type(call["type"])
      received = Map.get(item, "type")

      if call && ResponseItems.validate_client_call_output(call, item) == {:error, :type_mismatch} do
        [%{"call_id" => call_id, "expected" => expected, "received" => received}]
      else
        []
      end
    end)
  end

  defp mismatched_tool_result_names(output_items, anchor_calls) do
    Enum.flat_map(output_items, fn item ->
      call_id = Map.get(item, "call_id")
      output_name = Map.get(item, "name")
      call = Map.get(anchor_calls, ResponseItems.pair_key(item))
      call_name = call && Map.get(call, "name")

      if call && ResponseItems.validate_client_call_output(call, item) == {:error, :name_mismatch} do
        [%{"call_id" => call_id, "expected" => call_name, "received" => output_name}]
      else
        []
      end
    end)
  end

  defp quarantine_tool_result_items(
         repo,
         anchor,
         request_items,
         extra_metadata,
         reason,
         details
       ) do
    idempotency_key =
      tool_result_idempotency_key(anchor.subject_uid, anchor.id, request_items)

    quarantine =
      details
      |> Map.put("reason", reason)
      |> Map.put("anchor_response_id", "resp_#{anchor.id}")

    metadata =
      extra_metadata
      |> Map.merge(request_items_metadata(request_items))
      |> Map.merge(%{
        "tool_result_idempotency_key" => idempotency_key,
        "tool_result_quarantine" => quarantine,
        "error" => %{
          "code" => "tool_results_quarantined",
          "reason" => reason,
          "details" => details
        }
      })

    case fetch_tool_result_journal(repo, anchor.subject_uid, idempotency_key) do
      {:ok, %Message{} = message} ->
        tool_results_quarantined_error(message, quarantine)

      {:error, :invalid_anchor} ->
        insert_tool_result_quarantine(
          repo,
          anchor,
          request_items,
          metadata,
          idempotency_key,
          quarantine
        )
    end
  end

  defp insert_tool_result_quarantine(
         repo,
         anchor,
         request_items,
         metadata,
         idempotency_key,
         quarantine
       ) do
    changeset =
      %Message{}
      |> Message.changeset(%{
        subject_uid: anchor.subject_uid,
        conversation_id: anchor.conversation_id,
        type: "message",
        status: "error",
        previous_message_id: anchor.id,
        content: request_items,
        metadata: metadata
      })

    case repo.insert(changeset) do
      {:ok, %Message{} = message} ->
        :ok = Conversations.touch_conversation_in_tx(repo, anchor.conversation_id)
        tool_results_quarantined_error(message, quarantine)

      {:error, %Ecto.Changeset{} = changeset} ->
        if unique_constraint_error?(
             changeset,
             "ai_gateway_messages_tool_result_journal_key_index"
           ) do
          case fetch_tool_result_journal(repo, anchor.subject_uid, idempotency_key) do
            {:ok, %Message{} = message} -> tool_results_quarantined_error(message, quarantine)
            {:error, _reason} = error -> error
          end
        else
          {:error, changeset}
        end
    end
  end

  defp tool_results_quarantined_error(%Message{} = message, quarantine) do
    {:error,
     {:tool_results_quarantined,
      quarantine
      |> Map.put("quarantine_response_id", "resp_#{message.id}")
      |> Map.put("quarantine_status", message.status)}}
  end

  def request_items_metadata(request_items) when is_list(request_items) do
    %{"request_item_count" => length(request_items)}
    |> maybe_put_metadata("tool_results", tool_results_metadata(request_items))
  end

  def request_items_metadata(_request_items), do: %{}

  defp tool_results_metadata(request_items) do
    request_items
    |> Enum.filter(&tool_call_output_item?/1)
    |> Enum.map(fn item ->
      item
      |> Map.take(["call_id", "output"])
      |> maybe_put_metadata("id", Map.get(item, "id"))
      |> maybe_put_metadata("status", Map.get(item, "status"))
    end)
  end

  defp tool_call_output_item?(item), do: ResponseItems.client_output_item?(item)

  defp publish_tool_result_events(%Message{} = message, request_items) do
    request_items
    |> Enum.filter(&tool_call_output_item?/1)
    |> Enum.each(fn item ->
      Events.publish(
        message,
        :tool_call_completed,
        item |> Map.take(["call_id", "name", "output"]) |> Map.put_new("seq", nil)
      )
    end)
  end

  @doc false
  @spec publish_tool_result_events(Message.t()) :: :ok
  def publish_tool_result_events(%Message{} = message) do
    publish_tool_result_events(message, message.content || [])
  end

  defp validate_tool_result_items(request_items) when is_list(request_items) do
    case Enum.any?(request_items, &tool_call_output_item?/1) do
      true -> :ok
      false -> {:error, :invalid_tool_results}
    end
  end

  defp validate_tool_result_items(_request_items), do: {:error, :invalid_tool_results}

  defp tool_result_idempotency_key(subject_uid, previous_message_id, request_items) do
    stable_term = {subject_uid, previous_message_id, request_items}

    stable_term
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp unique_constraint_error?(%Ecto.Changeset{errors: errors}, constraint_name) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      opts[:constraint] == :unique and opts[:constraint_name] == constraint_name
    end)
  end

  defp maybe_put_metadata(map, _key, nil), do: map
  defp maybe_put_metadata(map, _key, ""), do: map
  defp maybe_put_metadata(map, key, value), do: Map.put(map, key, value)
end
