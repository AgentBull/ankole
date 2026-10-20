defmodule Ankole.Conversations.Context do
  @moduledoc "Renders public Messages for conversation history and ambient observation."
  import Ecto.Query
  alias Ankole.Conversations.{Message, ExternalMessageRef}
  alias Ankole.Repo

  @ambient_rows 80
  @backdrop_rows 10
  @history_rows 200
  @history_tokens 8_000

  defp observations(conversation_id) do
    from message in Message,
      left_join: ref in ExternalMessageRef,
      on: ref.message_id == message.id and ref.tenant_id == message.tenant_id,
      where: message.conversation_id == ^conversation_id,
      select: %{message: message, external_ref: ref}
  end

  def ambient_scene_fingerprint(repo, conversation_id) do
    observations(conversation_id)
    |> order_by([message], desc: message.seq)
    |> limit(@ambient_rows)
    |> repo.all()
    |> Enum.reverse()
    |> Enum.map(fn row ->
      {row.message.id, row.message.seq, row.message.text,
       if(row.external_ref, do: row.external_ref.content_hash)}
    end)
    |> Ankole.Attrs.digest()
  end

  def history_page(conversation_id, opts) do
    cursor =
      case Integer.parse(Keyword.get(opts, :cursor) || "0") do
        {seq, ""} when seq >= 0 -> seq
        _ -> 0
      end

    query =
      observations(conversation_id)
      |> where([message], message.seq > ^cursor)
      |> order_by([message], asc: message.seq)
      |> limit(@history_rows + 1)

    query =
      Enum.reduce(opts, query, fn
        {:since, %DateTime{} = at}, query ->
          where(query, [message], message.created_at >= ^at)

        {:until, %DateTime{} = at}, query ->
          where(query, [message], message.created_at <= ^at)

        {:query, text}, query when is_binary(text) ->
          where(
            query,
            [message],
            fragment("strpos(lower(COALESCE(?, '')), lower(?)) > 0", message.text, ^text)
          )

        _, query ->
          query
      end)

    rows = Repo.all(query)

    accepted =
      Enum.reduce_while(Enum.take(rows, @history_rows), {[], 0}, fn row, {accepted, tokens} ->
        visible = observed_message(row)
        count = Ankole.Kernel.estimate_o200k_base_tokens(visible["text"] || "")

        if accepted == [] or tokens + count <= @history_tokens,
          do: {:cont, {[{row, visible} | accepted], tokens + count}},
          else: {:halt, {accepted, tokens}}
      end)
      |> elem(0)
      |> Enum.reverse()

    next =
      if length(rows) > length(accepted) and accepted != [],
        do: accepted |> List.last() |> elem(0) |> then(&to_string(&1.message.seq))

    %{messages: Enum.map(accepted, &elem(&1, 1)), next_cursor: next}
  end

  def ambient_delta_messages(%{conversation_id: id} = attrs, entries, judged_until)
      when is_binary(id) do
    query =
      observations(id)
      |> after_time(judged_until)
      |> order_by([message], desc: message.seq)
      |> limit(@ambient_rows)

    Repo.all(query)
    |> Enum.reverse()
    |> Enum.map(&observed_message(&1, attrs.provider_thread_id))
    |> Kernel.++(batch_observed_messages(entries))
    |> dedupe()
    |> Enum.sort_by(&sort_key/1)
    |> Enum.take(-@ambient_rows)
  end

  def ambient_delta_messages(_attrs, entries, _cursor), do: batch_observed_messages(entries)

  def ambient_backdrop_messages(%{conversation_id: id} = attrs, %DateTime{} = until)
      when is_binary(id) do
    observations(id)
    |> where([message], message.created_at <= ^until)
    |> order_by([message], desc: message.seq)
    |> limit(@backdrop_rows)
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.map(&observed_message(&1, attrs.provider_thread_id))
  end

  def ambient_backdrop_messages(_attrs, _cursor), do: []

  def batch_observed_messages(entries) do
    Enum.flat_map(entries, fn entry ->
      text = value(entry, :text)
      time = value(entry, :sent_at) || value(entry, :time)

      if is_binary(text) and is_binary(time) do
        author = value(entry, :author) || %{}
        id = value(entry, :message_id) || value(entry, :id)

        [
          %{
            "id" => id,
            "message_id" => id,
            "source" => "conversation",
            "kind" => "normal",
            "role" => if(value(author, :agent_uid), do: "agent", else: "human"),
            "speaker" => speaker_name(author),
            "sent_at" => time,
            "text" => text,
            "conversation_id" => value(entry, :conversation_id),
            "provider_message_id" => value(entry, :provider_message_id),
            "provider_thread_id" => value(entry, :provider_thread_id)
          }
        ]
      else
        []
      end
    end)
  end

  def unreplied_messages(%{conversation_id: id} = attrs, entries) when is_binary(id) do
    current_ids = Enum.map(entries, &value(&1, :message_id)) |> Enum.filter(&is_binary/1)

    rows =
      observations(id)
      |> where([message], message.id not in ^current_ids)
      |> order_by([message], desc: message.seq)
      |> limit(@ambient_rows)
      |> Repo.all()
      |> Enum.reverse()

    cutoff = rows |> Enum.filter(&(&1.message.author_type == :agent)) |> List.last()

    Enum.filter(rows, fn row ->
      row.message.author_type != :agent and
        (is_nil(cutoff) or row.message.seq > cutoff.message.seq)
    end)
    |> Enum.map(&observed_message(&1, attrs.provider_thread_id))
  end

  def unreplied_messages(_attrs, _entries), do: []

  defp observed_message(%{message: message, external_ref: ref}, thread \\ nil) do
    author = if ref, do: ref.author, else: %{"principal_uid" => message.author_uid}

    %{
      "id" => message.id,
      "message_id" => message.id,
      "seq" => message.seq,
      "source" => "conversation",
      "role" => message_role(message),
      "kind" => "normal",
      "speaker" => speaker_name(author),
      "sent_at" => DateTime.to_iso8601(message.created_at),
      "text" => message.text || "",
      "attachments" => message.attachments,
      "conversation_id" => message.conversation_id,
      "provider_message_id" => if(ref, do: ref.provider_message_id),
      "provider_thread_id" => if(ref, do: ref.provider_thread_id) || thread
    }
  end

  defp message_role(%Message{author_type: :agent}), do: "agent"
  defp message_role(_message), do: "human"
  def speaker_name(author), do: author_name(author) || "unknown speaker"

  defp author_name(author) when is_map(author),
    do:
      Enum.find_value(
        ~w(display_name fullName userName name principal_uid agent_uid),
        &value(author, &1)
      )

  defp author_name(_author), do: nil

  defp after_time(query, nil), do: query
  defp after_time(query, %DateTime{} = at), do: where(query, [message], message.created_at > ^at)

  defp dedupe(messages),
    do:
      messages
      |> Enum.reverse()
      |> Enum.uniq_by(&(&1["message_id"] || {&1["conversation_id"], &1["provider_message_id"]}))
      |> Enum.reverse()

  defp sort_key(message) do
    case DateTime.from_iso8601(message["sent_at"] || "") do
      {:ok, at, _} -> {DateTime.to_unix(at, :microsecond), message["seq"] || 0}
      _ -> {0, 0}
    end
  end

  defp value(map, key) when is_map(map), do: Ankole.Attrs.get(map, key)
  defp value(_map, _key), do: nil
end
