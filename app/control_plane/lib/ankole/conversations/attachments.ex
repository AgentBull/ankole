defmodule Ankole.Conversations.Attachments do
  @moduledoc "Owns stable attachment identities and conversation-scoped drive references."
  import Ecto.Query
  alias Ecto.Adapters.SQL
  alias Ankole.{Files, Repo}
  alias Ankole.Conversations.{ExternalMessageRef, Message}
  @attachment_id_sequence "conversation_attachment_id_seq"
  @attachment_id_min 10_000
  @attachment_id_max 9_007_199_254_740_991
  @attachment_identity_fields ~w(provider_ref provider_file_id provider_file_key provider_uri blob_ref storage_ref)
  @attachment_materialization_fields ~w(attachment_id blob_ref path content_type size size_bytes bytes)

  def prepare_in_tx(repo, agent_uid, conversation_id, message_id, attachments, existing) do
    attachments
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.map(fn {attachment, index} ->
      put_attachment_id(repo, attachment, index, List.wrap(existing))
    end)
    |> scope(conversation_id)
    |> Enum.map(
      &link_attachment(
        repo,
        agent_uid,
        %{conversation_id: conversation_id, message_id: message_id},
        &1
      )
    )
  end

  # A later observation cannot take stored bytes away from an attachment. A
  # provider that redelivers an event can fetch the same file twice; when the
  # second fetch fails after the first one stored the bytes, or reports before
  # it, the stored result with its `blob_ref` stays. This runs under the entry
  # lock, so the order in which two downloads finish cannot lose the bytes.
  defp put_attachment_id(repo, attachment, index, existing_attachments)
       when is_map(attachment) do
    existing = matching_existing_attachment(attachment, index, existing_attachments)

    if stored?(existing) and not stored?(attachment) do
      existing
    else
      Map.put(
        attachment,
        "attachment_id",
        valid_attachment_id(existing) || next_attachment_id(repo)
      )
    end
  end

  defp put_attachment_id(_repo, attachment, _index, _existing_attachments), do: attachment

  @doc """
  Names in the Agent's drive every stored attachment that an Signal
  payload shows to the Agent and that the drive does not name yet.

  The control plane calls it before it hands a payload to a Worker. Paths that
  bypass the mirror, or reach the Agent before the mirror, then still give the
  Agent attachments it can read: an entry whose stored copy is newer than the
  observation, a group entry that is mirrored only when its batch closes, and
  a supplement that updates an open Signal before the mirror. A path that
  the drive already names stays as its writer left it, with the provenance of
  the mirror and the source of a sent or generated file.
  """
  @spec link_payload(String.t(), map(), String.t() | nil) :: :ok
  def link_payload(agent_uid, payload, channel_id)
      when is_binary(agent_uid) and is_map(payload) do
    payload
    |> scope_payload(channel_id)
    |> payload_attachments()
    |> Enum.filter(&stored?/1)
    |> Enum.uniq_by(&{&1["path"], &1["blob_ref"]})
    |> Enum.reject(&match?({:ok, _file}, Files.fetch(agent_uid, &1["path"])))
    |> Enum.each(fn attachment ->
      {:ok, _attachment} =
        Ankole.Repo.transact(fn repo ->
          {:ok, link_attachment(repo, agent_uid, %{conversation_id: channel_id}, attachment)}
        end)
    end)
  end

  def link_payload(_agent_uid, _payload, _channel_id), do: :ok

  @doc "Gives received files their channel paths, including old inbox references."
  def scope(attachments, channel_id) do
    Enum.map(attachments, fn
      %{"path" => "inbox/" <> _rest = path} = attachment when is_binary(channel_id) ->
        Map.put(attachment, "path", Files.chat_path(channel_id, path))

      attachment ->
        attachment
    end)
  end

  @doc "Updates received attachment paths in an input payload without changing its other facts."
  def scope_payload(payload, channel_id) do
    case payload do
      %{"data" => data} when is_map(data) ->
        data = scope_message(data, channel_id)

        data =
          Enum.reduce(
            ["entry", "entries", "unreplied_messages", "observed_messages", "backdrop_messages"],
            data,
            fn key, acc ->
              case Map.fetch(acc, key) do
                {:ok, entries} when is_list(entries) ->
                  Map.put(acc, key, Enum.map(entries, &scope_message(&1, channel_id)))

                {:ok, entry} when is_map(entry) ->
                  Map.put(acc, key, scope_message(entry, channel_id))

                _missing ->
                  acc
              end
            end
          )

        Map.put(payload, "data", data)

      _other ->
        payload
    end
  end

  defp scope_message(entry, channel_id) when is_map(entry) do
    entry =
      case Map.fetch(entry, "attachments") do
        {:ok, attachments} when is_list(attachments) ->
          Map.put(entry, "attachments", scope(attachments, channel_id))

        _missing ->
          entry
      end

    case Map.get(entry, "reply_to") do
      reply when is_map(reply) -> Map.put(entry, "reply_to", scope_message(reply, channel_id))
      _missing -> entry
    end
  end

  defp scope_message(other, _channel_id), do: other

  # Attachments of the entry, of the message it quotes, and of every entry of
  # a batch. The payload is the stored JSON of an Signal, so its keys are
  # strings.
  defp payload_attachments(payload) do
    data = field(payload, "data") || %{}

    entries =
      [data, field(data, "entry")] ++
        List.wrap(field(data, "entries")) ++
        List.wrap(field(data, "unreplied_messages")) ++
        List.wrap(field(data, "observed_messages")) ++
        List.wrap(field(data, "backdrop_messages"))

    Enum.flat_map(entries, fn
      entry when is_map(entry) ->
        List.wrap(field(entry, "attachments")) ++
          List.wrap(field(field(entry, "reply_to"), "attachments"))

      _other ->
        []
    end)
    |> Enum.filter(&is_map/1)
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key)
  defp field(_value, _key), do: nil

  defp link_attachment(
         repo,
         agent_uid,
         provenance,
         %{"blob_ref" => sha256, "path" => path} = attachment
       )
       when is_binary(agent_uid) and is_binary(sha256) and is_binary(path) do
    upsert = %{
      path: path,
      sha256: sha256,
      source: "inbound",
      content_type: content_type(attachment),
      conversation_id: Map.get(provenance, :conversation_id),
      message_id: Map.get(provenance, :message_id)
    }

    case Files.commit(repo, agent_uid, [upsert], []) do
      {:ok, _result} -> attachment
      {:error, {:blob_missing, _sha256}} -> Map.drop(attachment, ["blob_ref", "path"])
      {:error, reason} -> raise ArgumentError, "invalid stored attachment: #{inspect(reason)}"
    end
  end

  defp link_attachment(_repo, _agent_uid, _fact, attachment), do: attachment

  @doc "The declared content type of one attachment, if the provider gave one."
  @spec content_type(map()) :: String.t() | nil
  def content_type(attachment) when is_map(attachment) do
    Enum.find_value(["content_type", "mimetype", "mime_type"], fn key ->
      case Map.get(attachment, key) do
        value when is_binary(value) and value != "" -> value
        _missing -> nil
      end
    end)
  end

  defp matching_existing_attachment(attachment, index, existing_attachments) do
    case attachment_identity(attachment) do
      nil ->
        existing_attachment = Enum.at(existing_attachments, index)

        if attachment_descriptor(existing_attachment) == attachment_descriptor(attachment),
          do: existing_attachment

      identity ->
        Enum.find(existing_attachments, &(attachment_identity(&1) == identity))
    end
  end

  defp attachment_identity(attachment) when is_map(attachment) do
    Enum.find_value(@attachment_identity_fields, fn field ->
      case Map.get(attachment, field) do
        value when is_binary(value) and value != "" -> {field, value}
        _missing_or_invalid -> nil
      end
    end)
  end

  defp attachment_identity(_attachment), do: nil

  defp attachment_descriptor(attachment) when is_map(attachment),
    do: Map.drop(attachment, @attachment_materialization_fields)

  defp attachment_descriptor(_attachment), do: nil

  @doc """
  Returns whether the file service already holds the bytes of an attachment.

  The bytes are content addressed and shared, so one stored copy serves every
  Agent that receives the attachment.
  """
  @spec stored?(term()) :: boolean()
  def stored?(%{"blob_ref" => sha256, "path" => path})
      when is_binary(sha256) and sha256 != "" and is_binary(path) and path != "",
      do: true

  def stored?(_attachment), do: false

  defp valid_attachment_id(%{"attachment_id" => attachment_id})
       when is_integer(attachment_id) and attachment_id >= @attachment_id_min and
              attachment_id <= @attachment_id_max,
       do: attachment_id

  defp valid_attachment_id(_attachment), do: nil

  defp next_attachment_id(repo) do
    %{rows: [[attachment_id]]} =
      SQL.query!(repo, "SELECT nextval('#{@attachment_id_sequence}')", [])

    attachment_id
  end

  def recent(conversation_id, author_id, at, opts \\ []),
    do: recent(Repo, conversation_id, author_id, at, opts)

  def recent(repo, conversation_id, author_id, %DateTime{} = at, opts) do
    since = DateTime.add(at, -Keyword.get(opts, :window_seconds, 120), :second)
    limit = Keyword.get(opts, :limit, 3)
    rows = Keyword.get(opts, :message_limit, max(20, limit))

    repo.all(
      from message in Message,
        join: ref in ExternalMessageRef,
        on: ref.tenant_id == message.tenant_id and ref.message_id == message.id,
        where:
          message.conversation_id == ^conversation_id and
            fragment("?->>'id' = ?", ref.author, ^author_id) and
            ref.provider_time >= ^since and ref.provider_time <= ^at,
        order_by: [desc: ref.provider_time, desc: message.seq],
        limit: ^rows,
        select: message.attachments
    )
    |> List.flatten()
    |> Enum.take(limit)
  end

  def rich_content(text, formatted_content) when is_map(formatted_content) do
    case formatted_content do
      %{"format" => "markdown", "body" => ^text} when map_size(formatted_content) == 2 -> nil
      %{format: "markdown", body: ^text} when map_size(formatted_content) == 2 -> nil
      map when map == %{} -> nil
      map -> map
    end
  end

  def rich_content(_text, _formatted_content), do: nil
end
