defmodule Ankole.Plugins.SlackAdapter.BlockKit do
  @moduledoc false

  alias Ankole.Plugins.SlackAdapter.{MapHelpers, Mrkdwn}

  @spec render(map()) :: {:ok, [map()]} | {:error, :missing_card_payload}
  def render(payload) when is_map(payload) do
    cond do
      notice = Map.get(payload, "control_notice") ->
        {:ok, notice_blocks(notice, false)}

      notice = Map.get(payload, "progress_notice") ->
        {:ok, notice_blocks(notice, true)}

      is_list(Map.get(payload, "slack_native_blocks")) ->
        {:ok, payload["slack_native_blocks"]}

      is_map(Map.get(payload, "interactive_output")) ->
        render_interactive(payload["interactive_output"])

      true ->
        {:error, :missing_card_payload}
    end
  end

  @spec split_blocks([map()]) :: [[map()]]
  def split_blocks(blocks), do: Enum.chunk_every(blocks, 50)

  defp notice_blocks(notice, progress?) do
    text = notice_text(notice)

    context = %{
      "type" => "context",
      "elements" => [%{"type" => "mrkdwn", "text" => Mrkdwn.from_markdown(text)}]
    }

    if progress?, do: [%{"type" => "divider"}, context], else: [context]
  end

  defp notice_text(notice) when is_binary(notice), do: notice

  defp notice_text(notice) when is_map(notice),
    do: Map.get(notice, "text") || Map.get(notice, "message") || ""

  defp notice_text(_notice), do: ""

  defp render_interactive(output) do
    blocks =
      []
      |> add_title(MapHelpers.optional_text(output, "title"))
      |> add_body(body_text(output))
      |> add_facts(MapHelpers.fetch_list(output, "facts"))
      |> add_choices(MapHelpers.fetch_list(output, "choices"))
      |> add_state(MapHelpers.optional_text(output, "state"))

    {:ok, blocks}
  end

  defp add_title(blocks, nil), do: blocks

  defp add_title(blocks, title) do
    blocks ++
      [%{"type" => "header", "text" => %{"type" => "plain_text", "text" => truncate(title, 150)}}]
  end

  defp body_text(output) do
    MapHelpers.optional_text(output, "body") ||
      MapHelpers.optional_text(output, "text") ||
      MapHelpers.optional_text(output, "fallback_visible_text")
  end

  defp add_body(blocks, nil), do: blocks

  defp add_body(blocks, body) do
    sections =
      body
      |> Mrkdwn.from_markdown()
      |> split_text(3_000)
      |> Enum.map(&%{"type" => "section", "text" => %{"type" => "mrkdwn", "text" => &1}})

    blocks ++ sections
  end

  defp add_facts(blocks, facts) do
    sections =
      facts
      |> Enum.map(fn fact ->
        label = Map.get(fact, "label", "")
        value = Map.get(fact, "value", "")
        %{"type" => "mrkdwn", "text" => "*#{label}*\n#{Mrkdwn.from_markdown(to_string(value))}"}
      end)
      |> Enum.chunk_every(10)
      |> Enum.map(&%{"type" => "section", "fields" => &1})

    blocks ++ sections
  end

  defp add_choices(blocks, choices) do
    actions =
      choices
      |> Enum.map(fn choice ->
        value = to_string(Map.get(choice, "value", ""))

        %{
          "type" => "button",
          "action_id" => "ankole:choice:" <> value,
          "text" => %{
            "type" => "plain_text",
            "text" => truncate(to_string(Map.get(choice, "label", value)), 75)
          },
          "value" =>
            Torque.encode!(%{"v" => "ankole.interactive_output.action.v1", "value" => value})
        }
      end)
      |> Enum.chunk_every(5)
      |> Enum.map(&%{"type" => "actions", "elements" => &1})

    blocks ++ actions
  end

  defp add_state(blocks, nil), do: blocks

  defp add_state(blocks, state) do
    blocks ++
      [
        %{
          "type" => "context",
          "elements" => [%{"type" => "mrkdwn", "text" => Mrkdwn.from_markdown(state)}]
        }
      ]
  end

  defp split_text(text, size) do
    text |> String.graphemes() |> Enum.chunk_every(size) |> Enum.map(&Enum.join/1)
  end

  defp truncate(text, size), do: text |> String.graphemes() |> Enum.take(size) |> Enum.join()
end
