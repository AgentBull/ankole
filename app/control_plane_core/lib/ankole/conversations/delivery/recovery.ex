defmodule Ankole.Conversations.Delivery.Recovery do
  @moduledoc false
  import Ecto.Query, warn: false

  alias Ankole.I18n
  alias Ankole.Logging
  alias Ankole.Repo
  alias Ankole.Conversations.Delivery.Adapter
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Signals.Sanitizer

  # Give a transient provider failure a short recovery window before retry.
  @intent_base_retry_seconds 5
  # Prevent repeated provider failures from delaying recovery without limit.
  @intent_max_retry_seconds 5 * 60
  # Let recovery reclaim a provider call that has no durable result.
  @in_flight_recovery_seconds 60

  @spec in_flight_recovery_seconds() :: pos_integer()
  def in_flight_recovery_seconds, do: @in_flight_recovery_seconds

  @doc """
  Returns whether one stopped intent row can receive an explicit retry.
  """
  @spec requeueable?(Intent.t()) :: boolean()
  def requeueable?(%Intent{} = intent) do
    match?(
      {:ok, _attrs},
      explicit_requeue_attrs(intent, DateTime.utc_now(:microsecond))
    )
  end

  @doc """
  Gives one stopped durable reply one explicit provider call on the same row.

  The attempt count remains monotonic. If an earlier send was uncertain, the
  possible-duplicate notice remains part of the visible reply.
  """
  @spec requeue(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Intent.t()} | {:error, term()}
  def requeue(agent_uid, binding_name, outbound_key, options \\ [])

  def requeue(agent_uid, binding_name, outbound_key, options)
      when is_binary(agent_uid) and is_binary(binding_name) and is_binary(outbound_key) and
             is_list(options) do
    now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %Intent{} = intent <-
             Ankole.Conversations.Delivery.Queries.fetch_delivery_for_update(
               repo,
               agent_uid,
               binding_name,
               outbound_key
             ),
           {:ok, attrs} <- explicit_requeue_attrs(intent, now),
           {:ok, intent} <- intent |> Intent.changeset(attrs) |> repo.update(),
           :ok <- notify_intent_deadline(repo, intent) do
        {:ok, intent}
      else
        nil -> {:error, :intent_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  def requeue(_agent_uid, _binding_name, _outbound_key, _options),
    do: {:error, :invalid_intent_key}

  @doc false
  @spec wake_blocked_for_binding(String.t(), String.t()) :: :ok | {:error, term()}
  def wake_blocked_for_binding(agent_uid, binding_name)
      when is_binary(agent_uid) and is_binary(binding_name) do
    now = DateTime.utc_now(:microsecond)

    case Repo.transact(fn repo ->
           rows =
             Intent
             |> where([entry], entry.agent_uid == ^Ankole.PrincipalKey.canonicalize(agent_uid))
             |> where([entry], entry.binding_name == ^binding_name)
             |> where([entry], entry.delivery_class == :durable_ai_reply)
             |> where([entry], entry.status == :failed)
             |> where([entry], fragment("?->>'state' = 'blocked'", entry.recovery_state))
             |> lock("FOR UPDATE")
             |> repo.all()

           Enum.reduce_while(rows, {:ok, []}, fn intent, {:ok, acc} ->
             with {:ok, attrs} <- explicit_requeue_attrs(intent, now),
                  {:ok, intent} <-
                    intent
                    |> Intent.changeset(attrs)
                    |> repo.update(),
                  :ok <- notify_intent_deadline(repo, intent) do
               {:cont, {:ok, [intent | acc]}}
             else
               {:error, reason} -> {:halt, {:error, reason}}
             end
           end)
         end) do
      {:ok, _rows} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def wake_blocked_for_binding(_agent_uid, _binding_name),
    do: {:error, :invalid_signal_binding}

  defp explicit_requeue_attrs(
         %Intent{
           delivery_class: :durable_ai_reply,
           status: status,
           next_attempt_at: nil
         } = intent,
         now
       )
       when status in [:failed, :unknown] do
    ambiguous? = status == :unknown or possible_duplicate?(intent.recovery_state)

    with {:ok, content_attrs, notice} <- requeue_content_attrs(intent, ambiguous?) do
      {:ok,
       Map.merge(content_attrs, %{
         status: :pending,
         platform_send_started_at: nil,
         max_attempts: intent.attempt_count + 1,
         next_attempt_at: now,
         recovery_state: active_recovery_state(intent, ambiguous?, notice)
       })}
    end
  end

  defp explicit_requeue_attrs(%Intent{}, _now),
    do: {:error, :intent_not_requeueable}

  defp requeue_content_attrs(_intent, false), do: {:ok, %{}, nil}

  defp requeue_content_attrs(intent, true) do
    case possible_duplicate_notice(intent.recovery_state) do
      notice when is_binary(notice) -> {:ok, %{}, notice}
      nil -> ambiguous_reply_content_attrs(intent)
    end
  end

  def in_flight_recovery_action(
        %Intent{status: :pending, platform_send_started_at: %DateTime{} = started_at} =
          intent,
        adapter,
        now
      ) do
    case in_flight_recovery_due?(started_at, now) do
      true -> stale_in_flight_recovery_action(intent, adapter)
      false -> {:in_flight, intent}
    end
  end

  def in_flight_recovery_action(_intent, _adapter, _now), do: :continue

  defp stale_in_flight_recovery_action(
         %Intent{
           delivery_class: :durable_ai_reply,
           payload: %{"reply_presentation" => presentation}
         } = intent,
         adapter
       )
       when is_map(presentation) do
    capabilities = Adapter.capabilities(adapter)

    case MapSet.member?(capabilities, :outbound_reconciliation) do
      true -> {:reconcile, intent}
      false -> {:unknown, intent, %{"reason" => "durable AI reply cannot be reconciled"}}
    end
  end

  defp stale_in_flight_recovery_action(intent, _adapter),
    do:
      {:unknown, intent,
       %{
         "reason" => "provider send started without provider entry id"
       }}

  defp in_flight_recovery_due?(%DateTime{} = started_at, %DateTime{} = now) do
    cutoff = DateTime.add(now, -@in_flight_recovery_seconds, :second)
    DateTime.compare(started_at, cutoff) != :gt
  end

  def mark_intent_failed(repo, intent, reason, now) do
    reason = delivery_failure(reason)
    {last_error, next_attempt_at, recovery_state} = failure_recovery(intent, reason, now)

    with {:ok, %Intent{} = intent} <-
           intent
           |> Intent.changeset(%{
             status: :failed,
             last_error: last_error,
             next_attempt_at: next_attempt_at,
             recovery_state: recovery_state
           })
           |> repo.update(),
         :ok <- notify_intent_deadline(repo, intent) do
      log_delivery_failure(intent, reason)
      {:ok, intent}
    end
  end

  # A drive content that is gone stays gone, so every adapter blocks on it at
  # once instead of retrying; `Ankole.Conversations.Delivery.attachment_content/1` names it.
  defp delivery_failure(:attachment_file_missing),
    do: {:reply_delivery, :operator_action_required, %{"code" => "attachment_file_missing"}}

  defp delivery_failure(reason), do: reason

  defp failure_recovery(
         intent,
         {:reply_delivery, :operator_action_required, detail},
         _now
       ) do
    {
      %{"reason" => Sanitizer.transport(detail)},
      nil,
      terminal_recovery_state(intent, "blocked", "operator_action_required")
    }
  end

  defp failure_recovery(intent, {:reply_delivery, :permanent, detail}, _now) do
    {
      %{"reason" => Sanitizer.transport(detail)},
      nil,
      terminal_recovery_state(intent, "permanent", "permanent_failure")
    }
  end

  defp failure_recovery(intent, {:reply_delivery, :retryable, detail}, now) do
    retry_failure_recovery(intent, detail, now)
  end

  defp failure_recovery(intent, reason, now) do
    retry_failure_recovery(intent, reason, now)
  end

  defp retry_failure_recovery(intent, detail, now) do
    next_attempt_at = next_intent_attempt_at(intent, now, retry_after_seconds(detail))

    {
      %{"reason" => Sanitizer.transport(detail)},
      next_attempt_at,
      if(is_nil(next_attempt_at),
        do: terminal_recovery_state(intent, "exhausted", "max_attempts_reached"),
        else: active_recovery_state(intent)
      )
    }
  end

  defp log_delivery_failure(%Intent{} = intent, reason) do
    {failure_class, failure_code} = delivery_failure_identity(reason)

    fields = %{
      agent_uid: intent.agent_uid,
      binding_name: intent.binding_name,
      outbound_key: intent.outbound_key,
      source_signal_id: intent.source_signal_id,
      operation: intent.operation,
      delivery_class: intent.delivery_class,
      attempt_count: intent.attempt_count,
      max_attempts: intent.max_attempts,
      failure_class: failure_class,
      failure_code: failure_code,
      recovery_state: intent.recovery_state["state"],
      retry_scheduled: not is_nil(intent.next_attempt_at),
      next_attempt_at: encode_log_datetime(intent.next_attempt_at)
    }

    if is_nil(intent.next_attempt_at) do
      Logging.error(
        "conversations.delivery.delivery_failed",
        "signals gateway intent delivery stopped",
        fields
      )
    else
      Logging.warning(
        "conversations.delivery.delivery_failed",
        "signals gateway intent delivery will retry",
        fields
      )
    end
  end

  defp delivery_failure_identity({:reply_delivery, :operator_action_required, detail}),
    do: {"operator_action_required", delivery_failure_code(detail)}

  defp delivery_failure_identity({:reply_delivery, :retryable, detail}),
    do: {"retryable", delivery_failure_code(detail)}

  defp delivery_failure_identity({:reply_delivery, :permanent, detail}),
    do: {"permanent", delivery_failure_code(detail)}

  defp delivery_failure_identity(reason) when is_atom(reason),
    do: {"adapter_error", Atom.to_string(reason)}

  defp delivery_failure_identity({reason, _detail}) when is_atom(reason),
    do: {"adapter_error", Atom.to_string(reason)}

  defp delivery_failure_identity(reason),
    do: {"adapter_error", delivery_failure_code(reason)}

  defp delivery_failure_code(%{} = detail) do
    detail
    |> Map.get(:code, Map.get(detail, "code"))
    |> normalize_log_code()
  end

  defp delivery_failure_code(_detail), do: nil

  defp normalize_log_code(value) when is_binary(value), do: value
  defp normalize_log_code(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_log_code(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_log_code(_value), do: nil

  defp encode_log_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_log_datetime(nil), do: nil

  def mark_intent_unknown(repo, intent, reason, now) do
    attrs =
      intent
      |> unknown_recovery_attrs(now)
      |> Map.merge(%{
        status: :unknown,
        last_error: Sanitizer.transport(reason)
      })

    with {:ok, intent} <- intent |> Intent.changeset(attrs) |> repo.update(),
         :ok <- notify_intent_deadline(repo, intent) do
      {:ok, intent}
    end
  end

  defp unknown_recovery_attrs(%Intent{} = intent, _now) do
    %{
      next_attempt_at: nil,
      recovery_state:
        terminal_recovery_state(
          intent,
          "blocked",
          "ambiguous_delivery_not_retried",
          true,
          nil
        )
    }
  end

  defp ambiguous_reply_content_attrs(%Intent{} = intent) do
    notice = possible_duplicate_notice(intent.recovery_state) || ambiguous_delivery_notice()
    payload = prefix_ambiguous_payload(intent.payload, notice)
    fallback_visible_text = prefix_ambiguous_text(intent.fallback_visible_text, notice)

    if visible_reply_content?(intent) do
      {:ok, %{payload: payload, fallback_visible_text: fallback_visible_text}, notice}
    else
      {:error, :intent_ambiguous_delivery_not_requeueable}
    end
  end

  defp visible_reply_content?(%Intent{
         payload: payload,
         fallback_visible_text: fallback_visible_text
       }) do
    presentation_answer =
      case payload do
        %{"reply_presentation" => presentation} when is_map(presentation) ->
          Map.get(presentation, "answer")

        _missing ->
          nil
      end

    payload_text = if is_map(payload), do: Map.get(payload, "text")

    Enum.any?(
      [payload_text, presentation_answer, fallback_visible_text],
      &(Ankole.Conversations.Delivery.normalize_visible_text(&1) != "")
    )
  end

  defp prefix_ambiguous_payload(payload, notice) when is_map(payload) do
    payload = prefix_map_text(payload, "text", notice)

    case Map.get(payload, "reply_presentation") do
      presentation when is_map(presentation) ->
        Map.put(
          payload,
          "reply_presentation",
          prefix_map_text(presentation, "answer", notice)
        )

      _missing_or_invalid ->
        payload
    end
  end

  defp prefix_map_text(map, key, notice) do
    case Map.get(map, key) do
      text when is_binary(text) -> Map.put(map, key, prefix_ambiguous_text(text, notice))
      _missing -> map
    end
  end

  defp prefix_ambiguous_text(text, notice) when is_binary(text) do
    cond do
      String.trim(text) == "" -> notice
      String.starts_with?(text, notice) -> text
      true -> notice <> "\n\n" <> text
    end
  end

  defp prefix_ambiguous_text(value, _notice), do: value

  defp ambiguous_delivery_notice,
    do: I18n.t("conversations.delivery.reply.possible_duplicate_delivery")

  defp active_recovery_state(intent),
    do: active_recovery_state(intent, possible_duplicate?(intent.recovery_state), nil)

  defp active_recovery_state(intent, ambiguous?, notice),
    do: possible_duplicate_recovery_state(intent.recovery_state, ambiguous?, notice)

  defp terminal_recovery_state(intent, state, reason),
    do:
      terminal_recovery_state(
        intent,
        state,
        reason,
        possible_duplicate?(intent.recovery_state),
        nil
      )

  defp terminal_recovery_state(intent, state, reason, ambiguous?, notice) do
    intent.recovery_state
    |> possible_duplicate_recovery_state(ambiguous?, notice)
    |> Map.merge(%{"state" => state, "reason" => reason})
  end

  defp possible_duplicate_recovery_state(_recovery_state, false, _notice), do: %{}

  defp possible_duplicate_recovery_state(recovery_state, true, notice) do
    notice = notice || possible_duplicate_notice(recovery_state)
    state = %{"possible_duplicate" => true}

    if is_binary(notice) and notice != "" do
      Map.put(state, "possible_duplicate_notice", notice)
    else
      state
    end
  end

  defp possible_duplicate?(recovery_state) when is_map(recovery_state),
    do: Map.get(recovery_state, "possible_duplicate") == true

  defp possible_duplicate?(_recovery_state), do: false

  defp possible_duplicate_notice(recovery_state) when is_map(recovery_state) do
    case Map.get(recovery_state, "possible_duplicate_notice") do
      notice when is_binary(notice) and notice != "" -> notice
      _missing -> nil
    end
  end

  defp possible_duplicate_notice(_recovery_state), do: nil

  # Prefer the id the provider returned; fall back to one already on the row.
  # Without a provider-derived entry id there is no source mirror identity, so a
  # confirmed delivery remains sent without creating a second message.
  defp next_intent_attempt_at(
         %Intent{attempt_count: attempts, max_attempts: max},
         _now,
         _minimum_delay_seconds
       )
       when attempts >= max,
       do: nil

  defp next_intent_attempt_at(
         %Intent{attempt_count: attempts},
         now,
         minimum_delay_seconds
       ) do
    backoff_seconds =
      attempts
      |> max(1)
      |> then(&(@intent_base_retry_seconds * Integer.pow(2, &1 - 1)))
      |> min(@intent_max_retry_seconds)

    delay_seconds = max(backoff_seconds, minimum_delay_seconds)
    DateTime.add(now, delay_seconds, :second)
  end

  defp retry_after_seconds(detail), do: Ankole.Attrs.reply_delivery_retry_after_seconds(detail)

  def notify_intent_deadline(repo, %Intent{} = intent) do
    Ankole.Conversations.Delivery.Jobs.Dispatch.schedule_in_tx(
      repo,
      %{
        agent_uid: intent.agent_uid,
        binding_name: intent.binding_name,
        outbound_key: intent.outbound_key
      },
      intent_due_at(intent)
    )
  end

  defp intent_due_at(%Intent{
         status: :pending,
         platform_send_started_at: %DateTime{} = started_at
       }),
       do: DateTime.add(started_at, @in_flight_recovery_seconds, :second)

  defp intent_due_at(%Intent{
         status: :pending,
         platform_send_started_at: nil,
         next_attempt_at: %DateTime{} = at
       }),
       do: at

  defp intent_due_at(%Intent{status: :pending, expires_at: expires_at}) do
    now = DateTime.utc_now(:microsecond)
    if expires_at && DateTime.compare(expires_at, now) == :lt, do: expires_at, else: now
  end

  defp intent_due_at(%Intent{status: :failed, next_attempt_at: next_attempt_at}),
    do: next_attempt_at

  defp intent_due_at(%Intent{}), do: nil

  # Confirmed provider messages join the same history as incoming messages.
  # Preserve every chunk's identity and content alongside the sent status.
end
