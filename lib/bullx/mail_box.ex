defmodule BullX.MailBox do
  @moduledoc """
  Internal CloudEvents mail delivery window.

  MailBox owns receiver delivery entries and short processing sessions. It does
  not own IM messages, conversations, workflow runs, or outbound provider facts.
  """

  import Ecto.Query

  alias BullX.AIAgent.Message, as: ConversationMessage
  alias BullX.MailBox.{Dispatcher, SessionWorker}
  alias BullX.MailBox.Matcher
  alias BullX.MailBox.{DeliveryRule, Entry, Session}
  alias BullX.Principals.Agent
  alias BullX.Repo

  @lease_seconds 60
  @session_lease_seconds 120
  @lifecycle_in_flight_retry_ms 250
  @default_claim_limit 10
  @attention [:addressed, :ambient, :command, :action, :lifecycle, :system]
  @addressed_attention_reasons ~w(dm mention free_response command reply_to_bot application_command mention_text action batch_addressed)
  @control_event_types [
    "bullx.command.invoked",
    "bullx.agent.abort",
    "bullx.message.edited",
    "bullx.message.recalled",
    "bullx.message.deleted"
  ]

  @type deliver_result ::
          {:ok, %{agent: Agent.t(), session: Session.t(), entry: Entry.t()}}
          | {:ok, %{status: :duplicate, agent: Agent.t(), session: Session.t(), entry: Entry.t()}}
          | {:error, term()}

  @spec route(map(), keyword()) :: {:ok, [deliver_result()]} | {:error, term()}
  def route(cloud_event, opts \\ []) when is_map(cloud_event) and is_list(opts) do
    context = routing_context(cloud_event)
    rules = active_rules()

    with {:ok, matched_rules} <- match_rules(rules, context) do
      matched_rules
      |> Enum.map(&deliver(rule_request(&1, cloud_event), opts))
      |> then(&{:ok, &1})
    end
  end

  @spec deliver(map(), keyword()) :: deliver_result()
  def deliver(request, _opts \\ []) when is_map(request) do
    attrs = normalize_request(request)

    Repo.transaction(fn ->
      with {:ok, agent} <- get_agent(attrs),
           {:ok, session} <- get_or_create_session(agent, attrs),
           {:ok, entry} <- insert_entry(agent, session, attrs) do
        %{agent: agent, session: session, entry: entry}
      else
        {:duplicate, agent, session, entry} ->
          %{status: :duplicate, agent: agent, session: session, entry: entry}

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, result} ->
        wake_delivery(result)
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec deliver_many([map()], keyword()) :: [deliver_result()]
  def deliver_many(requests, opts \\ []) when is_list(requests) do
    Enum.map(requests, &deliver(&1, opts))
  end

  defp claim_ready_sessions(limit, opts)
       when is_integer(limit) and limit > 0 and is_list(opts) do
    now = utc_now()
    holder = Keyword.get(opts, :holder, default_holder())

    Repo.transaction(fn ->
      sessions =
        Session
        |> where(
          [session],
          is_nil(session.lease_holder) or is_nil(session.lease_expires_at) or
            session.lease_expires_at <= ^now
        )
        |> where(
          [session],
          fragment(
            """
            EXISTS (
              SELECT 1
              FROM mailbox_entries e
              WHERE e.mailbox_session_id = ?
                AND e.available_at <= ?
                AND (
                  e.status = 'pending' OR
                  (e.status = 'leased' AND (e.lease_expires_at IS NULL OR e.lease_expires_at <= ?))
                )
                AND COALESCE(e.cloud_event->>'type', '') NOT IN (
                  'bullx.command.invoked',
                  'bullx.agent.abort',
                  'bullx.message.edited',
                  'bullx.message.recalled',
                  'bullx.message.deleted'
                )
            )
            """,
            session.id,
            ^now,
            ^now
          )
        )
        |> order_by([session], asc: session.last_entry_at)
        |> limit(^limit)
        |> lock("FOR UPDATE SKIP LOCKED")
        |> Repo.all()

      ids = Enum.map(sessions, & &1.id)

      case ids do
        [] ->
          []

        [_ | _] ->
          lease_until = DateTime.add(now, @session_lease_seconds, :second)

          Repo.update_all(
            from(session in Session, where: session.id in ^ids),
            set: [
              lease_holder: holder,
              lease_expires_at: lease_until,
              updated_at: now
            ]
          )

          Session
          |> where([session], session.id in ^ids)
          |> order_by([session], asc: session.last_entry_at)
          |> Repo.all()
      end
    end)
    |> case do
      {:ok, sessions} -> {:ok, sessions}
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim_ready_control_entries(limit, opts)
       when is_integer(limit) and limit > 0 and is_list(opts) do
    now = utc_now()
    holder = Keyword.get(opts, :holder, default_holder())

    Repo.transaction(fn ->
      entries =
        Entry
        |> where([entry], entry.available_at <= ^now)
        |> where(
          [entry],
          entry.status == :pending or
            (entry.status == :leased and
               (is_nil(entry.lease_expires_at) or entry.lease_expires_at <= ^now))
        )
        |> where(
          [entry],
          fragment("?->>'type' = ANY(?)", entry.cloud_event, ^@control_event_types)
        )
        |> order_by([entry], asc: entry.entry_seq)
        |> limit(^limit)
        |> lock("FOR UPDATE SKIP LOCKED")
        |> Repo.all()

      lease_entries(entries, holder, now)
    end)
    |> case do
      {:ok, entries} -> {:ok, entries}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec next_ready_at() :: DateTime.t() | nil
  def next_ready_at do
    now = utc_now()

    pending_next =
      Entry
      |> where([entry], entry.status == :pending)
      |> select([entry], min(entry.available_at))
      |> Repo.one()

    leased_next =
      Entry
      |> where([entry], entry.status == :leased)
      |> select([entry], min(coalesce(entry.lease_expires_at, ^now)))
      |> Repo.one()

    earliest_datetime([pending_next, leased_next])
  end

  @spec process_entry(Entry.t(), keyword()) :: :ok | {:error, term()}
  def process_entry(%Entry{} = entry, opts \\ []) when is_list(opts) do
    entry = Repo.preload(entry, [:agent, :session])
    holder = Keyword.get(opts, :holder, entry.lease_holder)

    case maybe_apply_lifecycle_to_pending_receive(entry) do
      :applied ->
        mark_entry(entry, :processed, nil, holder)

      :defer ->
        defer_entry(entry, holder)

      :continue ->
        process_dispatch_entry(entry, holder, opts)

      {:error, reason} ->
        mark_entry(entry, :failed, safe_error(reason), holder)
    end
  end

  defp process_dispatch_entry(%Entry{} = entry, holder, opts) do
    {entry, coalesced_entries} = coalesce_entry(entry, holder)

    case dispatch(entry, opts) do
      :ok ->
        with :ok <- mark_entry(entry, :processed, nil, holder),
             :ok <- mark_entries(coalesced_entries, :processed, nil, holder) do
          :ok
        end

      {:error, reason} ->
        release_entries(coalesced_entries, holder)
        mark_entry(entry, :failed, safe_error(reason), holder)
    end
  end

  @spec process_entry_by_id(String.t(), keyword()) :: :ok | {:error, term()}
  def process_entry_by_id(entry_id, opts \\ []) when is_binary(entry_id) and is_list(opts) do
    with {:ok, entry} <- claim_entry(entry_id, opts) do
      process_entry(entry, Keyword.put(opts, :holder, entry.lease_holder))
    end
  end

  @spec process_session(Session.t(), keyword()) :: :ok | {:error, term()}
  def process_session(%Session{} = session, opts \\ []) when is_list(opts) do
    holder = session.lease_holder || Keyword.get(opts, :holder, default_holder())
    heartbeat = start_session_heartbeat(session.id, holder)

    try do
      process_session_loop(session.id, holder, opts)
    after
      stop_session_heartbeat(heartbeat)
      release_session(session.id, holder)
    end
  end

  @spec process_ready(pos_integer(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def process_ready(limit \\ @default_claim_limit, opts \\ []) do
    async? = Keyword.get(opts, :async?, false)

    with {:ok, controls} <- claim_ready_control_entries(limit, opts),
         remaining <- max(limit - length(controls), 0),
         {:ok, sessions} <- maybe_claim_ready_sessions(remaining, opts) do
      Enum.each(controls, &process_or_start_entry(&1, opts, async?))
      Enum.each(sessions, &process_or_start_session(&1, opts, async?))

      {:ok, length(controls) + length(sessions)}
    end
  end

  defp maybe_claim_ready_sessions(0, _opts), do: {:ok, []}
  defp maybe_claim_ready_sessions(limit, opts), do: claim_ready_sessions(limit, opts)

  defp process_or_start_entry(%Entry{} = entry, opts, true) do
    opts = Keyword.put(opts, :holder, entry.lease_holder)
    SessionWorker.start_entry(entry, opts)
  end

  defp process_or_start_entry(%Entry{} = entry, opts, false) do
    process_entry(entry, Keyword.put(opts, :holder, entry.lease_holder))
  end

  defp process_or_start_session(%Session{} = session, opts, true) do
    opts = Keyword.put(opts, :holder, session.lease_holder)
    SessionWorker.start_session(session, opts)
  end

  defp process_or_start_session(%Session{} = session, opts, false) do
    process_session(session, Keyword.put(opts, :holder, session.lease_holder))
  end

  defp process_session_loop(session_id, holder, opts) do
    case claim_next_session_entry(session_id, holder) do
      {:ok, nil} ->
        :ok

      {:ok, %Entry{} = entry} ->
        _result = process_entry(entry, Keyword.put(opts, :holder, holder))
        process_session_loop(session_id, holder, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp claim_next_session_entry(session_id, holder) do
    now = utc_now()

    Repo.transaction(fn ->
      entry =
        Entry
        |> where([entry], entry.mailbox_session_id == ^session_id)
        |> where([entry], entry.available_at <= ^now)
        |> where(
          [entry],
          entry.status == :pending or
            (entry.status == :leased and
               (is_nil(entry.lease_expires_at) or entry.lease_expires_at <= ^now))
        )
        |> where(
          [entry],
          fragment(
            "NOT (COALESCE(?->>'type', '') = ANY(?))",
            entry.cloud_event,
            ^@control_event_types
          )
        )
        |> order_by([entry], asc: entry.entry_seq)
        |> limit(1)
        |> lock("FOR UPDATE SKIP LOCKED")
        |> Repo.one()

      case lease_entries(List.wrap(entry), holder, now) do
        [] -> nil
        [entry] -> entry
      end
    end)
    |> case do
      {:ok, entry_or_nil} -> {:ok, entry_or_nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim_entry(entry_id, opts) do
    now = utc_now()
    holder = Keyword.get(opts, :holder, default_holder())

    Repo.transaction(fn ->
      entry =
        Entry
        |> where([entry], entry.id == ^entry_id)
        |> where([entry], entry.available_at <= ^now)
        |> where(
          [entry],
          entry.status == :pending or
            (entry.status == :leased and
               (is_nil(entry.lease_expires_at) or entry.lease_expires_at <= ^now))
        )
        |> lock("FOR UPDATE SKIP LOCKED")
        |> Repo.one()

      case lease_entries(List.wrap(entry), holder, now) do
        [] -> Repo.rollback(:entry_not_ready)
        [entry] -> entry
      end
    end)
    |> case do
      {:ok, entry} -> {:ok, entry}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lease_entries([], _holder, _now), do: []

  defp lease_entries(entries, holder, now) do
    ids = Enum.map(entries, & &1.id)

    Repo.update_all(
      from(entry in Entry, where: entry.id in ^ids),
      set: [
        status: :leased,
        lease_holder: holder,
        lease_expires_at: DateTime.add(now, @lease_seconds, :second),
        updated_at: now
      ],
      inc: [attempts: 1]
    )

    Entry
    |> where([entry], entry.id in ^ids)
    |> order_by([entry], asc: entry.entry_seq)
    |> preload([:agent, :session])
    |> Repo.all()
  end

  defp start_session_heartbeat(session_id, holder) when is_binary(holder) do
    ref = make_ref()
    interval_ms = div(@session_lease_seconds * 1_000, 3)
    pid = spawn(fn -> session_heartbeat_loop(ref, session_id, holder, interval_ms) end)
    {pid, ref}
  end

  defp start_session_heartbeat(_session_id, _holder), do: nil

  defp stop_session_heartbeat({pid, ref}) when is_pid(pid), do: send(pid, {:stop, ref})
  defp stop_session_heartbeat(_heartbeat), do: :ok

  defp session_heartbeat_loop(ref, session_id, holder, interval_ms) do
    receive do
      {:stop, ^ref} ->
        :ok
    after
      interval_ms ->
        _ignored = heartbeat_session(session_id, holder)
        session_heartbeat_loop(ref, session_id, holder, interval_ms)
    end
  end

  defp heartbeat_session(session_id, holder) do
    now = utc_now()

    Repo.update_all(
      from(session in Session,
        where: session.id == ^session_id and session.lease_holder == ^holder
      ),
      set: [
        lease_expires_at: DateTime.add(now, @session_lease_seconds, :second),
        updated_at: now
      ]
    )
  end

  defp release_session(session_id, holder) when is_binary(holder) do
    now = utc_now()

    Repo.update_all(
      from(session in Session,
        where: session.id == ^session_id and session.lease_holder == ^holder
      ),
      set: [lease_holder: nil, lease_expires_at: nil, updated_at: now]
    )

    :ok
  end

  defp release_session(_session_id, _holder), do: :ok

  defp coalesce_entry(%Entry{} = entry, holder) when is_binary(holder) do
    case coalesce_config(entry) do
      {:ok, window_ms, max_chars} ->
        entries = claim_coalesced_entries(entry, holder, window_ms, max_chars)
        {merge_coalesced_entries(entry, entries), entries}

      :skip ->
        {entry, []}
    end
  end

  defp coalesce_entry(%Entry{} = entry, _holder), do: {entry, []}

  defp coalesce_config(%Entry{
         cloud_event: %{
           "type" => "bullx.message.received",
           "data" => %{"coalesce" => %{} = config}
         }
       }) do
    window_ms = integer_value(config["window_ms"], 0)
    max_chars = integer_value(config["max_chars"], 0)

    case window_ms > 0 and max_chars > 0 do
      true -> {:ok, window_ms, max_chars}
      false -> :skip
    end
  end

  defp coalesce_config(_entry), do: :skip

  defp maybe_apply_lifecycle_to_pending_receive(%Entry{
         mailbox_session_id: session_id,
         cloud_event: %{"type" => type, "data" => %{} = data}
       })
       when type in ["bullx.message.edited", "bullx.message.recalled", "bullx.message.deleted"] do
    case source_message_ids(data) do
      [] ->
        :continue

      target_ids ->
        case receive_for_lifecycle(session_id, target_ids) do
          {:pending, %Entry{} = target} ->
            apply_lifecycle_to_pending_receive(target, type, data)

          {:leased, %Entry{} = target} ->
            case lifecycle_target_materialized?(session_id, target_ids, target) do
              true -> :continue
              false -> :defer
            end

          nil ->
            :continue
        end
    end
  end

  defp maybe_apply_lifecycle_to_pending_receive(_entry), do: :continue

  defp receive_for_lifecycle(session_id, target_ids) do
    target_set = MapSet.new(target_ids)

    Entry
    |> where([entry], entry.mailbox_session_id == ^session_id)
    |> where([entry], entry.status in [:pending, :leased])
    |> where(
      [entry],
      fragment("?->>'type' = 'bullx.message.received'", entry.cloud_event)
    )
    |> order_by([entry], asc: entry.entry_seq)
    |> limit(100)
    |> Repo.all()
    |> Enum.find_value(fn entry ->
      matches? =
        entry
        |> get_in([Access.key(:cloud_event), "data"])
        |> source_message_ids()
        |> Enum.any?(&MapSet.member?(target_set, &1))

      case matches? do
        true -> {entry.status, entry}
        false -> nil
      end
    end)
  end

  defp lifecycle_target_materialized?(session_id, target_ids, %Entry{} = target) do
    target_set = MapSet.new(target_ids)

    ConversationMessage
    |> where([message], message.mailbox_session_id == ^session_id)
    |> where([message], message.role in [:user, :im_ambient])
    |> where([message], message.kind == :normal)
    |> where([message], is_nil(fragment("?->'branch_effect'", message.metadata)))
    |> order_by([message], desc: message.inserted_at)
    |> limit(100)
    |> Repo.all()
    |> Enum.any?(&materialized_target?(&1, target.id, target_set))
  end

  defp materialized_target?(
         %ConversationMessage{mailbox_entry_id: message_entry_id},
         target_entry_id,
         _target_set
       )
       when is_binary(message_entry_id) and message_entry_id == target_entry_id,
       do: true

  defp materialized_target?(%ConversationMessage{metadata: metadata}, _entry_id, target_set) do
    metadata
    |> materialized_source_ids()
    |> Enum.any?(&MapSet.member?(target_set, &1))
  end

  defp materialized_source_ids(metadata) when is_map(metadata) do
    provider_ids =
      metadata
      |> get_in(["provider_refs", "message_ids"])
      |> List.wrap()

    batch_ids =
      metadata
      |> get_in(["im_batch", "items"])
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"provider_message_ids" => ids} -> List.wrap(ids)
        _item -> []
      end)

    (provider_ids ++ batch_ids)
    |> Enum.map(&string_value/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp materialized_source_ids(_metadata), do: []

  defp apply_lifecycle_to_pending_receive(%Entry{} = target, "bullx.message.edited", data) do
    cloud_event = edited_pending_receive_event(target.cloud_event, data)
    attention = event_attention(cloud_event)

    target
    |> Entry.changeset(%{cloud_event: cloud_event, attention: attention})
    |> Repo.update()
    |> case do
      {:ok, _entry} -> :applied
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp apply_lifecycle_to_pending_receive(%Entry{} = target, type, _data)
       when type in ["bullx.message.recalled", "bullx.message.deleted"] do
    now = utc_now()

    {count, _rows} =
      Repo.update_all(
        from(entry in Entry, where: entry.id == ^target.id and entry.status == :pending),
        set: [status: :discarded, updated_at: now]
      )

    case count do
      1 -> :applied
      0 -> :continue
    end
  end

  defp edited_pending_receive_event(%{} = cloud_event, %{} = edit_data) do
    data = cloud_event["data"] || %{}

    merged_data =
      data
      |> Map.put("content", edit_data["content"] || data["content"] || [])
      |> Map.put("refs", merge_refs(data["refs"], edit_data["refs"]))
      |> Map.put("raw_ref", edit_data["raw_ref"] || data["raw_ref"])
      |> Map.put(
        "routing_facts",
        merge_routing_facts(data["routing_facts"], edit_data["routing_facts"])
      )
      |> Map.put("reply_address", edit_data["reply_address"] || data["reply_address"])
      |> Map.put("pending_lifecycle", %{
        "action" => "edited",
        "event_id" => edit_data["event_id"]
      })
      |> reject_nil_values()

    Map.put(cloud_event, "data", merged_data)
  end

  defp merge_refs(left, right) do
    (List.wrap(left) ++ List.wrap(right))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp merge_routing_facts(%{} = left, %{} = right), do: Map.merge(left, right)
  defp merge_routing_facts(%{} = left, _right), do: left
  defp merge_routing_facts(_left, %{} = right), do: right
  defp merge_routing_facts(_left, _right), do: %{}

  defp claim_coalesced_entries(%Entry{} = entry, holder, window_ms, max_chars) do
    actor_key = coalesce_actor_key(entry)
    base_chars = text_chars(entry)
    window_until = DateTime.add(entry.inserted_at, window_ms, :millisecond)

    candidates =
      Entry
      |> where([candidate], candidate.mailbox_session_id == ^entry.mailbox_session_id)
      |> where([candidate], candidate.entry_seq > ^entry.entry_seq)
      |> where([candidate], candidate.inserted_at <= ^window_until)
      |> where([candidate], candidate.status == :pending)
      |> where(
        [candidate],
        fragment("?->>'type' = 'bullx.message.received'", candidate.cloud_event)
      )
      |> order_by([candidate], asc: candidate.entry_seq)
      |> limit(50)
      |> Repo.all()

    candidates
    |> Enum.reduce_while({[], base_chars}, fn candidate, {acc, chars} ->
      candidate_chars = text_chars(candidate)

      cond do
        coalesce_actor_key(candidate) != actor_key ->
          {:halt, {acc, chars}}

        chars + candidate_chars > max_chars ->
          {:halt, {acc, chars}}

        true ->
          {:cont, {[candidate | acc], chars + candidate_chars}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> case do
      [] -> []
      entries -> lease_entries(entries, holder, utc_now())
    end
  end

  defp merge_coalesced_entries(%Entry{} = entry, []), do: entry

  defp merge_coalesced_entries(%Entry{} = entry, entries) do
    all_entries = [entry | entries]
    items = Enum.map(all_entries, &batch_item/1)
    text = items |> active_batch_items() |> batch_text()
    attention = effective_batch_attention(items)

    refs =
      all_entries
      |> Enum.flat_map(&(get_in(&1.cloud_event, ["data", "refs"]) || []))
      |> Enum.reject(&is_nil/1)

    source_fact = get_in(entry.cloud_event, ["data", "source_fact"]) || %{}

    data =
      entry.cloud_event
      |> get_in(["data"])
      |> Map.put(
        "content",
        coalesced_content(text, get_in(entry.cloud_event, ["data", "content"]))
      )
      |> Map.put("refs", refs)
      |> Map.put("im_batch", %{
        "effective_attention" => Atom.to_string(attention),
        "items" => items
      })
      |> put_batch_effective_attention(attention)
      |> Map.put(
        "source_fact",
        Map.merge(source_fact, %{
          "batch_mailbox_entry_ids" => Enum.map(all_entries, & &1.id),
          "coalesced_mailbox_entry_ids" => Enum.map(entries, & &1.id),
          "coalesced_event_ids" => Enum.map(entries, &get_in(&1.cloud_event, ["id"]))
        })
      )

    cloud_event =
      entry.cloud_event
      |> put_in(["data"], data)

    %{entry | attention: attention, cloud_event: cloud_event}
  end

  defp coalesced_content("", original_content), do: original_content || []
  defp coalesced_content(text, _original_content), do: [%{"type" => "text", "text" => text}]

  defp coalesce_actor_key(%Entry{} = entry) do
    data = get_in(entry.cloud_event, ["data"]) || %{}

    get_in(data, ["actor", "principal", "uid"]) ||
      get_in(data, ["actor", "external_account_id"]) ||
      get_in(data, ["actor", "id"]) ||
      ""
  end

  defp text_chars(%Entry{} = entry), do: String.length(entry_text(entry))

  defp entry_text(%Entry{} = entry) do
    entry.cloud_event
    |> get_in(["data", "content"])
    |> List.wrap()
    |> Enum.flat_map(&content_text/1)
    |> Enum.join("\n")
  end

  defp content_text(%{"type" => "text", "text" => text}) when is_binary(text), do: [text]
  defp content_text(%{"text" => text}) when is_binary(text), do: [text]
  defp content_text(_block), do: []

  defp batch_item(%Entry{} = entry) do
    data = get_in(entry.cloud_event, ["data"]) || %{}

    %{
      "mailbox_entry_id" => entry.id,
      "event_id" => get_in(entry.cloud_event, ["id"]),
      "event_source" => get_in(entry.cloud_event, ["source"]),
      "provider_message_ids" => source_message_ids(data),
      "attention" => Atom.to_string(entry_attention(entry)),
      "state" => "active",
      "text" => entry_text(entry),
      "content" => data["content"] || [],
      "refs" => data["refs"] || [],
      "raw_ref" => data["raw_ref"],
      "routing_facts" => data["routing_facts"] || %{},
      "reply_address" => data["reply_address"]
    }
    |> reject_nil_values()
  end

  defp put_batch_effective_attention(data, attention) do
    Map.update(
      data,
      "routing_facts",
      %{"batch_effective_attention" => Atom.to_string(attention)},
      fn
        %{} = facts -> Map.put(facts, "batch_effective_attention", Atom.to_string(attention))
        _value -> %{"batch_effective_attention" => Atom.to_string(attention)}
      end
    )
  end

  defp active_batch_items(items) do
    Enum.filter(items, &(Map.get(&1, "state") == "active"))
  end

  defp batch_text(items) do
    items
    |> Enum.map(&(Map.get(&1, "text") || ""))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp effective_batch_attention(items) do
    case Enum.any?(active_batch_items(items), &(Map.get(&1, "attention") == "addressed")) do
      true -> :addressed
      false -> :ambient
    end
  end

  defp active_rules do
    DeliveryRule
    |> where([rule], rule.active == true)
    |> order_by([rule], asc: rule.priority, asc: rule.id)
    |> Repo.all()
  end

  defp match_rules(rules, context) do
    rules
    |> Enum.reduce_while({:ok, []}, fn rule, {:ok, acc} ->
      case Matcher.match([rule], context) do
        {:ok, {:matched, _id, _diagnostics}} -> {:cont, {:ok, [rule | acc]}}
        {:ok, {:no_match, _diagnostics}} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, matched} -> {:ok, Enum.reverse(matched)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rule_request(%DeliveryRule{} = rule, cloud_event) do
    %{
      cloud_event: cloud_event,
      agent_uid: rule.agent_uid,
      attention: event_attention(cloud_event),
      dedupe_key: rule.id
    }
  end

  defp normalize_request(request) do
    cloud_event = map_value(request, :cloud_event)
    attention = attention_value(map_value(request, :attention), cloud_event)
    now = utc_now()

    %{
      cloud_event: stringify!(cloud_event || %{}),
      agent_uid: string_value(map_value(request, :agent_uid)),
      attention: attention,
      session_key: session_key_value(map_value(request, :session_key), cloud_event),
      available_at:
        map_value(request, :available_at) ||
          DateTime.add(now, event_delay_ms(cloud_event), :millisecond),
      idempotency_key: idempotency_key(request, attention),
      metadata: maybe_stringify_map(map_value(request, :metadata)) || %{},
      now: now
    }
  end

  defp get_agent(%{agent_uid: agent_uid}) when is_binary(agent_uid) and agent_uid != "" do
    case Repo.get(Agent, agent_uid) do
      %Agent{} = agent -> {:ok, agent}
      nil -> {:error, :agent_not_found}
    end
  end

  defp get_agent(_attrs), do: {:error, :agent_uid_required}

  defp get_or_create_session(%Agent{} = agent, attrs) do
    case Repo.get_by(Session, agent_uid: agent.uid, session_key: attrs.session_key) do
      %Session{} = session ->
        session
        |> Session.changeset(%{last_entry_at: attrs.now})
        |> Repo.update()

      nil ->
        %Session{}
        |> Session.changeset(%{
          agent_uid: agent.uid,
          session_key: attrs.session_key,
          last_entry_at: attrs.now
        })
        |> Repo.insert()
        |> case do
          {:ok, session} -> {:ok, session}
          {:error, changeset} -> existing_session_after_conflict(changeset, agent, attrs)
        end
    end
  end

  defp existing_session_after_conflict(changeset, agent, attrs) do
    case unique_conflict?(changeset) do
      true ->
        case Repo.get_by(Session, agent_uid: agent.uid, session_key: attrs.session_key) do
          %Session{} = session -> {:ok, session}
          nil -> {:error, changeset}
        end

      false ->
        {:error, changeset}
    end
  end

  defp insert_entry(%Agent{} = agent, %Session{} = session, attrs) do
    %Entry{}
    |> Entry.changeset(%{
      agent_uid: agent.uid,
      mailbox_session_id: session.id,
      status: :pending,
      attention: attrs.attention,
      cloud_event: attrs.cloud_event,
      available_at: attrs.available_at,
      idempotency_key: attrs.idempotency_key,
      attempts: 0
    })
    |> Repo.insert()
    |> case do
      {:ok, entry} ->
        {:ok, Repo.preload(entry, [:agent, :session])}

      {:error, changeset} ->
        existing_entry_after_conflict(changeset, agent, session, attrs)
    end
  end

  defp existing_entry_after_conflict(changeset, agent, session, attrs) do
    case unique_conflict?(changeset) do
      true ->
        case Repo.get_by(Entry, agent_uid: agent.uid, idempotency_key: attrs.idempotency_key) do
          %Entry{} = entry ->
            {:duplicate, agent, session, Repo.preload(entry, [:agent, :session])}

          nil ->
            {:error, changeset}
        end

      false ->
        {:error, changeset}
    end
  end

  defp dispatch(%Entry{agent: %Agent{type: :ai_agent} = agent} = entry, opts) do
    holder = Keyword.get(opts, :holder, entry.lease_holder)

    invocation = %{
      target_ref: agent.uid,
      mailbox_session_id: entry.mailbox_session_id,
      mailbox_entry_id: entry.id,
      output: BullX.MailBox.StreamingOutput,
      close: fn -> :ok end,
      fail: fn reason -> mark_entry(entry, :failed, safe_error(reason), holder) end
    }

    BullX.AIAgent.handle_mailbox_entry(invocation, entry)
  end

  defp dispatch(%Entry{agent: %Agent{type: agent_type}}, _opts),
    do: {:error, {:unknown_agent_type, agent_type}}

  defp mark_entry(%Entry{} = entry, status, safe_error, holder) when is_binary(holder) do
    now = utc_now()

    {count, _rows} =
      Repo.update_all(
        from(mailbox_entry in Entry,
          where: mailbox_entry.id == ^entry.id and mailbox_entry.lease_holder == ^holder
        ),
        set: [
          status: status,
          safe_error: safe_error,
          lease_holder: nil,
          lease_expires_at: nil,
          updated_at: now
        ]
      )

    case count do
      1 -> :ok
      0 -> {:error, :stale_mailbox_entry_lease}
    end
  end

  defp mark_entry(%Entry{} = entry, status, safe_error, _holder) do
    entry
    |> Entry.changeset(%{status: status, safe_error: safe_error})
    |> Repo.update()
    |> case do
      {:ok, _entry} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp defer_entry(%Entry{} = entry, holder) when is_binary(holder) do
    now = utc_now()
    available_at = DateTime.add(now, @lifecycle_in_flight_retry_ms, :millisecond)

    {count, _rows} =
      Repo.update_all(
        from(mailbox_entry in Entry,
          where: mailbox_entry.id == ^entry.id and mailbox_entry.lease_holder == ^holder
        ),
        set: [
          status: :pending,
          available_at: available_at,
          lease_holder: nil,
          lease_expires_at: nil,
          updated_at: now
        ]
      )

    case count do
      1 ->
        Dispatcher.wake(@lifecycle_in_flight_retry_ms)
        :ok

      0 ->
        {:error, :stale_mailbox_entry_lease}
    end
  end

  defp mark_entries([], _status, _safe_error, _holder), do: :ok

  defp mark_entries(entries, status, safe_error, holder) when is_binary(holder) do
    ids = Enum.map(entries, & &1.id)
    now = utc_now()

    {count, _rows} =
      Repo.update_all(
        from(mailbox_entry in Entry,
          where: mailbox_entry.id in ^ids and mailbox_entry.lease_holder == ^holder
        ),
        set: [
          status: status,
          safe_error: safe_error,
          lease_holder: nil,
          lease_expires_at: nil,
          updated_at: now
        ]
      )

    case count == length(ids) do
      true -> :ok
      false -> {:error, :stale_mailbox_entry_lease}
    end
  end

  defp mark_entries(entries, status, safe_error, _holder) do
    entries
    |> Enum.map(&mark_entry(&1, status, safe_error, nil))
    |> Enum.find(:ok, &match?({:error, _reason}, &1))
  end

  defp release_entries([], _holder), do: :ok

  defp release_entries(entries, holder) when is_binary(holder) do
    ids = Enum.map(entries, & &1.id)
    now = utc_now()

    Repo.update_all(
      from(mailbox_entry in Entry,
        where: mailbox_entry.id in ^ids and mailbox_entry.lease_holder == ^holder
      ),
      set: [status: :pending, lease_holder: nil, lease_expires_at: nil, updated_at: now]
    )

    :ok
  end

  defp release_entries(_entries, _holder), do: :ok

  defp routing_context(%{
         "id" => id,
         "source" => source,
         "type" => type,
         "time" => time,
         "data" => data
       }) do
    %{
      "source" => source,
      "type" => type,
      "time" => time,
      "data" => data,
      "event" => %{
        "id" => id,
        "identity" => %{"source" => source, "id" => id}
      },
      "channel" => data["channel"],
      "scope" => data["scope"],
      "actor" => data["actor"],
      "refs" => data["refs"],
      "reply_address" => data["reply_address"],
      "routing_facts" => data["routing_facts"]
    }
  end

  defp routing_context(_event), do: %{}

  defp default_session_key(%{"data" => %{"queue_key" => queue_key}})
       when is_binary(queue_key) and queue_key != "",
       do: queue_key

  defp default_session_key(%{"subject" => subject}) when is_binary(subject) and subject != "",
    do: subject

  defp default_session_key(%{"source" => source, "id" => id}) do
    [source, id]
    |> Enum.map(&to_string/1)
    |> Enum.join("#")
  end

  defp default_session_key(_cloud_event), do: "default"

  defp session_key_value(value, _cloud_event) when is_binary(value) and value != "", do: value
  defp session_key_value(_value, cloud_event), do: default_session_key(cloud_event || %{})

  defp attention_value(value, _cloud_event) when is_atom(value) and value in @attention, do: value

  defp attention_value("addressed", _cloud_event), do: :addressed
  defp attention_value("ambient", _cloud_event), do: :ambient
  defp attention_value("command", _cloud_event), do: :command
  defp attention_value("action", _cloud_event), do: :action
  defp attention_value("lifecycle", _cloud_event), do: :lifecycle
  defp attention_value("system", _cloud_event), do: :system
  defp attention_value(_value, cloud_event), do: event_attention(cloud_event || %{})

  defp idempotency_key(request, attention) do
    request
    |> idempotency_material(attention)
    |> Jason.encode!()
    |> BullX.Ext.generic_hash()
  end

  defp idempotency_material(request, attention) do
    cloud_event = map_value(request, :cloud_event) || %{}
    dedupe_key = map_value(request, :dedupe_key)

    %{
      agent_uid: map_value(request, :agent_uid),
      source: map_value(cloud_event, :source),
      id: map_value(cloud_event, :id),
      attention: attention,
      dedupe_key: dedupe_key || [map_value(cloud_event, :source), map_value(cloud_event, :id)]
    }
  end

  defp unique_conflict?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {_field, {_message, opts}} -> Keyword.get(opts, :constraint) == :unique
    end)
  end

  defp stringify!(value) do
    case BullX.JSON.stringify_keys(value) do
      {:ok, normalized} -> normalized
      :error -> value
    end
  end

  defp maybe_stringify_map(nil), do: nil
  defp maybe_stringify_map(%{} = value), do: stringify!(value)
  defp maybe_stringify_map(_value), do: nil

  defp map_value(%{} = map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(%{} = map, key) when is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp map_value(_value, _key), do: nil

  defp string_value(value) when is_binary(value), do: String.trim(value)
  defp string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp string_value(value), do: to_string(value)

  defp integer_value(value, _default) when is_integer(value), do: value
  defp integer_value(_value, default), do: default

  defp event_delay_ms(%{"type" => "bullx.message.received"} = cloud_event) do
    cloud_event
    |> get_in(["data", "coalesce", "window_ms"])
    |> integer_value(0)
  end

  defp event_delay_ms(_cloud_event), do: 0

  defp event_attention(%{"type" => "bullx.command.invoked"}), do: :command
  defp event_attention(%{"type" => "bullx.agent.abort"}), do: :command

  defp event_attention(%{"type" => type})
       when type in ["bullx.message.edited", "bullx.message.recalled", "bullx.message.deleted"],
       do: :lifecycle

  defp event_attention(%{"type" => "bullx.message.received", "data" => data})
       when is_map(data),
       do: received_attention(data)

  defp event_attention(_cloud_event), do: :system

  defp received_attention(%{"routing_facts" => %{} = facts} = data) do
    reason = string_value(facts["attention_reason"])

    cond do
      reason in @addressed_attention_reasons -> :addressed
      is_binary(facts["command_name"]) -> :addressed
      channel_kind(data) in ["dm", "direct"] -> :addressed
      reason == "unaddressed" -> :ambient
      true -> :addressed
    end
  end

  defp received_attention(data) when is_map(data) do
    case channel_kind(data) in ["dm", "direct"] do
      true -> :addressed
      false -> :addressed
    end
  end

  defp channel_kind(%{"channel" => %{} = channel}), do: string_value(channel["kind"])
  defp channel_kind(_data), do: ""

  defp entry_attention(%Entry{attention: attention}) when attention in @attention, do: attention
  defp entry_attention(%Entry{cloud_event: cloud_event}), do: event_attention(cloud_event || %{})

  defp source_message_ids(data) when is_map(data) do
    [
      ref_message_ids(data["refs"]),
      raw_ref_message_ids(data["raw_ref"])
    ]
    |> List.flatten()
    |> Enum.map(&string_value/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp source_message_ids(_data), do: []

  defp ref_message_ids(refs) when is_list(refs) do
    refs
    |> Enum.flat_map(fn
      %{"kind" => kind, "id" => id} when is_binary(kind) and is_binary(id) ->
        ref_message_id(kind, id)

      _ref ->
        []
    end)
  end

  defp ref_message_ids(_refs), do: []

  defp ref_message_id(kind, id) do
    case String.contains?(kind, "message") do
      true -> [id]
      false -> []
    end
  end

  defp raw_ref_message_ids(%{"message_id" => message_id}), do: [message_id]
  defp raw_ref_message_ids(_raw_ref), do: []

  defp reject_nil_values(map),
    do: Map.reject(map, fn {_key, value} -> is_nil(value) or value == "" end)

  defp earliest_datetime(datetimes) do
    datetimes
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      [datetime | rest] -> Enum.reduce(rest, datetime, &earlier_datetime/2)
    end
  end

  defp earlier_datetime(left, right) do
    case DateTime.compare(left, right) do
      :lt -> left
      _gte -> right
    end
  end

  defp safe_error(reason) do
    %{"reason" => inspect(reason, limit: 6)}
  end

  defp default_holder do
    "#{node()}:#{inspect(self())}"
  end

  defp wake_delivery(%{status: :duplicate}), do: :ok

  defp wake_delivery(%{entry: %Entry{} = entry}) do
    case control_entry?(entry) do
      true -> SessionWorker.start_entry_id(entry.id)
      false -> wake_dispatcher(%{entry: maybe_flush_full_coalesce_batch(entry)})
    end
  end

  defp maybe_flush_full_coalesce_batch(%Entry{} = entry) do
    case coalesce_config(entry) do
      {:ok, _window_ms, max_chars} ->
        flush_full_coalesce_batch(entry, max_chars)

      :skip ->
        entry
    end
  end

  defp flush_full_coalesce_batch(%Entry{} = entry, max_chars) do
    actor_key = coalesce_actor_key(entry)

    pending_entries =
      Entry
      |> where([candidate], candidate.mailbox_session_id == ^entry.mailbox_session_id)
      |> where([candidate], candidate.status == :pending)
      |> where(
        [candidate],
        fragment("?->>'type' = 'bullx.message.received'", candidate.cloud_event)
      )
      |> order_by([candidate], asc: candidate.entry_seq)
      |> Repo.all()
      |> Enum.filter(&(coalesce_actor_key(&1) == actor_key))

    total_chars = pending_entries |> Enum.map(&text_chars/1) |> Enum.sum()

    case total_chars >= max_chars do
      true ->
        now = utc_now()
        ids = Enum.map(pending_entries, & &1.id)

        Repo.update_all(from(candidate in Entry, where: candidate.id in ^ids),
          set: [available_at: now]
        )

        %{entry | available_at: now}

      false ->
        entry
    end
  end

  defp wake_dispatcher(%{entry: %Entry{} = entry}) do
    Dispatcher.wake(wake_delay_ms(entry))
  end

  defp control_entry?(%Entry{cloud_event: %{"type" => type}}), do: type in @control_event_types
  defp control_entry?(_entry), do: false

  defp wake_delay_ms(%Entry{available_at: %DateTime{} = available_at}) do
    available_at
    |> DateTime.diff(utc_now(), :millisecond)
    |> max(0)
  end

  defp utc_now, do: DateTime.utc_now(:microsecond)
end
