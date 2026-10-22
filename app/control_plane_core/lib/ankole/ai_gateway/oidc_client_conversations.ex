defmodule Ankole.AIGateway.OIDCClientConversations do
  @moduledoc """
  Stored conversation evidence submitted through an authenticated OIDC Client.

  Origin belongs to each request, not to the conversation's Human owner.
  Only terminal requests participate. Retractions change the revision but do
  not supply evidence. Injection positions and text byte ranges refer to the
  single stored item list.
  """

  require Ash.Query

  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.JSON
  alias Ankole.Kernel, as: NativeKernel

  def client_ids do
    %{client_ids: client_ids} =
      Ankole.Ash.aggregate!(terminal_requests(), [
        {:client_ids, :list, field: :oidc_client_id, uniq?: true}
      ])

    client_ids
  end

  def conversations(client_id) do
    requests(client_id)
    |> Ash.Query.select([:id, :conversation_id, :subject_uid, :status, :updated_at])
    |> Ankole.Ash.read!()
    |> Enum.group_by(& &1.conversation_id)
    |> Enum.map(fn {id, messages} ->
      %{id: id, subject_uid: hd(messages).subject_uid, revision: revision(messages)}
    end)
  end

  def read(client_id, conversation_id) do
    messages =
      client_id
      |> requests()
      |> Ash.Query.filter(conversation_id == ^conversation_id)
      |> Ankole.Ash.read!()

    evidence =
      messages
      |> Enum.reject(&(&1.status == :retracted))
      |> Enum.map(&request_evidence/1)
      |> Enum.reject(&(&1.input == [] and &1.output == []))

    %{revision: revision(messages), requests: evidence}
  end

  defp terminal_requests do
    Ash.Query.filter(
      Message,
      type == :message and status in [:complete, :error, :retracted] and
        not is_nil(oidc_client_id)
    )
  end

  defp requests(client_id) do
    terminal_requests()
    |> Ash.Query.filter(oidc_client_id == ^client_id)
    |> Ash.Query.sort(id: :asc)
  end

  defp revision(messages) do
    messages
    |> Enum.map(&[&1.id, &1.status, DateTime.to_iso8601(&1.updated_at)])
    |> JSON.encode!()
    |> NativeKernel.xxh3_128_hex()
  end

  defp request_evidence(message) do
    input_count = message.metadata["request_item_count"] || 0
    {input, output} = Enum.split(message.content, input_count)

    %{
      response_id: "resp_#{message.id}",
      previous_response_id:
        if(message.previous_message_id, do: "resp_#{message.previous_message_id}"),
      submitted_by: message.subject_uid,
      recorded_at: DateTime.to_iso8601(message.inserted_at),
      status: Atom.to_string(message.status),
      input: dialogue(input),
      output: if(message.status == :complete, do: dialogue(output), else: [])
    }
  end

  defp dialogue(items) do
    Enum.flat_map(items, fn
      %{"role" => role, "content" => content} = item when role in ["user", "assistant"] ->
        text =
          if(Map.get(item, "type", "message") == "message", do: text_content(content), else: "")

        if String.trim(text) == "",
          do: [],
          else: [Map.take(item, ["role", "name"]) |> Map.put("text", text)]

      _internal ->
        []
    end)
  end

  defp text_content(content) when is_binary(content), do: content

  defp text_content(parts) when is_list(parts) do
    Enum.flat_map(parts, fn
      %{"type" => type, "text" => text}
      when type in ["input_text", "output_text", "text"] and is_binary(text) ->
        [text]

      _part ->
        []
    end)
    |> Enum.join("\n")
  end

  defp text_content(_content), do: ""
end
