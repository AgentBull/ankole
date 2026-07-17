defmodule DingTalkOpenAPI.Robot do
  @moduledoc """
  DingTalk enterprise-internal robot messaging.

  Outbound group and one-to-one sends live on the new domain; media upload lives
  on the old domain and yields a `media_id` that `msgParam` references. A
  successful send returns `processQueryKey` (an encrypted message id) used as the
  outbound entry's provider id and recall handle — it is not the inbound `msgId`.

  `msgParam` is a JSON string on the wire; these functions take a plain map for
  it and encode it, so callers work with structured content.
  """

  alias DingTalkOpenAPI.{Client, Error}

  @group_send_path "/v1.0/robot/groupMessages/send"
  @oto_send_path "/v1.0/robot/oToMessages/batchSend"
  @group_recall_path "/v1.0/robot/groupMessages/recall"
  @oto_recall_path "/v1.0/robot/otoMessages/batchRecall"
  @file_download_path "/v1.0/robot/messageFiles/download"
  @media_upload_path "media/upload"

  @doc """
  Send a group message. `opts`: `:open_conversation_id`, `:robot_code`,
  `:msg_key`, `:msg_param` (map, encoded to the `msgParam` string),
  `:cool_app_code` (optional).
  """
  @spec send_group_message(Client.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def send_group_message(%Client{} = client, opts) do
    body =
      %{
        "openConversationId" => Keyword.fetch!(opts, :open_conversation_id),
        "robotCode" => Keyword.fetch!(opts, :robot_code),
        "msgKey" => Keyword.fetch!(opts, :msg_key),
        "msgParam" => encode_msg_param(Keyword.fetch!(opts, :msg_param))
      }
      |> maybe_put("coolAppCode", Keyword.get(opts, :cool_app_code))

    DingTalkOpenAPI.post(client, @group_send_path, body: body)
  end

  @doc """
  Batch-send a one-to-one message. `opts`: `:robot_code`, `:user_ids` (list),
  `:msg_key`, `:msg_param` (map). Returns `processQueryKey`,
  `invalidStaffIdList`, and `flowControlledStaffIdList` (per-user rate-limit
  signal).
  """
  @spec batch_send_oto(Client.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def batch_send_oto(%Client{} = client, opts) do
    body = %{
      "robotCode" => Keyword.fetch!(opts, :robot_code),
      "userIds" => Keyword.fetch!(opts, :user_ids),
      "msgKey" => Keyword.fetch!(opts, :msg_key),
      "msgParam" => encode_msg_param(Keyword.fetch!(opts, :msg_param))
    }

    DingTalkOpenAPI.post(client, @oto_send_path, body: body)
  end

  @doc "Recall group messages by `processQueryKey`. `opts`: `:open_conversation_id`, `:robot_code`, `:process_query_keys`."
  @spec recall_group(Client.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def recall_group(%Client{} = client, opts) do
    body = %{
      "openConversationId" => Keyword.fetch!(opts, :open_conversation_id),
      "robotCode" => Keyword.fetch!(opts, :robot_code),
      "processQueryKeys" => Keyword.fetch!(opts, :process_query_keys)
    }

    DingTalkOpenAPI.post(client, @group_recall_path, body: body)
  end

  @doc "Recall one-to-one messages by `processQueryKey`. `opts`: `:robot_code`, `:process_query_keys`."
  @spec batch_recall_oto(Client.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def batch_recall_oto(%Client{} = client, opts) do
    body = %{
      "robotCode" => Keyword.fetch!(opts, :robot_code),
      "processQueryKeys" => Keyword.fetch!(opts, :process_query_keys)
    }

    DingTalkOpenAPI.post(client, @oto_recall_path, body: body)
  end

  @doc """
  Resolve a robot-received file's `downloadCode` to a temporary URL and pull the
  bytes immediately. The temporary URL is never returned to callers — it is
  short-lived and must not be persisted.
  """
  @spec download_message_file(Client.t(), String.t(), String.t()) ::
          {:ok, %{body: binary(), filename: String.t() | nil}} | {:error, Error.t()}
  def download_message_file(%Client{} = client, robot_code, download_code) do
    body = %{"downloadCode" => download_code, "robotCode" => robot_code}

    case DingTalkOpenAPI.post(client, @file_download_path, body: body) do
      {:ok, %{"downloadUrl" => url}} when is_binary(url) ->
        DingTalkOpenAPI.download(client, url)

      {:ok, other} ->
        {:error, %Error{reason: :unexpected_shape, raw: other}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Upload a media file (old domain) and return `{:ok, media_id}`. `type` is one
  of `"image" | "voice" | "video" | "file"`.
  """
  @spec upload_media(Client.t(), String.t(), binary(), String.t()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def upload_media(%Client{} = client, type, content, filename)
      when is_binary(content) and is_binary(filename) do
    opts = [
      query: [type: type],
      form_multipart: [media: {content, filename: filename}]
    ]

    case DingTalkOpenAPI.request(client, :post, @media_upload_path, opts) do
      {:ok, %{"media_id" => media_id}} when is_binary(media_id) -> {:ok, media_id}
      {:ok, other} -> {:error, %Error{reason: :unexpected_shape, raw: other}}
      {:error, _reason} = error -> error
    end
  end

  defp encode_msg_param(param) when is_binary(param), do: param
  defp encode_msg_param(param) when is_map(param), do: Torque.encode!(param)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
