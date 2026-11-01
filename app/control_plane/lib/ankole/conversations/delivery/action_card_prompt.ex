defmodule Ankole.Conversations.Delivery.ActionCardPrompt do
  @moduledoc """
  Extracts a turn-ending `propose_action_card` tool result into portable interactive
  output and durable Action Card attributes.
  """

  alias Ankole.Conversations.ActionCard
  alias Ankole.Conversations.Delivery.{ReplyPresentation, ToolOutput}
  alias Ankole.Files.Path, as: FilePath

  @tool_name "propose_action_card"
  @action_kinds_list ActionCard.action_kinds()

  @spec from_response_items(term()) :: {:ok, map() | nil} | {:error, term()}
  def from_response_items(items) when is_list(items) do
    call_ids = tool_call_ids(items)

    items
    |> Enum.reduce_while({:ok, nil}, fn
      %{"type" => "function_call_output", "call_id" => call_id, "output" => output}, {:ok, prompt}
      when is_binary(call_id) ->
        if MapSet.member?(call_ids, call_id) do
          case normalize_output(ToolOutput.decode(output), call_id) do
            {:ok, normalized} -> {:cont, {:ok, normalized}}
            :ignore -> {:cont, {:ok, prompt}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        else
          {:cont, {:ok, prompt}}
        end

      _item, acc ->
        {:cont, acc}
    end)
  end

  def from_response_items(_items), do: {:ok, nil}

  defp tool_call_ids(items) do
    Enum.reduce(items, MapSet.new(), fn
      %{"type" => "function_call", "name" => @tool_name, "call_id" => call_id}, acc
      when is_binary(call_id) ->
        MapSet.put(acc, call_id)

      _item, acc ->
        acc
    end)
  end

  defp normalize_output(%{"tool" => @tool_name, "ok" => true} = output, call_id) do
    with {:ok, card_id} <- Ecto.UUID.cast(Map.get(output, "card_id")),
         action_kind when action_kind in @action_kinds_list <- Map.get(output, "action_kind"),
         {:ok, summary} <- sanitize_summary(Map.get(output, "summary")),
         payload when is_map(payload) <- Map.get(output, "payload", %{}),
         preconditions when is_map(preconditions) <- Map.get(output, "preconditions", %{}) do
      interaction_id = "action_card:#{card_id}"
      body = card_body(action_kind, summary, payload)

      choices = [
        %{
          "id" => "confirm",
          "label" => "Confirm & Execute",
          "value" => "confirm",
          "description" => "Verify your permissions and execute this change."
        },
        %{
          "id" => "cancel",
          "label" => "Cancel",
          "value" => "cancel",
          "description" => "Dismiss this proposed change without applying it."
        }
      ]

      fallback =
        ReplyPresentation.clarification_text(
          body,
          choices,
          "Use Confirm & Execute or Cancel on the card to resolve this proposal."
        )

      {:ok,
       %{
         "card_id" => card_id,
         "call_id" => call_id,
         "interaction_id" => interaction_id,
         "action_kind" => action_kind,
         "summary" => summary,
         "target_node_id" => Map.get(output, "target_node_id"),
         "payload" => payload,
         "preconditions" => preconditions,
         "body" => body,
         "fallback_visible_text" => fallback,
         "interactive_output" => %{
           "title" => "Action Confirmation Required",
           "body" => body,
           "fallback_visible_text" => fallback,
           "interaction_id" => interaction_id,
           "control_id" => "action-card-choice",
           "version" => 1,
           "free_input" => false,
           "choices" => choices
         }
       }}
    else
      _invalid -> {:error, {:invalid_action_card_output, call_id}}
    end
  end

  defp normalize_output(_output, _call_id), do: :ignore

  def sanitize_summary(summary) when is_binary(summary) do
    cleaned =
      summary
      |> FilePath.sanitize_inline_text()
      |> String.trim()

    if cleaned != "" and String.length(cleaned) <= 500 do
      {:ok, cleaned}
    else
      {:error, :invalid_summary}
    end
  end

  def sanitize_summary(_summary), do: {:error, :invalid_summary}

  def card_body(action_kind, summary, payload) do
    target_line =
      case action_kind do
        "pod.page.set_sharing" ->
          "Action: Update sharing permissions on \"#{payload["node_title"] || payload["node_id"]}\""

        "pod.page.delete" ->
          "Action: Move \"#{payload["node_title"] || payload["node_id"]}\" to trash"

        "pod.page.restore" ->
          "Action: Restore \"#{payload["node_title"] || payload["node_id"]}\" from trash"

        "pod.base.delete_table" ->
          "Action: Delete Base table \"#{payload["table_name"] || payload["table_id"]}\" in \"#{payload["page_title"] || payload["page_id"]}\""

        "conversation.add_participants" ->
          names =
            (payload["participants"] || [])
            |> Enum.map(&(&1["name"] || &1["uid"]))
            |> Enum.join(", ")

          "Action: Add participants (#{names}) to this conversation"

        _ ->
          "Action: #{action_kind}"
      end

    "#{target_line}\nSummary: #{summary}"
  end

  def tier3_non_interactive_text(prompt, conversation_id) do
    body = prompt["body"] || prompt["summary"] || ""

    approval_url =
      case prompt["card_id"] do
        card_id when is_binary(card_id) and card_id != "" ->
          AnkoleWeb.PodURL.current_tenant_url("/?actionCard=" <> URI.encode_www_form(card_id))

        _ ->
          AnkoleWeb.PodURL.current_tenant_url("/conversations/" <> to_string(conversation_id))
      end

    """
    [Action Confirmation Required]
    #{body}

    This channel does not support interactive approval buttons. Review and confirm or cancel this card in Pod WebUI (#{approval_url}).
    """
    |> String.trim()
  end
end
