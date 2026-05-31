defmodule BullX.MailBox do
  @moduledoc """
  Internal CloudEvents mail delivery window.

  MailBox stores accepted pending mail in PostgreSQL and keeps scheduling state
  in `BullX.MailBox.Runtime`. The persisted rows are intentionally small: they
  are enough to rebuild runtime queues after an Elixir process crash, but they
  do not encode timers, leases, or coalesce pressure.
  """

  import Ecto.Query

  alias BullX.AIAgent.Message, as: ConversationMessage
  alias BullX.MailBox.{AcceptanceKey, DeliveryRule, Entry, Matcher, Runtime}
  alias BullX.Principals.Agent
  alias BullX.Repo

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
  @active_rules_cache_key {__MODULE__, :active_rules}
  @default_active_rules_cache_ttl_ms 1_000

  @type deliver_result ::
          {:ok, %{agent: Agent.t(), queue_key: String.t(), entry: Entry.t() | nil}}
          | {:ok,
             %{
               status: :duplicate,
               agent: Agent.t(),
               queue_key: String.t(),
               entry: Entry.t() | nil
             }}
          | {:error, term()}

  @type route_result ::
          {:ok, %{agent: Agent.t(), queue_key: String.t(), entry: Entry.t() | nil}}
          | {:ok,
             %{
               status: :duplicate,
               agent: Agent.t(),
               queue_key: String.t(),
               entry: Entry.t() | nil
             }}

  @spec route(map(), keyword()) :: {:ok, [route_result()]} | {:error, term()}
  def route(cloud_event, opts \\ []) when is_map(cloud_event) and is_list(opts) do
    context = routing_context(cloud_event)
    rules = active_rules()

    with {:ok, matched_rules} <- match_rules(rules, context) do
      matched_rules
      |> Enum.map(&deliver(rule_request(&1, cloud_event), opts))
      |> route_delivery_results()
    end
  end

  @spec invalidate_delivery_rule_cache() :: :ok
  def invalidate_delivery_rule_cache do
    :persistent_term.erase(@active_rules_cache_key)
    :ok
  end

  @spec deliver(map(), keyword()) :: deliver_result()
  def deliver(request, _opts \\ []) when is_map(request) do
    attrs = normalize_request(request)

    Repo.transaction(fn ->
      case get_agent(attrs) do
        {:ok, agent} -> accept_entry(agent, attrs)
        {:error, reason} -> Repo.rollback(reason)
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

  @spec process_ready(pos_integer(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def process_ready(limit \\ @default_claim_limit, opts \\ [])
      when is_integer(limit) and limit > 0 and is_list(opts) do
    Runtime.process_ready(limit, opts)
  end

  @spec next_ready_at() :: DateTime.t() | nil
  def next_ready_at, do: Runtime.next_ready_at()

  @spec rebuild_runtime() :: :ok | {:error, term()}
  def rebuild_runtime, do: Runtime.reload()

  @spec force_ready() :: :ok
  def force_ready, do: Runtime.force_ready()

  @spec control_event_type?(String.t()) :: boolean()
  def control_event_type?(type) when is_binary(type), do: type in @control_event_types
  def control_event_type?(_type), do: false

  @spec process_entry(Entry.t(), keyword()) :: :ok | {:error, term()}
  def process_entry(%Entry{} = entry, opts \\ []) when is_list(opts) do
    result = process_entry_result(entry, opts)
    Runtime.complete(entry.id, result)
    public_process_result(result)
  end

  @doc false
  @spec process_entry_result(Entry.t(), keyword()) :: Runtime.process_result()
  def process_entry_result(%Entry{} = entry, opts \\ []) when is_list(opts) do
    entry = Repo.preload(entry, [:agent])

    case maybe_apply_lifecycle_to_pending_receive(entry) do
      {:updated, %Entry{} = updated_target} ->
        Runtime.replace_entry(updated_target)
        delete_entries([entry.id])

      {:deleted, target_id} ->
        delete_entries([entry.id, target_id])

      :defer ->
        {:defer, @lifecycle_in_flight_retry_ms}

      :continue ->
        process_dispatch_entry(entry, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec process_entry_by_id(String.t(), keyword()) :: :ok | {:error, term()}
  def process_entry_by_id(entry_id, opts \\ []) when is_binary(entry_id) and is_list(opts) do
    case Repo.get(Entry, entry_id) do
      %Entry{} = entry -> process_entry(entry, opts)
      nil -> {:error, :entry_not_found}
    end
  end

  defp public_process_result({:ok, _ids}), do: :ok
  defp public_process_result({:defer, _delay_ms}), do: :ok
  defp public_process_result({:error, reason}), do: {:error, reason}

  defp process_dispatch_entry(%Entry{} = entry, opts) do
    {entry, coalesced_entries} = coalesce_entry(entry)
    Runtime.mark_in_flight(coalesced_entries, entry.queue_key)
    ids = Enum.map([entry | coalesced_entries], & &1.id)

    case dispatch(entry, opts) do
      :ok ->
        delete_entries(ids)

      {:error, _reason} ->
        delete_entries(ids)
    end
  end

  defp accept_entry(%Agent{} = agent, attrs) do
    entry_id = BullX.Ext.gen_uuid_v7()

    case insert_acceptance_key(agent, attrs, entry_id) do
      :inserted ->
        insert_entry(agent, attrs, entry_id)

      :duplicate ->
        existing_accepted(agent, attrs)
    end
  end

  defp insert_acceptance_key(%Agent{} = agent, attrs, entry_id) do
    row = %{
      id: BullX.Ext.gen_uuid_v7(),
      agent_uid: agent.uid,
      idempotency_key: attrs.idempotency_key,
      entry_id: entry_id,
      accepted_at: attrs.now,
      inserted_at: attrs.now
    }

    case Repo.insert_all(AcceptanceKey, [row],
           on_conflict: :nothing,
           conflict_target: [:agent_uid, :idempotency_key]
         ) do
      {1, _rows} -> :inserted
      {0, _rows} -> :duplicate
    end
  end

  defp insert_entry(%Agent{} = agent, attrs, entry_id) do
    %Entry{id: entry_id}
    |> Entry.changeset(%{
      agent_uid: agent.uid,
      queue_key: attrs.queue_key,
      attention: attrs.attention,
      cloud_event: attrs.cloud_event,
      idempotency_key: attrs.idempotency_key
    })
    |> Repo.insert()
    |> case do
      {:ok, entry} ->
        %{agent: agent, queue_key: attrs.queue_key, entry: Repo.preload(entry, [:agent])}

      {:error, changeset} ->
        case existing_entry_after_conflict(changeset, agent, attrs) do
          {:duplicate, result} -> result
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp existing_accepted(agent, attrs) do
    entry =
      AcceptanceKey
      |> Repo.get_by(agent_uid: agent.uid, idempotency_key: attrs.idempotency_key)
      |> pending_entry_for_key(agent, attrs)

    %{status: :duplicate, agent: agent, queue_key: attrs.queue_key, entry: entry}
  end

  defp existing_entry_after_conflict(changeset, agent, attrs) do
    case unique_conflict?(changeset) do
      true ->
        entry = Repo.get_by(Entry, agent_uid: agent.uid, idempotency_key: attrs.idempotency_key)

        {:duplicate,
         %{status: :duplicate, agent: agent, queue_key: attrs.queue_key, entry: entry}}

      false ->
        {:error, changeset}
    end
  end

  defp pending_entry_for_key(nil, _agent, _attrs), do: nil

  defp pending_entry_for_key(%AcceptanceKey{entry_id: entry_id}, agent, attrs) do
    Repo.get(Entry, entry_id) ||
      Repo.get_by(Entry, agent_uid: agent.uid, idempotency_key: attrs.idempotency_key)
  end

  defp delete_entries(ids) do
    ids =
      ids
      |> List.wrap()
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case ids do
      [] ->
        {:ok, []}

      [_ | _] ->
        Repo.delete_all(from(entry in Entry, where: entry.id in ^ids))
        {:ok, ids}
    end
  end

  defp dispatch(%Entry{agent: %Agent{type: :ai_agent} = agent} = entry, _opts) do
    invocation = %{
      target_ref: agent.uid,
      mailbox_queue_key: entry.queue_key,
      mailbox_entry_id: entry.id,
      output: BullX.MailBox.StreamingOutput,
      close: fn -> :ok end,
      fail: fn _reason -> :ok end
    }

    BullX.AIAgent.handle_mailbox_entry(invocation, entry)
  end

  defp dispatch(%Entry{agent: %Agent{type: agent_type}}, _opts),
    do: {:error, {:unknown_agent_type, agent_type}}

  defp maybe_apply_lifecycle_to_pending_receive(%Entry{
         agent_uid: agent_uid,
         queue_key: queue_key,
         cloud_event: %{"type" => type, "data" => %{} = data}
       })
       when type in ["bullx.message.edited", "bullx.message.recalled", "bullx.message.deleted"] do
    case source_message_ids(data) do
      [] ->
        :continue

      target_ids ->
        case receive_for_lifecycle(agent_uid, queue_key, target_ids) do
          %Entry{} = target ->
            apply_or_defer_lifecycle(agent_uid, queue_key, target_ids, target, type, data)

          nil ->
            :continue
        end
    end
  end

  defp maybe_apply_lifecycle_to_pending_receive(_entry), do: :continue

  defp apply_or_defer_lifecycle(agent_uid, queue_key, target_ids, %Entry{} = target, type, data) do
    case Runtime.in_flight?(target.id) do
      true ->
        case lifecycle_target_materialized?(agent_uid, queue_key, target_ids, target) do
          true -> :continue
          false -> :defer
        end

      false ->
        apply_lifecycle_to_pending_receive(target, type, data)
    end
  end

  defp receive_for_lifecycle(agent_uid, queue_key, target_ids) do
    target_set = MapSet.new(target_ids)

    Entry
    |> where([entry], entry.agent_uid == ^agent_uid)
    |> where([entry], entry.queue_key == ^queue_key)
    |> where([entry], fragment("?->>'type' = 'bullx.message.received'", entry.cloud_event))
    |> order_by([entry], asc: entry.entry_seq)
    |> limit(100)
    |> Repo.all()
    |> Enum.find(fn entry ->
      entry
      |> get_in([Access.key(:cloud_event), "data"])
      |> source_message_ids()
      |> Enum.any?(&MapSet.member?(target_set, &1))
    end)
  end

  defp lifecycle_target_materialized?(agent_uid, queue_key, target_ids, %Entry{} = target) do
    target_set = MapSet.new(target_ids)

    ConversationMessage
    |> where([message], message.agent_uid == ^agent_uid)
    |> where([message], message.mailbox_queue_key == ^queue_key)
    |> where([message], message.role in [:user, :im_ambient])
    |> where([message], message.kind == :normal)
    |> where([message], is_nil(fragment("?->'transcript_effect'", message.metadata)))
    |> order_by([message], desc: message.inserted_at)
    |> limit(100)
    |> Repo.all()
    |> Enum.any?(&materialized_target?(&1, target.id, target_set))
  end

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
      {:ok, entry} -> {:updated, entry}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp apply_lifecycle_to_pending_receive(%Entry{} = target, type, _data)
       when type in ["bullx.message.recalled", "bullx.message.deleted"],
       do: {:deleted, target.id}

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

  defp coalesce_entry(%Entry{} = entry) do
    case coalesce_config(entry) do
      {:ok, window_ms, max_chars} ->
        entries = coalesced_entries(entry, window_ms, max_chars)
        {merge_coalesced_entries(entry, entries), entries}

      :skip ->
        {entry, []}
    end
  end

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

  defp coalesced_entries(%Entry{} = entry, window_ms, max_chars) do
    actor_key = coalesce_actor_key(entry)
    base_chars = text_chars(entry)
    window_until = DateTime.add(entry.inserted_at, window_ms, :millisecond)

    Entry
    |> where([candidate], candidate.agent_uid == ^entry.agent_uid)
    |> where([candidate], candidate.queue_key == ^entry.queue_key)
    |> where([candidate], candidate.entry_seq > ^entry.entry_seq)
    |> where([candidate], candidate.inserted_at <= ^window_until)
    |> where(
      [candidate],
      fragment("?->>'type' = 'bullx.message.received'", candidate.cloud_event)
    )
    |> order_by([candidate], asc: candidate.entry_seq)
    |> limit(50)
    |> Repo.all()
    |> Enum.reject(&Runtime.in_flight?(&1.id))
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
          "coalesced_event_ids" => Enum.map(entries, &get_in(&1.cloud_event, ["id"]))
        })
      )

    cloud_event = put_in(entry.cloud_event, ["data"], data)
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
    now_ms = System.monotonic_time(:millisecond)
    ttl_ms = active_rules_cache_ttl_ms()

    case cached_active_rules(now_ms, ttl_ms) do
      {:ok, rules} -> rules
      :miss -> load_active_rules(now_ms, ttl_ms)
    end
  end

  defp cached_active_rules(_now_ms, ttl_ms) when ttl_ms <= 0, do: :miss

  defp cached_active_rules(now_ms, _ttl_ms) do
    case :persistent_term.get(@active_rules_cache_key, :miss) do
      {expires_at_ms, rules} when expires_at_ms > now_ms -> {:ok, rules}
      _other -> :miss
    end
  end

  defp load_active_rules(now_ms, ttl_ms) do
    rules = query_active_rules()
    cache_active_rules(rules, now_ms, ttl_ms)
    rules
  end

  defp query_active_rules do
    DeliveryRule
    |> where([rule], rule.active == true)
    |> order_by([rule], asc: rule.priority, asc: rule.id)
    |> Repo.all()
  end

  defp cache_active_rules(_rules, _now_ms, ttl_ms) when ttl_ms <= 0, do: :ok

  defp cache_active_rules(rules, now_ms, ttl_ms) do
    :persistent_term.put(@active_rules_cache_key, {now_ms + ttl_ms, rules})
  end

  defp active_rules_cache_ttl_ms do
    :bullx
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:active_rules_cache_ttl_ms, default_active_rules_cache_ttl_ms())
    |> normalize_cache_ttl_ms()
  end

  defp default_active_rules_cache_ttl_ms do
    case Code.ensure_loaded?(Mix) and Mix.env() == :test do
      true -> 0
      false -> @default_active_rules_cache_ttl_ms
    end
  rescue
    _reason -> @default_active_rules_cache_ttl_ms
  end

  defp normalize_cache_ttl_ms(value) when is_integer(value) and value >= 0, do: value
  defp normalize_cache_ttl_ms(_value), do: @default_active_rules_cache_ttl_ms

  defp match_rules(rules, context) do
    case Matcher.match_all(rules, context) do
      {:ok, {:matched, rule_ids, _diagnostics}} -> {:ok, matched_rules(rules, rule_ids)}
      {:ok, {:no_match, _diagnostics}} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp matched_rules(rules, rule_ids) do
    rules_by_id = Map.new(rules, &{&1.id, &1})
    Enum.map(rule_ids, &Map.fetch!(rules_by_id, &1))
  end

  defp route_delivery_results(results) do
    case Enum.filter(results, &match?({:error, _reason}, &1)) do
      [] -> {:ok, results}
      failures -> {:error, {:delivery_failed, failures}}
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
      queue_key:
        queue_key_value(
          map_value(request, :queue_key) || map_value(request, :session_key),
          cloud_event
        ),
      idempotency_key: idempotency_key(request, attention),
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

  defp default_queue_key(%{"data" => %{"queue_key" => queue_key}})
       when is_binary(queue_key) and queue_key != "",
       do: queue_key

  defp default_queue_key(%{"subject" => subject}) when is_binary(subject) and subject != "",
    do: subject

  defp default_queue_key(%{"source" => source, "id" => id}) do
    [source, id]
    |> Enum.map(&to_string/1)
    |> Enum.join("#")
  end

  defp default_queue_key(_cloud_event), do: "default"

  defp queue_key_value(value, _cloud_event) when is_binary(value) and value != "", do: value
  defp queue_key_value(_value, cloud_event), do: default_queue_key(cloud_event || %{})

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
  defp string_value(nil), do: ""
  defp string_value(value), do: to_string(value)

  defp integer_value(value, _default) when is_integer(value), do: value
  defp integer_value(_value, default), do: default

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

  defp wake_delivery(%{entry: %Entry{} = entry}), do: Runtime.accepted(entry)
  defp wake_delivery(_result), do: :ok

  defp utc_now, do: DateTime.utc_now(:microsecond)
end
