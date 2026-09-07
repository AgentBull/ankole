defmodule Ankole.AIGateway.OIDCClientConversations do
  @moduledoc """
  Stored conversation evidence submitted through an authenticated OIDC Client.

  Origin belongs to each request, not to the conversation's Human owner.
  Only terminal requests participate. Retractions change the revision but do
  not supply evidence. Injection positions and text byte ranges refer to the
  single stored item list.
  """

  import Ecto.Query

  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.JSON
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Repo

  def client_ids do
    terminal_requests()
    |> select([message], fragment("?->>'oidc_client_id'", message.metadata))
    |> distinct(true)
    |> Repo.all()
  end

  def conversations(client_id) do
    requests(client_id)
    |> select(
      [message],
      map(message, [:id, :conversation_id, :subject_uid, :status, :updated_at])
    )
    |> Repo.all()
    |> Enum.group_by(& &1.conversation_id)
    |> Enum.map(fn {id, messages} ->
      %{id: id, subject_uid: hd(messages).subject_uid, revision: revision(messages)}
    end)
  end

  def read(client_id, conversation_id) do
    messages =
      requests(client_id)
      |> where([message], message.conversation_id == ^conversation_id)
      |> Repo.all()

    evidence =
      messages
      |> Enum.reject(&(&1.status == "retracted"))
      |> Enum.map(&request_evidence/1)
      |> Enum.reject(&(&1.input == [] and &1.output == []))

    %{revision: revision(messages), requests: evidence}
  end

  defp terminal_requests do
    Message
    |> where(
      [message],
      message.type == "message" and message.status in ["complete", "error", "retracted"]
    )
    |> where([message], fragment("?->>'oidc_client_id' IS NOT NULL", message.metadata))
  end

  defp requests(client_id) do
    terminal_requests()
    |> where([message], fragment("?->>'oidc_client_id'", message.metadata) == ^client_id)
    |> order_by([message], asc: message.id)
  end

  defp revision(messages) do
    messages
    |> Enum.map(&[&1.id, &1.status, DateTime.to_iso8601(&1.updated_at)])
    |> JSON.encode!()
    |> NativeKernel.xxh3_128_hex()
  end

  defp request_evidence(message) do
    input_count = message.metadata["request_item_count"] || 0
    injection = message.metadata["brain_injection"] || %{}
    {input, output} = Enum.split(message.content, input_count)

    input =
      input
      |> Enum.with_index()
      |> Enum.reject(fn {_item, index} -> index in (injection["items"] || []) end)
      |> Enum.map(fn {item, index} ->
        without_environment(item, index, injection["environment"])
      end)

    %{
      response_id: "resp_#{message.id}",
      previous_response_id:
        if(message.previous_message_id, do: "resp_#{message.previous_message_id}"),
      submitted_by: message.subject_uid,
      recorded_at: DateTime.to_iso8601(message.inserted_at),
      status: message.status,
      input: dialogue(input),
      output: if(message.status == "complete", do: dialogue(output), else: [])
    }
  end

  defp without_environment(
         %{"content" => parts} = item,
         index,
         %{
           "item_index" => index,
           "part_index" => part_index,
           "offset" => offset,
           "length" => length
         }
       )
       when is_list(parts) do
    content =
      List.update_at(parts, part_index, fn %{"text" => text} = part ->
        ending = offset + length

        Map.put(
          part,
          "text",
          binary_part(text, 0, offset) <> binary_part(text, ending, byte_size(text) - ending)
        )
      end)

    Map.put(item, "content", content)
  end

  defp without_environment(item, _index, _position), do: item

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
