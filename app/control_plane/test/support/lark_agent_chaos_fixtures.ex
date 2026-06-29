defmodule Ankole.LarkAgentChaos.FakeLarkOutbox do
  @moduledoc """
  Fake sender that still uses the real Lark adapter request builder.
  """

  @behaviour Ankole.SignalsGateway.OutboxAdapter

  alias Ankole.Plugins.LarkAdapter.Outbox
  alias Ankole.SignalsGateway.OutboxEntry

  @owner_key {__MODULE__, :owner}

  @doc """
  Directs fake send notifications to a test process.
  """
  @spec put_owner(pid()) :: :ok
  def put_owner(owner) when is_pid(owner) do
    Process.put(@owner_key, owner)
    :ok
  end

  @impl true
  def capabilities, do: Outbox.capabilities()

  @impl true
  def send(%OutboxEntry{} = outbox) do
    with {:ok, outbox} <- fake_materialize_outbound_attachments(outbox),
         {:ok, request} <- Outbox.request_for_outbox(outbox) do
      owner = Process.get(@owner_key) || self()
      Kernel.send(owner, {:fake_lark_outbox_send, outbox.outbound_key, request, outbox})

      {:ok,
       %{
         provider_entry_id: "om_fake_out_#{System.unique_integer([:positive])}",
         provider_thread_id: outbox.provider_thread_id || outbox.source_provider_entry_id,
         raw_payload: %{"fake_lark_request" => stringify_request(request)}
       }}
    end
  end

  @impl true
  def reconcile(_outbox), do: :unknown

  defp stringify_request(request) when is_map(request) do
    request
    |> Enum.map(fn {key, value} -> {to_string(key), stringify_request(value)} end)
    |> Map.new()
  end

  defp stringify_request(request) when is_list(request),
    do: Enum.map(request, &stringify_request/1)

  defp stringify_request({key, value}), do: %{to_string(key) => stringify_request(value)}
  defp stringify_request(request) when is_atom(request), do: Atom.to_string(request)
  defp stringify_request(other), do: other

  defp fake_materialize_outbound_attachments(%OutboxEntry{payload: payload} = outbox) do
    case Map.get(payload || %{}, "attachments") do
      nil ->
        {:ok, outbox}

      [] ->
        {:ok, outbox}

      [attachment] when is_map(attachment) ->
        materialized =
          attachment
          |> Map.put_new("provider_file_key", fake_file_key(attachment))
          |> Map.put_new("name", Path.basename(attachment["user_files_relative_path"] || "file"))

        {:ok, %OutboxEntry{outbox | payload: Map.put(payload, "attachments", [materialized])}}

      _attachments ->
        {:error, :multiple_outbound_attachments_not_supported}
    end
  end

  defp fake_file_key(attachment) do
    path =
      attachment["user_files_relative_path"] ||
        attachment["agent_computer_path"] ||
        attachment["path"] ||
        "unknown"

    "fake_file_" <> Base.url_encode64(path, padding: false)
  end
end

defmodule Ankole.LarkAgentChaos.FeishuServer do
  @moduledoc """
  Encodes fake Feishu events as WS frames and dispatches the decoded payload.
  """

  alias Ankole.JSON
  alias FeishuOpenAPI.Event.Dispatcher, as: FeishuDispatcher
  alias FeishuOpenAPI.WS.Frame

  @base_time ~U[2026-06-24 08:00:00.000000Z]
  @base_ms DateTime.to_unix(@base_time, :millisecond)

  @doc """
  Pushes one message event through Frame.encode/Frame.decode and the dispatcher.
  """
  @spec push_message(term(), keyword()) :: {:ok, :ok} | {:error, term()}
  def push_message(dispatcher, attrs) do
    envelope = message_envelope(attrs)
    frame = frame_for(envelope, Keyword.get(attrs, :frame_chaos, []))
    encoded = Frame.encode(frame)

    with {:ok, decoded_frame} <- Frame.decode(encoded),
         {:ok, decoded} <- JSON.decode(decoded_frame.payload) do
      FeishuDispatcher.dispatch(dispatcher, {:trusted_decoded, decoded})
    end
  end

  @doc """
  Pushes one message-recalled event through the same WS frame path as messages.
  """
  @spec push_message_recalled(term(), keyword()) :: {:ok, :ok} | {:error, term()}
  def push_message_recalled(dispatcher, attrs) do
    envelope = recalled_envelope(attrs)
    frame = frame_for(envelope, Keyword.get(attrs, :frame_chaos, []))
    encoded = Frame.encode(frame)

    with {:ok, decoded_frame} <- Frame.decode(encoded),
         {:ok, decoded} <- JSON.decode(decoded_frame.payload) do
      FeishuDispatcher.dispatch(dispatcher, {:trusted_decoded, decoded})
    end
  end

  @doc """
  Proves truncated PBBP2 frames are rejected before adapter dispatch.
  """
  @spec malformed_frame_probe() :: {:ok, Frame.t()} | {:error, term()}
  def malformed_frame_probe do
    frame = frame_for(%{"schema" => "2.0", "header" => %{}, "event" => %{}})
    encoded = Frame.encode(frame)
    Frame.decode(binary_part(encoded, 0, max(byte_size(encoded) - 2, 0)))
  end

  defp frame_for(envelope, frame_chaos \\ []) do
    event_id = get_in(envelope, ["header", "event_id"]) || "evt_unknown"

    headers =
      [{"type", "event"}, {"message_id", event_id}] ++
        Enum.map(frame_chaos, fn {key, value} -> {to_string(key), to_string(value)} end)

    %Frame{
      seq_id: System.unique_integer([:positive]),
      log_id: System.unique_integer([:positive]),
      service: 1001,
      method: 1,
      headers: headers,
      payload_encoding: "json",
      payload_type: "application/json",
      payload: JSON.encode!(envelope),
      log_id_new: "chaos-#{event_id}"
    }
  end

  defp message_envelope(attrs) do
    event_id = Keyword.fetch!(attrs, :event_id)
    message_id = Keyword.fetch!(attrs, :message_id)
    create_time = Keyword.get(attrs, :create_time_ms, @base_ms)
    message_type = Keyword.get(attrs, :message_type, "text")

    %{
      "schema" => "2.0",
      "header" => %{
        "event_id" => event_id,
        "event_type" => "im.message.receive_v1",
        "create_time" => Integer.to_string(create_time),
        "tenant_key" => "tenant-chaos",
        "app_id" => Keyword.get(attrs, :app_id, "cli_chaos_lark")
      },
      "event" => %{
        "sender" => %{
          "sender_type" => Keyword.get(attrs, :sender_type, "user"),
          "sender_name" => Keyword.get(attrs, :sender_name, "Alice Chaos"),
          "sender_id" => %{
            "user_id" => Keyword.get(attrs, :sender_user_id, "ou_alice"),
            "open_id" => Keyword.get(attrs, :sender_open_id, "ou_open_alice"),
            "union_id" => "onion_#{Keyword.get(attrs, :sender_user_id, "ou_alice")}"
          }
        },
        "message" => %{
          "message_id" => message_id,
          "root_id" => Keyword.get(attrs, :root_id),
          "parent_id" => Keyword.get(attrs, :parent_id),
          "chat_id" => Keyword.get(attrs, :chat_id, "oc_chaos_group"),
          "chat_type" => Keyword.get(attrs, :chat_type, "group"),
          "message_type" => message_type,
          "content" => message_content(attrs, message_type),
          "mentions" => Keyword.get(attrs, :mentions, []),
          "create_time" => Integer.to_string(create_time)
        }
      }
    }
  end

  defp message_content(attrs, message_type) do
    case Keyword.fetch(attrs, :content) do
      {:ok, content} when is_binary(content) ->
        content

      {:ok, content} when is_map(content) ->
        JSON.encode!(content)

      :error when message_type == "text" ->
        JSON.encode!(%{"text" => Keyword.get(attrs, :text, "")})

      :error ->
        JSON.encode!(%{})
    end
  end

  defp recalled_envelope(attrs) do
    event_id = Keyword.fetch!(attrs, :event_id)
    message_id = Keyword.fetch!(attrs, :message_id)
    recall_time = Keyword.get(attrs, :recall_time_ms, @base_ms)

    %{
      "schema" => "2.0",
      "header" => %{
        "event_id" => event_id,
        "event_type" => "im.message.recalled_v1",
        "create_time" => Integer.to_string(recall_time),
        "tenant_key" => "tenant-chaos",
        "app_id" => Keyword.get(attrs, :app_id, "cli_chaos_lark")
      },
      "event" => %{
        "message_id" => message_id,
        "chat_id" => Keyword.get(attrs, :chat_id, "oc_chaos_group"),
        "chat_type" => Keyword.get(attrs, :chat_type, "group"),
        "recall_time" => Integer.to_string(recall_time)
      }
    }
  end
end
