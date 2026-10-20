defmodule Ankole.Conversations.Attachments do
  @moduledoc "Owns attachment bytes, stable identities, and conversation-scoped drive references."
  import Ecto.Query
  alias Ecto.Adapters.SQL
  alias Ankole.{Files, Repo}
  alias Ankole.Conversations.{Conversation, External, ExternalMessageRef, Message}
  @attachment_id_sequence "conversation_attachment_id_seq"
  @attachment_id_min 10_000
  @attachment_id_max 9_007_199_254_740_991
  @attachment_identity_fields ~w(upload_id provider_ref provider_file_id provider_file_key provider_uri blob_ref storage_ref)
  @attachment_materialization_fields ~w(attachment_id blob_ref path content_type size size_bytes bytes)

  @doc """
  Returns whether any attachment still needs its bytes stored.

  Stored bytes, provider download limits, and external-content references
  require no download. A true result means the adapter must emit a `pending`
  observation first, download and store the bytes, and then emit the final
  observation with the same `observed_at`.
  """
  @spec attachments_need_bytes?([map()]) :: boolean()
  def attachments_need_bytes?(attachments) when is_list(attachments) do
    Enum.any?(attachments, &(not attachment_satisfied?(&1)))
  end

  @doc "Stores each download result and removes transient provider credentials."
  @spec materialize_attachments([map()], String.t(), (map() -> tuple()), keyword()) :: [map()]
  def materialize_attachments(attachments, adapter_id, download_fun, opts \\ []) do
    Enum.map(attachments, fn attachment ->
      result =
        if attachment_satisfied?(attachment) do
          attachment
        else
          materialize_attachment(attachment, adapter_id, download_fun, opts)
        end

      Map.drop(result, Keyword.get(opts, :drop_keys, []))
    end)
  end

  @doc "Returns the final state of an entry's attachment observation."
  @spec materialization_state([map()]) :: String.t()
  def materialization_state(attachments) do
    if Enum.all?(attachments, &attachment_satisfied?/1), do: "complete", else: "failed"
  end

  @doc "Reuses stored media and the first observation time on provider redelivery."
  @spec reuse_stored_attachments(map(), [String.t()]) :: {map(), DateTime.t()}
  def reuse_stored_attachments(%{attachments: []} = input, _provider_fact_states),
    do: {input, DateTime.utc_now(:microsecond)}

  def reuse_stored_attachments(input, provider_fact_states) do
    conversation =
      Repo.get_by(Conversation, provider_conversation_id: input.provider_conversation_id)

    existing =
      if conversation, do: External.get_message(Repo, conversation.id, input.provider_message_id)

    case existing do
      %{message: %{attachments: stored}, external_ref: %{metadata: stored_metadata}}
      when is_list(stored) and stored != [] ->
        by_ref = Map.new(stored, &{&1["provider_ref"], &1})

        attachments =
          Enum.map(input.attachments, fn attachment ->
            case Map.get(by_ref, attachment["provider_ref"]) do
              %{"materialization_state" => "complete"} = kept ->
                if stored?(kept), do: kept, else: attachment

              %{"materialization_state" => state} = kept ->
                if state in provider_fact_states, do: kept, else: attachment

              _missing_failed_or_unfinished ->
                attachment
            end
          end)

        observation = stored_metadata["attachment_materialization"]

        metadata =
          if is_map(observation),
            do: Map.put(input.metadata, "attachment_materialization", observation),
            else: input.metadata

        {%{input | attachments: attachments, metadata: metadata}, observation_time(observation)}

      _no_mirror ->
        {input, DateTime.utc_now(:microsecond)}
    end
  rescue
    exception ->
      Ankole.Logging.warning(
        "conversations.attachments.reuse_lookup_failed",
        "Attachment reuse lookup failed",
        %{provider_message_id: input.provider_message_id, reason: Exception.message(exception)}
      )

      {input, DateTime.utc_now(:microsecond)}
  end

  defp materialize_attachment(attachment, adapter_id, download_fun, opts) do
    with {:ok, %{body: body, filename: filename, content_type: content_type, put: put}} <-
           download_fun.(attachment),
         {:ok, stored} <-
           store_attachment(Map.merge(attachment, put), body,
             name: filename,
             content_type: content_type
           ) do
      Map.put(stored, "materialization_state", "complete")
    else
      {:error, :provider_download_limit} ->
        attachment
        |> Map.put("materialization_state", "provider_download_limit")
        |> Map.put("restriction", Keyword.fetch!(opts, :restriction))

      reason ->
        attachment_failed(attachment, adapter_id, reason)
    end
  rescue
    exception -> attachment_failed(attachment, adapter_id, exception)
  end

  defp attachment_failed(attachment, adapter_id, reason) do
    Ankole.Logging.warning(
      "conversations.attachments.materialization_failed",
      "Attachment materialization failed",
      %{
        adapter: adapter_id,
        provider_ref: attachment["provider_ref"],
        source_message_id: attachment["source_message_id"],
        reason: inspect(reason)
      }
    )

    Map.put(attachment, "materialization_state", "failed")
  end

  defp attachment_satisfied?(attachment) do
    stored?(attachment) or
      attachment["materialization_state"] in [
        "provider_download_limit",
        "provider_external_content"
      ]
  end

  defp observation_time(%{"observed_at" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, observed_at, _offset} -> observed_at
      _invalid -> DateTime.utc_now(:microsecond)
    end
  end

  defp observation_time(_observation), do: DateTime.utc_now(:microsecond)

  @doc """
  Stores downloaded attachment bytes in the file service.

  `content` is a binary or `{:file, path}`. The result is the attachment with
  `blob_ref` (the SHA-256 digest), `path` (its drive path under `inbox/`), and
  `size`. `name:` overrides the attachment's own `name` in the path, and
  `content_type:` fills `content_type` when the attachment declares none.
  Every Agent that receives the attachment gets the same stored bytes, so an
  adapter stores them once whichever Agent asked first.
  """
  @spec store_attachment(map(), binary() | {:file, Path.t()}, keyword()) ::
          {:ok, map()} | {:error, term()}
  def store_attachment(attachment, content, opts \\ []) when is_map(attachment) do
    with {:ok, %{sha256: sha256, size: size}} <- Files.store(content) do
      name = present(Keyword.get(opts, :name)) || present(attachment["name"]) || "attachment"

      attachment =
        attachment
        |> Map.put("blob_ref", sha256)
        |> Map.put("path", Files.content_path("inbox", sha256, name))
        |> Map.put("size", size)

      attachment =
        case {content_type(attachment), present(opts[:content_type])} do
          {nil, content_type} when is_binary(content_type) ->
            Map.put(attachment, "content_type", content_type)

          _declared_or_unknown ->
            attachment
        end

      {:ok, attachment}
    end
  end

  @doc """
  Puts the two-phase attachment observation into entry metadata.

  `state` is `"pending"` before the download and `"complete"` or `"failed"`
  after it. `observed_at` is the moment the adapter first saw the attachment.
  It anchors the inbound batch window and the materialization cap, so the
  final observation must carry the same value as the pending one.
  """
  @spec put_attachment_materialization(map(), String.t(), DateTime.t()) :: map()
  def put_attachment_materialization(metadata, state, %DateTime{} = observed_at)
      when is_map(metadata) and state in ["pending", "complete", "failed"] do
    Map.put(metadata, "attachment_materialization", %{
      "state" => state,
      "observed_at" => DateTime.to_iso8601(observed_at)
    })
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

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

  @doc """
  Assigns native Message identities without exposing a queued upload in the Agent drive.
  A Message has its own path so a later upload cannot read or replace an Agent's edits to an older input.
  """
  def prepare_native_in_tx(repo, conversation_id, message_id, attachments, existing) do
    attachments
    |> Enum.with_index()
    |> Enum.map(fn {attachment, index} ->
      path = Files.content_path("inbox", attachment["blob_ref"], attachment["name"])
      attachment = put_attachment_id(repo, attachment, index, existing)
      Map.put(attachment, "path", String.replace_prefix(path, "inbox/", "inbox/#{message_id}/"))
    end)
    |> scope(conversation_id)
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
