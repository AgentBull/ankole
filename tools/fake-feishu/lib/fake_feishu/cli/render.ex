defmodule FakeFeishu.CLI.Render do
  @moduledoc """
  Terminal rendering for transcripts and live events.

  Card streaming renders as a typewriter: while an update extends the
  previously printed card text, only the appended suffix is written, so a
  streamed CardKit answer reads like the real client. A non-appending update
  reprints the full card text on a new line.
  """

  @bot_prefix "\e[36mbot\e[0m"

  def print_transcript(messages) do
    Enum.each(messages, fn message ->
      IO.puts(transcript_line(message))
    end)
  end

  def transcript_line(message) do
    sender =
      case message["sender"] do
        "bot" -> @bot_prefix
        _user -> "\e[33m#{message["sender_name"]}\e[0m"
      end

    body =
      case {message["msg_type"], message["text"]} do
        {"file", _text} -> "[file] #{message["content"]}"
        {"image", _text} -> "[image] #{message["content"]}"
        {_type, nil} -> "[#{message["msg_type"]}] #{message["content"]}"
        {_type, text} -> text
      end

    reactions =
      case message["reactions"] do
        [] -> ""
        keys -> "  [#{Enum.join(keys, " ")}]"
      end

    "#{message["message_id"]}  #{sender} ▸ #{body}#{reactions}"
  end

  @doc """
  Prints one live event and returns the updated card-stream cache
  (`%{card_id => last_text}`).
  """
  def print_event(event, cards) do
    case event do
      %{"type" => "user_message"} = event ->
        IO.puts(
          "#{event["message_id"]}  \e[33m#{event["sender_name"]}\e[0m ▸ #{event["text"] || "[#{event["msg_type"]}]"}"
        )

        cards

      %{"type" => "bot_message"} = event ->
        body =
          case {event["msg_type"], event["text"]} do
            {"interactive", _text} -> "[card #{event["card_id"]}]"
            {type, nil} -> "[#{type}]"
            {_type, text} -> text
          end

        IO.puts("#{event["message_id"]}  #{@bot_prefix} ▸ #{body}")
        cards

      %{"type" => "card_updated", "card_id" => card_id} = event ->
        print_card_update(event, card_id, cards)

      %{"type" => "bot_message_edited"} = event ->
        IO.puts("#{event["message_id"]}  #{@bot_prefix} ✎ #{event["text"]}")
        cards

      %{"type" => "bot_message_deleted"} = event ->
        IO.puts("#{event["message_id"]}  #{@bot_prefix} ✗ deleted")
        cards

      %{"type" => "bot_reaction"} = event ->
        IO.puts("#{event["message_id"]}  #{@bot_prefix} reacted #{event["emoji"]}")
        cards

      %{"type" => "user_reaction"} = event ->
        marker = if event["action"] == "add", do: "+", else: "-"
        IO.puts("#{event["message_id"]}  #{event["operator"]} #{marker}#{event["emoji"]}")
        cards

      %{"type" => "user_recalled"} = event ->
        IO.puts("#{event["message_id"]}  recalled by user")
        cards

      %{"type" => "file_uploaded"} = event ->
        IO.puts("#{@bot_prefix} uploaded file #{event["file_key"]}")
        cards

      %{"type" => "image_uploaded"} = event ->
        IO.puts("#{@bot_prefix} uploaded image #{event["image_key"]}")
        cards

      %{"type" => "ws_connected"} = event ->
        IO.puts("\e[32m● bot connected\e[0m (conn #{event["conn_id"]})")
        cards

      %{"type" => "ws_disconnected"} = event ->
        IO.puts("\e[31m○ bot disconnected\e[0m (conn #{event["conn_id"]})")
        cards

      %{"type" => "app_auto_registered"} = event ->
        IO.puts("\e[32m● app #{event["app_id"]} auto-registered\e[0m")
        cards

      _quiet ->
        cards
    end
  end

  defp print_card_update(event, card_id, cards) do
    text = event["text"] || ""
    previous = Map.get(cards, card_id)

    cond do
      previous == nil ->
        IO.write("#{@bot_prefix} ▸ #{text}")
        newline_when_settled(event)
        Map.put(cards, card_id, text)

      text == previous ->
        newline_when_settled(event)
        cards

      String.starts_with?(text, previous) ->
        IO.write(binary_part(text, byte_size(previous), byte_size(text) - byte_size(previous)))
        newline_when_settled(event)
        Map.put(cards, card_id, text)

      true ->
        IO.puts("")
        IO.write("#{@bot_prefix} ↻ #{text}")
        newline_when_settled(event)
        Map.put(cards, card_id, text)
    end
  end

  defp newline_when_settled(%{"streaming" => false}), do: IO.puts("\n\e[2m— card settled\e[0m")
  defp newline_when_settled(_streaming), do: :ok
end
