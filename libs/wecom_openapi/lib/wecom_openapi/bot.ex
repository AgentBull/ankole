defmodule WeComOpenAPI.Bot do
  @moduledoc """
  WeCom AI-bot command helpers over a `WeComOpenAPI.Bot.Client` connection.

  Reply commands ride `aibot_respond_msg` bound to an inbound `req_id` (valid
  for 24 hours after the callback); proactive commands ride `aibot_send_msg`
  with a fresh `req_id` and require the user to have messaged the bot in that
  conversation before. Media uploads run the three-step chunked flow
  (`init → chunk × N → finish`) serially over the same connection.
  """

  alias WeComOpenAPI.Bot.Client
  alias WeComOpenAPI.Error

  @update_cmd "aibot_respond_update_msg"
  @welcome_cmd "aibot_respond_welcome_msg"
  @send_cmd "aibot_send_msg"
  @upload_init_cmd "aibot_upload_media_init"
  @upload_chunk_cmd "aibot_upload_media_chunk"
  @upload_finish_cmd "aibot_upload_media_finish"

  # Chunk payload bytes before Base64 (protocol cap 512KB per chunk).
  @chunk_size 512 * 1024
  @max_chunks 100

  @type media_type :: String.t()

  # --- replies (bound to an inbound req_id) --------------------------------

  @doc """
  Create or refresh a streaming reply. The same `stream_id` refreshes the
  message with the full `content` snapshot; `finish: true` closes the stream.
  `opts`: `:finish` (default false), `:msg_item` (finish-frame only).
  """
  @spec reply_stream(GenServer.server(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def reply_stream(server, req_id, stream_id, content, opts \\ []) do
    stream =
      %{"id" => stream_id, "finish" => Keyword.get(opts, :finish, false), "content" => content}
      |> maybe_put("msg_item", Keyword.get(opts, :msg_item))

    Client.reply(server, req_id, %{"msgtype" => "stream", "stream" => stream})
  end

  @doc "Reply with a markdown message."
  @spec reply_markdown(GenServer.server(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def reply_markdown(server, req_id, content) do
    Client.reply(server, req_id, %{"msgtype" => "markdown", "markdown" => %{"content" => content}})
  end

  @doc "Reply with an uploaded media item (`file` / `image` / `voice` / `video`)."
  @spec reply_media(GenServer.server(), String.t(), media_type(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def reply_media(server, req_id, media_type, media_id)
      when media_type in ["file", "image", "voice", "video"] do
    Client.reply(server, req_id, %{
      "msgtype" => media_type,
      media_type => %{"media_id" => media_id}
    })
  end

  @doc "Reply with a template card."
  @spec reply_template_card(GenServer.server(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def reply_template_card(server, req_id, template_card) when is_map(template_card) do
    Client.reply(server, req_id, %{
      "msgtype" => "template_card",
      "template_card" => template_card
    })
  end

  @doc """
  Update a template card in response to a `template_card_event` (must be sent
  within the 5-second event window, bound to the event frame's `req_id`).
  `opts`: `:userids` — replace only those users' cards.
  """
  @spec update_template_card(GenServer.server(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def update_template_card(server, req_id, template_card, opts \\ [])
      when is_map(template_card) do
    body =
      %{"msgtype" => "template_card", "template_card" => template_card}
      |> maybe_put("userids", Keyword.get(opts, :userids))

    Client.reply(server, req_id, body, cmd: @update_cmd)
  end

  @doc "Reply a welcome message to an `enter_chat` event (5-second window)."
  @spec reply_welcome(GenServer.server(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def reply_welcome(server, req_id, body) when is_map(body) do
    Client.reply(server, req_id, body, cmd: @welcome_cmd)
  end

  # --- proactive sends -----------------------------------------------------

  @doc """
  Proactively send markdown to a conversation. `chat_type` is `1` for a DM
  (chatid = userid) and `2` for a group (chatid = group chatid).
  """
  @spec send_markdown(GenServer.server(), String.t(), 1 | 2, String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def send_markdown(server, chatid, chat_type, content) do
    Client.request(server, @send_cmd, %{
      "chatid" => chatid,
      "chat_type" => chat_type,
      "msgtype" => "markdown",
      "markdown" => %{"content" => content}
    })
  end

  @doc "Proactively send a template card to a conversation."
  @spec send_template_card(GenServer.server(), String.t(), 1 | 2, map()) ::
          {:ok, map()} | {:error, Error.t()}
  def send_template_card(server, chatid, chat_type, template_card) when is_map(template_card) do
    Client.request(server, @send_cmd, %{
      "chatid" => chatid,
      "chat_type" => chat_type,
      "msgtype" => "template_card",
      "template_card" => template_card
    })
  end

  # --- media upload --------------------------------------------------------

  @doc """
  Upload a temporary media item over the connection (three-step chunked flow)
  and return its `media_id`. `type` is `"file" | "image" | "voice" | "video"`;
  platform size caps apply (image/video 10MB, voice 2MB AMR, file 20MB) and are
  enforced by the platform, not here. Chunks upload serially — the 30-minute
  upload session leaves ample room at ≤100 chunks.
  """
  @spec upload_media(GenServer.server(), media_type(), String.t(), binary()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def upload_media(server, type, filename, content)
      when type in ["file", "image", "voice", "video"] and is_binary(content) do
    chunks = chunk(content)
    total_chunks = length(chunks)

    cond do
      content == <<>> ->
        {:error, %Error{reason: :unexpected_shape, message: "media content is empty"}}

      total_chunks > @max_chunks ->
        {:error,
         %Error{
           reason: :unexpected_shape,
           message: "media exceeds #{@max_chunks} chunks (#{byte_size(content)} bytes)"
         }}

      true ->
        init_body = %{
          "type" => type,
          "filename" => filename,
          "total_size" => byte_size(content),
          "total_chunks" => total_chunks,
          "md5" => Base.encode16(:crypto.hash(:md5, content), case: :lower)
        }

        with {:ok, init_ack} <- Client.request(server, @upload_init_cmd, init_body),
             {:ok, upload_id} <- fetch_body_field(init_ack, "upload_id"),
             :ok <- upload_chunks(server, upload_id, chunks),
             {:ok, finish_ack} <-
               Client.request(server, @upload_finish_cmd, %{"upload_id" => upload_id}) do
          fetch_body_field(finish_ack, "media_id")
        end
    end
  end

  defp chunk(content) do
    for <<chunk::binary-size(@chunk_size) <- content>> do
      chunk
    end
    |> then(fn full_chunks ->
      remainder_size = rem(byte_size(content), @chunk_size)

      if remainder_size > 0 do
        full_chunks ++ [binary_part(content, byte_size(content) - remainder_size, remainder_size)]
      else
        full_chunks
      end
    end)
  end

  defp upload_chunks(server, upload_id, chunks) do
    chunks
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {chunk, index}, :ok ->
      body = %{
        "upload_id" => upload_id,
        "chunk_index" => index,
        "base64_data" => Base.encode64(chunk)
      }

      case Client.request(server, @upload_chunk_cmd, body) do
        {:ok, _ack} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp fetch_body_field(ack, field) do
    case get_in(ack, ["body", field]) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, %Error{reason: :unexpected_shape, raw: ack}}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
