defmodule BullX.MailBox do
  @moduledoc """
  Internal CloudEvents mail delivery window.

  MailBox owns receiver delivery entries and short processing sessions. It does
  not own IM messages, conversations, workflow runs, or outbound provider facts.
  """

  import Ecto.Query

  alias BullX.MailBox.Dispatcher
  alias BullX.MailBox.Matcher
  alias BullX.MailBox.{DeliveryRule, Entry, Session}
  alias BullX.Principals.Agent
  alias BullX.Repo

  @lease_seconds 60
  @default_claim_limit 10
  @attention [:addressed, :ambient, :command, :action, :lifecycle, :system]

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
        wake_dispatcher(result)
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec deliver_many([map()], keyword()) :: [deliver_result()]
  def deliver_many(requests, opts \\ []) when is_list(requests) do
    Enum.map(requests, &deliver(&1, opts))
  end

  @spec claim_ready(pos_integer(), keyword()) :: {:ok, [Entry.t()]} | {:error, term()}
  def claim_ready(limit \\ @default_claim_limit, opts \\ [])
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
        |> order_by([entry], asc: entry.entry_seq)
        |> limit(^limit)
        |> lock("FOR UPDATE SKIP LOCKED")
        |> Repo.all()

      ids = Enum.map(entries, & &1.id)

      case ids do
        [] ->
          []

        [_ | _] ->
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

    case dispatch(entry, opts) do
      :ok -> mark_entry(entry, :processed, nil)
      {:error, reason} -> mark_entry(entry, :failed, safe_error(reason))
    end
  end

  @spec process_ready(pos_integer(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def process_ready(limit \\ @default_claim_limit, opts \\ []) do
    with {:ok, entries} <- claim_ready(limit, opts) do
      entries
      |> Enum.each(&process_entry(&1, opts))
      |> then(fn _ignored -> {:ok, length(entries)} end)
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
      attention: rule.attention,
      session_key: render_template(rule.session_key_template, cloud_event),
      available_delay_ms: rule.available_delay_ms,
      coalesce_key: render_template(rule.coalesce_key_template, cloud_event),
      reply_address: get_in(cloud_event, ["data", "reply_address"]),
      dedupe_key: rule.id
    }
  end

  defp normalize_request(request) do
    cloud_event = map_value(request, :cloud_event)
    available_delay_ms = integer_value(map_value(request, :available_delay_ms), 0)
    now = utc_now()

    %{
      cloud_event: stringify!(cloud_event || %{}),
      agent_uid: string_value(map_value(request, :agent_uid)),
      attention: attention_value(map_value(request, :attention)),
      session_key: session_key_value(map_value(request, :session_key), cloud_event),
      reply_address: maybe_stringify_map(map_value(request, :reply_address)),
      available_at:
        map_value(request, :available_at) ||
          DateTime.add(now, available_delay_ms, :millisecond),
      dedupe_hash: dedupe_hash(request),
      coalesce_key: string_or_nil(map_value(request, :coalesce_key)),
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
          status: :active,
          last_entry_at: attrs.now,
          metadata: %{}
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
      reply_address: attrs.reply_address,
      available_at: attrs.available_at,
      dedupe_hash: attrs.dedupe_hash,
      coalesce_key: attrs.coalesce_key,
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
        case Repo.get_by(Entry, agent_uid: agent.uid, dedupe_hash: attrs.dedupe_hash) do
          %Entry{} = entry ->
            {:duplicate, agent, session, Repo.preload(entry, [:agent, :session])}

          nil ->
            {:error, changeset}
        end

      false ->
        {:error, changeset}
    end
  end

  defp dispatch(%Entry{agent: %Agent{type: :ai_agent} = agent} = entry, _opts) do
    invocation = %{
      target_ref: agent.uid,
      mailbox_session_id: entry.mailbox_session_id,
      mailbox_entry_id: entry.id,
      output: BullX.MailBox.StreamingOutput,
      close: fn -> :ok end,
      fail: fn reason -> mark_entry(entry, :failed, safe_error(reason)) end
    }

    BullX.AIAgent.handle_mailbox_entry(invocation, entry)
  end

  defp dispatch(%Entry{agent: %Agent{type: :blackhole}}, _opts), do: :ok

  defp dispatch(%Entry{agent: %Agent{type: agent_type}}, _opts),
    do: {:error, {:unknown_agent_type, agent_type}}

  defp mark_entry(%Entry{} = entry, status, safe_error) do
    entry
    |> Entry.changeset(%{
      status: status,
      safe_error: safe_error,
      lease_holder: nil,
      lease_expires_at: nil
    })
    |> Repo.update()
    |> case do
      {:ok, _entry} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

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

  defp render_template(nil, cloud_event), do: default_session_key(cloud_event)
  defp render_template("", cloud_event), do: default_session_key(cloud_event)
  defp render_template(template, _cloud_event) when is_binary(template), do: template

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

  defp attention_value(value) when is_atom(value) and value in @attention, do: value

  defp attention_value("addressed"), do: :addressed
  defp attention_value("ambient"), do: :ambient
  defp attention_value("command"), do: :command
  defp attention_value("action"), do: :action
  defp attention_value("lifecycle"), do: :lifecycle
  defp attention_value("system"), do: :system
  defp attention_value(_value), do: :system

  defp dedupe_hash(request) do
    request
    |> dedupe_material()
    |> Jason.encode!()
    |> BullX.Ext.generic_hash()
  end

  defp dedupe_material(request) do
    cloud_event = map_value(request, :cloud_event) || %{}
    dedupe_key = map_value(request, :dedupe_key)

    %{
      agent_uid: map_value(request, :agent_uid),
      source: map_value(cloud_event, :source),
      id: map_value(cloud_event, :id),
      attention: map_value(request, :attention),
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

  defp string_or_nil(nil), do: nil
  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(value), do: to_string(value)

  defp integer_value(value, _default) when is_integer(value), do: value
  defp integer_value(_value, default), do: default

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

  defp wake_dispatcher(%{entry: %Entry{} = entry}) do
    Dispatcher.wake(wake_delay_ms(entry))
  end

  defp wake_delay_ms(%Entry{available_at: %DateTime{} = available_at}) do
    available_at
    |> DateTime.diff(utc_now(), :millisecond)
    |> max(0)
  end

  defp utc_now, do: DateTime.utc_now(:microsecond)
end
