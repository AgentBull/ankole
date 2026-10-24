defmodule Ankole.Plugins.EmailAdapter.Delivery do
  @moduledoc false

  @behaviour Ankole.Conversations.Delivery.Adapter

  alias Ankole.Signals.Bindings
  alias Ankole.Plugins.EmailAdapter.Address
  alias Ankole.Plugins.EmailAdapter.Config
  alias Ankole.Plugins.EmailAdapter.ErrorPolicy
  alias Ankole.Plugins.EmailAdapter.Message
  alias Ankole.Plugins.EmailAdapter.Smtp
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Conversations.Conversation
  alias Ankole.Conversations.External
  alias Ankole.Conversations.Delivery.Intent

  @attachment_limit_bytes 20 * 1024 * 1024
  @references_limit 20

  @impl true
  def deliver(%Intent{} = intent) do
    result =
      with {:ok, config} <- Bindings.delivery_config(intent, Config),
           config = Config.runtime(config),
           {:ok, email} <- build(intent, config) do
        deliver(email, config, intent)
      end

    ErrorPolicy.normalize_delivery_result(result)
  end

  @doc """
  Builds the outbound message: recipients, headers, MIME body, and the
  deterministic Message-ID that a resend repeats.
  """
  @spec build(Intent.t(), Config.Runtime.t()) ::
          {:ok,
           %{
             from: String.t(),
             recipients: [String.t()],
             message_id: String.t(),
             headers: map(),
             body: binary()
           }}
          | {:error, term()}
  def build(%Intent{operation: operation} = intent, %Config.Runtime{} = config)
      when operation in [:post, :reply] do
    with {:ok, target} <- target(intent, config),
         {:ok, attachments} <- attachments(intent),
         :ok <- attachment_budget(attachments) do
      to = Enum.reject(target.to, &(&1 == config.address))
      cc = target.cc |> Enum.reject(&(&1 == config.address or &1 in to))

      if to == [] and cc == [] do
        {:error, :no_recipients}
      else
        message_id = message_id(intent, config)
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

        body = encode(headers, intent.fallback_visible_text || "", attachments)

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

  def build(_intent, _config), do: {:error, :unsupported_intent_operation}

  @doc false
  @spec message_id(Intent.t(), Config.Runtime.t()) :: String.t()
  def message_id(%Intent{} = intent, %Config.Runtime{address: address}) do
    digest =
      :sha256
      |> :crypto.hash([intent.agent_uid, 0, intent.binding_name, 0, intent.outbound_key])
      |> Base.encode16(case: :lower)
      |> binary_part(0, 40)

    "ank-#{digest}@#{Address.domain(address)}"
  end

  defp deliver(email, config, intent) do
    case Smtp.deliver(config, email.from, email.recipients, email.body) do
      {:ok, receipt} ->
        {:ok,
         %{
           created_provider_message_id: email.message_id,
           provider_thread_id:
             intent.provider_thread_id ||
               Ankole.Conversations.External.provider_conversation_id!(intent.conversation_id),
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
           payload: intent.payload
         }}

      :unknown ->
        :unknown

      {:error, _reason} = error ->
        error
    end
  end

  # A reply addresses the mirrored target message; a post addresses the
  # thread participants that the channel remembers.
  defp target(%Intent{operation: :reply} = intent, config) do
    case External.get_message(intent.conversation_id, intent.reply_to_provider_message_id) do
      %{external_ref: %{raw_payload: payload}} when is_map(payload) and map_size(payload) > 0 ->
        reply_targets = addresses(payload["reply_to"]) |> nonempty() || addresses(payload["from"])
        target_id = payload["message_id"] || intent.reply_to_provider_message_id

        {:ok,
         %{
           to: reply_targets,
           cc: addresses(payload["to"]) ++ addresses(payload["cc"]),
           subject: payload["subject"] || channel_subject(intent),
           in_reply_to: target_id,
           references: Enum.uniq(List.wrap(payload["references"]) ++ [target_id])
         }}

      _missing ->
        case notice_recipient(intent) do
          nil -> channel_target(intent, config)
          recipient -> notice_target(intent, recipient)
        end
    end
  end

  defp target(%Intent{operation: :post} = intent, config), do: channel_target(intent, config)

  # Signals records the refused sender on the mapping notice when it
  # commits the row, so the notice reaches that sender even when the thread
  # participants change before dispatch. The subject of an email sender is
  # the address itself.
  defp notice_recipient(%Intent{payload: payload}) do
    case Address.normalize(get_in(payload, ["metadata", "unmatched_sender", "platform_subject"])) do
      {:ok, address} -> address
      :error -> nil
    end
  end

  defp notice_target(intent, recipient) do
    {:ok,
     %{
       to: [recipient],
       cc: [],
       subject: channel_subject(intent),
       in_reply_to: intent.reply_to_provider_message_id,
       references: [intent.reply_to_provider_message_id]
     }}
  end

  # A reply whose target was never mirrored, such as the mapping notice to an
  # unmatched sender, still anchors to the target ID so the recipient's client
  # threads it; the target's Reply-To is unknown here, so the thread
  # participants receive it.
  defp channel_target(intent, _config) do
    with {:ok, channel} <- channel(intent) do
      root = channel.provider_conversation_id |> String.split(":thread:", parts: 2) |> Enum.at(1)
      target = if intent.operation == :reply, do: intent.reply_to_provider_message_id

      {:ok,
       %{
         to: List.wrap(channel.metadata["participants"]),
         cc: [],
         subject: channel.metadata["subject"] || channel.title,
         in_reply_to: target,
         references: Enum.uniq(Enum.reject([root, target], &is_nil/1))
       }}
    end
  end

  defp channel(intent) do
    case Ankole.Conversations.get_conversation!(intent.conversation_id) do
      %Conversation{} = channel -> {:ok, channel}
      nil -> {:error, :signal_channel_not_found}
    end
  end

  defp channel_subject(intent) do
    case channel(intent) do
      {:ok, channel} -> channel.metadata["subject"] || channel.title
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
  defp attachments(intent) do
    declared = MapHelpers.fetch_list(intent.payload, "attachments")

    with :ok <- declared_attachment_budget(declared) do
      declared
      |> Enum.map(&attachment_content/1)
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

  defp attachment_content(attachment) do
    with {:ok, content} <- Ankole.Conversations.Delivery.attachment_content(attachment) do
      {:ok,
       %{
         name: attachment["name"] || Path.basename(attachment["path"] || "attachment"),
         mime_type:
           attachment["mime_type"] || attachment["mimetype"] || "application/octet-stream",
         content: content
       }}
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
end
