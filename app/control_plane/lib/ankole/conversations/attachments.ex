defmodule Ankole.Conversations.Attachments do
  @moduledoc "Coordinates attachment materialization, stable identities, and conversation-root references."
  require Ash.Query
  alias Ecto.Adapters.SQL
  alias Ankole.{Files, Repo}
  alias Ankole.Conversations.{External, ExternalMessageRef, Message}
  @attachment_id_sequence "conversation_attachment_id_seq"
  @attachment_id_min 10_000
  @attachment_id_max 9_007_199_254_740_991
  @attachment_identity_fields ~w(upload_id provider_ref provider_file_id provider_file_key provider_uri object_id storage_ref)
  @attachment_materialization_fields ~w(attachment_id object_id node_id sha256 path content_type size size_bytes bytes)

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
    conversation = External.get_conversation(input.provider_conversation_id)

    existing =
      if conversation, do: External.get_message(conversation.id, input.provider_message_id)

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
        Map.put(
          Ankole.Logging.failure_fields(:error, exception, __STACKTRACE__),
          :provider_message_id,
          input.provider_message_id
        )
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

  defp observation_time(%{"observed_at" => value}) when is_binary(value),
    do: Ankole.Attrs.parse_datetime(value) || DateTime.utc_now(:microsecond)

  defp observation_time(_observation), do: DateTime.utc_now(:microsecond)

  @doc "Stores downloaded bytes as an uncompleted object until the attachment commits."
  @spec store_attachment(map(), binary() | {:file, Path.t()}, keyword()) ::
          {:ok, map()} | {:error, term()}
  def store_attachment(attachment, content, opts \\ []) when is_map(attachment) do
    with {:ok, %{object_id: object_id, sha256: sha256, size: size}} <- Files.store(content) do
      name = present(Keyword.get(opts, :name)) || present(attachment["name"]) || "attachment"

      attachment =
        attachment
        |> Map.put("object_id", object_id)
        |> Map.put("sha256", sha256)
        |> Map.put_new("name", name)
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

  def prepare_in_tx(_agent_uid, conversation_id, _message_id, attachments, existing) do
    attachments
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.map(fn {attachment, index} ->
      attachment
      |> put_attachment_id(index, List.wrap(existing))
      |> ensure_conversation_node(conversation_id)
    end)
  end

  @doc "Assigns native attachment identities and creates files in the conversation root."
  def prepare_native_in_tx(conversation_id, message_id, attachments, existing),
    do: prepare_in_tx(nil, conversation_id, message_id, attachments, existing)

  # A later observation cannot take stored bytes away from an attachment. A
  # provider that redelivers an event can fetch the same file twice; when the
  # second fetch fails after the first one stored the bytes, or reports before
  # it, the stored result with its `object_id` stays. This runs under the entry
  # lock, so the order in which two downloads finish cannot lose the bytes.
  defp put_attachment_id(attachment, index, existing_attachments)
       when is_map(attachment) do
    existing = matching_existing_attachment(attachment, index, existing_attachments)

    if stored?(existing) and not stored?(attachment) do
      existing
    else
      Map.put(
        attachment,
        "attachment_id",
        valid_attachment_id(existing) || next_attachment_id()
      )
    end
  end

  defp put_attachment_id(attachment, _index, _existing_attachments), do: attachment

  @doc """
  Applies the stored-bytes rule of `prepare_in_tx/5` without a Message.

  An attachment that `existing` stored replaces its later form without bytes.
  The caller holds the entry lock.
  """
  @spec keep_stored([map()], [map()]) :: [map()]
  def keep_stored(attachments, existing) do
    attachments
    |> Enum.with_index()
    |> Enum.map(fn {attachment, index} ->
      stored = matching_existing_attachment(attachment, index, existing)
      if stored?(stored) and not stored?(attachment), do: stored, else: attachment
    end)
  end

  @doc "Pins attachment objects in the conversation root before their Signal commits."
  def prepare_payload_in_tx(payload, conversation_id) do
    case payload do
      %{"data" => data} when is_map(data) ->
        data = scope_message(data, conversation_id)

        data =
          Enum.reduce(
            ["entry", "entries", "unreplied_messages", "observed_messages", "backdrop_messages"],
            data,
            fn key, acc ->
              case Map.fetch(acc, key) do
                {:ok, entries} when is_list(entries) ->
                  Map.put(acc, key, Enum.map(entries, &scope_message(&1, conversation_id)))

                {:ok, entry} when is_map(entry) ->
                  Map.put(acc, key, scope_message(entry, conversation_id))

                _ ->
                  acc
              end
            end
          )

        Map.put(payload, "data", data)

      _ ->
        payload
    end
  end

  defp scope_message(entry, channel_id) when is_map(entry) do
    message = payload_message(entry, channel_id)

    entry =
      case Map.fetch(entry, "attachments") do
        {:ok, attachments} when is_list(attachments) ->
          Map.put(
            entry,
            "attachments",
            Enum.map(attachments, fn attachment ->
              attachment |> ensure_conversation_node(channel_id) |> put_message_locator(message)
            end)
          )

        _missing ->
          entry
      end

    case Map.get(entry, "reply_to") do
      reply when is_map(reply) -> Map.put(entry, "reply_to", scope_message(reply, channel_id))
      _missing -> entry
    end
  end

  defp scope_message(other, _channel_id), do: other

  defp payload_message(%{"message_id" => id}, conversation_id) when is_binary(id) do
    Message
    |> Ash.Query.filter(id == ^id and conversation_id == ^conversation_id)
    |> Ankole.Ash.read_one!()
  end

  defp payload_message(%{"provider_message_id" => id}, conversation_id) when is_binary(id) do
    case External.get_message(conversation_id, id) do
      %{message: message} -> message
      _ -> nil
    end
  end

  defp payload_message(_entry, _conversation_id), do: nil

  defp put_message_locator(%{"object_id" => id} = attachment, %Message{} = message) do
    case Enum.find_index(message.attachments, &(&1["object_id"] == id)) do
      nil ->
        attachment

      position ->
        Map.merge(attachment, %{
          "message_id" => message.id,
          "conversation_id" => message.conversation_id,
          "position" => position
        })
    end
  end

  defp put_message_locator(attachment, _message), do: attachment

  @doc "Resolves frozen Message attachment metadata through the executing Principal's current membership."
  def resolve(%Ankole.AuthZ.Actor{} = actor, conversation_id, message_id, position)
      when is_integer(position) and position >= 0 do
    with {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id),
         {:ok, message_id} <- Ecto.UUID.cast(message_id),
         :ok <- authorize_attachment(actor, conversation_id),
         %Message{attachments: attachments} <-
           Message
           |> Ash.Query.filter(id == ^message_id and conversation_id == ^conversation_id)
           |> Ankole.Ash.read_one!(),
         %{"object_id" => object_id} = attachment <- Enum.at(attachments, position),
         true <- is_binary(object_id) do
      {:ok, attachment}
    else
      _ -> {:error, :not_found}
    end
  end

  def resolve(_actor, _conversation_id, _message_id, _position), do: {:error, :not_found}

  defp authorize_attachment(actor, conversation_id) do
    case Ankole.Conversations.get_conversation!(conversation_id) do
      %{kind: :native, native_access_scope: :anchor_page, page_id: page_id} ->
        Ankole.Conversations.Native.authorize_page(actor, page_id)

      _ ->
        uid = Ankole.AuthZ.Actor.uid(actor)

        case Ankole.Conversations.Participant
             |> Ash.Query.filter(conversation_id == ^conversation_id and principal_uid == ^uid)
             |> Ankole.Ash.read_one!() do
          nil -> {:error, :not_found}
          _participant -> :ok
        end
    end
  end

  def read_to_file(actor, conversation_id, message_id, position, local_path) do
    with {:ok, attachment} <- resolve(actor, conversation_id, message_id, position),
         :ok <- Files.read_object_to_file(attachment["object_id"], local_path),
         do: {:ok, attachment}
  end

  defp ensure_conversation_node(
         %{"object_id" => object_id, "node_id" => node_id} = attachment,
         _conversation_id
       )
       when is_binary(object_id) and is_binary(node_id), do: attachment

  defp ensure_conversation_node(%{"object_id" => object_id} = attachment, conversation_id)
       when is_binary(object_id) and is_binary(conversation_id) do
    object =
      if is_binary(attachment["sha256"]),
        do: %{object_id: object_id, sha256: attachment["sha256"], size: attachment["size"]},
        else: object_id

    name = present(attachment["name"]) || "attachment"

    with {:ok, node} <-
           Files.create_conversation_file_in_tx(conversation_id, name, object, %{
             content_type: content_type(attachment),
             source: "inbound"
           }) do
      attachment
      |> Map.put("node_id", node.id)
      |> Map.put("path", node.path)
    else
      {:error, reason} -> raise ArgumentError, "invalid stored attachment: #{inspect(reason)}"
    end
  end

  defp ensure_conversation_node(attachment, _conversation_id), do: attachment

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

  @doc "Returns whether an attachment identifies stored object bytes."
  @spec stored?(term()) :: boolean()
  def stored?(%{"object_id" => object_id}) when is_binary(object_id) and object_id != "",
    do: true

  def stored?(_attachment), do: false

  defp valid_attachment_id(%{"attachment_id" => attachment_id})
       when is_integer(attachment_id) and attachment_id >= @attachment_id_min and
              attachment_id <= @attachment_id_max,
       do: attachment_id

  defp valid_attachment_id(_attachment), do: nil

  defp next_attachment_id() do
    %{rows: [[attachment_id]]} =
      SQL.query!(Repo, "SELECT nextval('#{@attachment_id_sequence}')", [])

    attachment_id
  end

  def recent(conversation_id, author_id, %DateTime{} = at, opts \\ []) do
    since = DateTime.add(at, -Keyword.get(opts, :window_seconds, 120), :second)
    limit = Keyword.get(opts, :limit, 3)
    rows = Keyword.get(opts, :message_limit, max(20, limit))

    # The window is short, so the newest rows are sorted after the read.
    provider_times =
      ExternalMessageRef
      |> Ash.Query.filter(
        conversation_id == ^conversation_id and
          fragment("?->>'id' = ?", author, ^author_id) and provider_time >= ^since and
          provider_time <= ^at
      )
      |> Ash.Query.select([:message_id, :provider_time])
      |> Ankole.Ash.read!()
      |> Map.new(&{&1.message_id, &1.provider_time})

    message_ids = Map.keys(provider_times)

    Message
    |> Ash.Query.filter(conversation_id == ^conversation_id and id in ^message_ids)
    |> Ankole.Ash.read!()
    |> Enum.sort_by(&{Map.fetch!(provider_times, &1.id), &1.seq}, &newer_or_equal?/2)
    |> Enum.take(rows)
    |> Enum.flat_map(& &1.attachments)
    |> Enum.take(limit)
  end

  defp newer_or_equal?({left_time, left_seq}, {right_time, right_seq}) do
    case DateTime.compare(left_time, right_time) do
      :gt -> true
      :lt -> false
      :eq -> left_seq >= right_seq
    end
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
