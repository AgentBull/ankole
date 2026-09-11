defmodule Ankole.Plugins.EmailAdapter.Outbox do
  @moduledoc false

  @behaviour Ankole.SignalsGateway.OutboxAdapter

  alias Ankole.{Repo, WorkerFiles}
  alias Ankole.Plugins.EmailAdapter.{Address, Config, ErrorPolicy, Message, Smtp}
  alias Ankole.Plugins.MapHelpers
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.{Channel, Entry, OutboxEntry}

  @attachment_limit_bytes 20 * 1024 * 1024
  @references_limit 20

  @impl true
  def send(%OutboxEntry{} = outbox) do
    result =
      with {:ok, config} <- config_for_outbox(outbox),
           {:ok, email} <- build(outbox, config) do
        deliver(email, config, outbox)
      end

    ErrorPolicy.normalize_delivery_result(result)
  end

  @doc """
  Builds the outbound message: recipients, headers, MIME body, and the
  deterministic Message-ID that a resend repeats.
  """
  @spec build(OutboxEntry.t(), Config.Runtime.t()) ::
          {:ok,
           %{
             from: String.t(),
             recipients: [String.t()],
             message_id: String.t(),
             headers: map(),
             body: binary()
           }}
          | {:error, term()}
  def build(%OutboxEntry{operation: operation} = outbox, %Config.Runtime{} = config)
      when operation in [:post, :reply] do
    with {:ok, target} <- target(outbox, config),
         {:ok, attachments} <- attachments(outbox),
         :ok <- attachment_budget(attachments) do
      to = Enum.reject(target.to, &(&1 == config.address))
      cc = target.cc |> Enum.reject(&(&1 == config.address or &1 in to))

      if to == [] and cc == [] do
        {:error, :no_recipients}
      else
        message_id = message_id(outbox, config)
        subject = reply_subject(target.subject)

        headers =
          MapHelpers.compact_map(%{
            "From" => Address.format(%{address: config.address, name: config.display_name}),
            "To" => Enum.join(to, ", "),
            "Cc" => if(cc != [], do: Enum.join(cc, ", ")),
            "Subject" => subject,
            "Message-ID" => "<#{message_id}>",
            "In-Reply-To" => target.in_reply_to && "<#{target.in_reply_to}>",
            "References" => references_header(target.references),
            "Auto-Submitted" => "auto-generated"
          })

        body = encode(headers, outbox.fallback_visible_text || "", attachments)

        {:ok,
         %{
           from: config.address,
           recipients: to ++ cc,
           message_id: message_id,
           headers: headers,
           body: body
         }}
      end
    end
  end

  def build(_outbox, _config), do: {:error, :unsupported_outbox_operation}

  @doc false
  @spec message_id(OutboxEntry.t(), Config.Runtime.t()) :: String.t()
  def message_id(%OutboxEntry{} = outbox, %Config.Runtime{address: address}) do
    digest =
      :sha256
      |> :crypto.hash([outbox.agent_uid, 0, outbox.binding_name, 0, outbox.outbound_key])
      |> Base.encode16(case: :lower)
      |> binary_part(0, 40)

    "ank-#{digest}@#{Address.domain(address)}"
  end

  defp deliver(email, config, outbox) do
    case Smtp.deliver(config, email.from, email.recipients, email.body) do
      {:ok, receipt} ->
        {:ok,
         %{
           created_source_entry_id: email.message_id,
           provider_thread_id: outbox.signal_channel_id,
           raw_payload:
             MapHelpers.compact_map(%{
               "message_id" => email.message_id,
               "from" => %{"address" => email.from},
               "to" => Enum.map(email.recipients, &%{"address" => &1}),
               "subject" => email.headers["Subject"],
               "in_reply_to" =>
                 email.headers["In-Reply-To"] &&
                   Message.message_id_tokens(email.headers["In-Reply-To"]),
               "references" =>
                 email.headers["References"] &&
                   Message.message_id_tokens(email.headers["References"]),
               "smtp_receipt" => receipt
             }),
           payload: outbox.payload
         }}

      :unknown ->
        :unknown

      {:error, _reason} = error ->
        error
    end
  end

  # A reply addresses the mirrored target message; a post addresses the
  # thread participants that the channel remembers.
  defp target(%OutboxEntry{operation: :reply} = outbox, config) do
    case Repo.get_by(Entry,
           signal_channel_id: outbox.signal_channel_id,
           source_entry_id: outbox.reply_to_source_entry_id
         ) do
      %Entry{raw_payload: payload} when is_map(payload) and map_size(payload) > 0 ->
        reply_targets = addresses(payload["reply_to"]) |> nonempty() || addresses(payload["from"])
        target_id = payload["message_id"] || outbox.reply_to_source_entry_id

        {:ok,
         %{
           to: reply_targets,
           cc: addresses(payload["to"]) ++ addresses(payload["cc"]),
           subject: payload["subject"] || channel_subject(outbox),
           in_reply_to: target_id,
           references: Enum.uniq(List.wrap(payload["references"]) ++ [target_id])
         }}

      _missing ->
        case notice_recipient(outbox) do
          nil -> channel_target(outbox, config)
          recipient -> notice_target(outbox, recipient)
        end
    end
  end

  defp target(%OutboxEntry{operation: :post} = outbox, config), do: channel_target(outbox, config)

  # SignalsGateway records the refused sender on the mapping notice when it
  # commits the row, so the notice reaches that sender even when the thread
  # participants change before dispatch. The subject of an email sender is
  # the address itself.
  defp notice_recipient(%OutboxEntry{payload: payload}) do
    case Address.normalize(get_in(payload, ["metadata", "unmatched_sender", "platform_subject"])) do
      {:ok, address} -> address
      :error -> nil
    end
  end

  defp notice_target(outbox, recipient) do
    {:ok,
     %{
       to: [recipient],
       cc: [],
       subject: channel_subject(outbox),
       in_reply_to: outbox.reply_to_source_entry_id,
       references: [outbox.reply_to_source_entry_id]
     }}
  end

  # A reply whose target was never mirrored, such as the mapping notice to an
  # unmatched sender, still anchors to the target ID so the recipient's client
  # threads it; the target's Reply-To is unknown here, so the thread
  # participants receive it.
  defp channel_target(outbox, _config) do
    with {:ok, channel} <- channel(outbox) do
      root = outbox.signal_channel_id |> String.split(":thread:", parts: 2) |> Enum.at(1)
      target = if outbox.operation == :reply, do: outbox.reply_to_source_entry_id

      {:ok,
       %{
         to: List.wrap(channel.metadata["participants"]),
         cc: [],
         subject: channel.metadata["subject"] || channel.name,
         in_reply_to: target,
         references: Enum.uniq(Enum.reject([root, target], &is_nil/1))
       }}
    end
  end

  defp channel(outbox) do
    case Repo.get(Channel, outbox.signal_channel_id) do
      %Channel{} = channel -> {:ok, channel}
      nil -> {:error, :signal_channel_not_found}
    end
  end

  defp channel_subject(outbox) do
    case channel(outbox) do
      {:ok, channel} -> channel.metadata["subject"] || channel.name
      _missing -> nil
    end
  end

  defp reply_subject(nil), do: "Re:"

  defp reply_subject(subject) do
    if Regex.match?(~r/\A\s*re\s*[:：]/i, subject), do: subject, else: "Re: #{subject}"
  end

  defp references_header([]), do: nil

  defp references_header(references) do
    references
    |> Enum.take(-@references_limit)
    |> Enum.map_join(" ", &"<#{&1}>")
  end

  defp encode(headers, text, []) do
    :mimemail.encode(
      {"text", "plain", header_list(headers), %{content_type_params: [{"charset", "utf-8"}]},
       text}
    )
  end

  defp encode(headers, text, attachments) do
    text_part = {"text", "plain", [], %{content_type_params: [{"charset", "utf-8"}]}, text}

    attachment_parts =
      Enum.map(attachments, fn %{name: name, mime_type: mime_type, content: content} ->
        {type, subtype} = split_mime_type(mime_type)

        {type, subtype, [],
         %{
           content_type_params: [{"name", name}],
           disposition: "attachment",
           disposition_params: [{"filename", name}],
           transfer_encoding: "base64"
         }, content}
      end)

    :mimemail.encode(
      {"multipart", "mixed", header_list(headers), %{}, [text_part | attachment_parts]}
    )
  end

  defp header_list(headers) do
    ~w(From To Cc Subject Message-ID In-Reply-To References Auto-Submitted)
    |> Enum.flat_map(fn name ->
      case headers[name] do
        nil -> []
        value -> [{name, value}]
      end
    end)
  end

  defp split_mime_type(mime_type) do
    case String.split(mime_type || "", "/", parts: 2) do
      [type, subtype] when type != "" and subtype != "" -> {type, subtype}
      _other -> {"application", "octet-stream"}
    end
  end

  # The declared sizes stop an oversize send before any file is read; the
  # loaded bytes are checked again because a declaration can be absent.
  defp attachments(outbox) do
    declared = MapHelpers.fetch_list(outbox.payload, "attachments")

    with :ok <- declared_attachment_budget(declared) do
      declared
      |> Enum.map(&attachment_content(&1, outbox.agent_uid))
      |> MapHelpers.collect_results()
    end
  end

  defp declared_attachment_budget(attachments) do
    total =
      attachments
      |> Enum.map(fn attachment ->
        case attachment["size"] || attachment["size_bytes"] do
          size when is_integer(size) and size > 0 -> size
          _unknown -> 0
        end
      end)
      |> Enum.sum()

    if total > @attachment_limit_bytes, do: {:error, :attachments_too_large}, else: :ok
  end

  defp attachment_content(attachment, agent_uid) do
    relative = MapHelpers.optional_text(attachment, "user_files_relative_path")
    lane_path = if relative, do: Ankole.AgentHomePaths.user_files_lane_path(agent_uid, relative)

    with path when is_binary(path) <- lane_path,
         {:ok, %{"content" => content}} <- WorkerFiles.get("user_files", path) do
      {:ok,
       %{
         name: attachment["name"] || Path.basename(relative),
         mime_type:
           attachment["mime_type"] || attachment["mimetype"] || "application/octet-stream",
         content: content
       }}
    else
      nil -> {:error, :outbound_attachment_path_missing}
      {:error, _reason} = error -> error
    end
  end

  defp attachment_budget(attachments) do
    total = attachments |> Enum.map(&byte_size(&1.content)) |> Enum.sum()
    if total > @attachment_limit_bytes, do: {:error, :attachments_too_large}, else: :ok
  end

  defp addresses(nil), do: []
  defp addresses(%{"address" => address}) when is_binary(address), do: [address]
  defp addresses(list) when is_list(list), do: Enum.flat_map(list, &addresses/1)
  defp addresses(_other), do: []

  defp nonempty([]), do: nil
  defp nonempty(list), do: list

  defp config_for_outbox(outbox) do
    with {:ok, config_ref} <- SignalsGateway.outbox_binding_config_ref(outbox),
         {:ok, config} <- Config.load_config_ref(config_ref) do
      {:ok, config}
    else
      :error -> {:error, :binding_config_not_found}
      {:error, _reason} = error -> error
    end
  end
end
