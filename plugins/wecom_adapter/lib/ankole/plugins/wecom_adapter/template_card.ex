defmodule Ankole.Plugins.WeComAdapter.TemplateCard do
  @moduledoc """
  Template-card rendering for the non-streaming `card` outbox operation.

  WeCom template cards are plain JSON payloads (no console-hosted template),
  but their buttons round-trip only a `key` string — no structured value — so
  the portable `ankole.interactive_output.action.v1` protocol is packed into
  a JSON list in the key (`ank2:` prefix) and the source
  actor event rides `task_id` (`ankole:<event id>`). `Inbound` unpacks both on
  the `template_card_event`.

  Choice interactions render as a `button_interaction` card. Free-text form
  interactions and already-settled interactions have no card carrier (no input
  control, no disabled buttons), so they deliver the row's
  `fallback_visible_text` as Markdown instead — same degrade honesty as the
  DingTalk template-missing path.
  """

  alias Ankole.Plugins.MapHelpers
  alias Ankole.Plugins.WeComAdapter.Markdown
  alias Ankole.SignalsGateway.OutboxEntry
  alias WeComOpenAPI.Bot

  import MapHelpers, only: [fetch_list: 2, fetch_value: 2, optional_text: 2]

  # The platform documents at most six buttons on a button_interaction card.
  @max_buttons 6
  @max_key_bytes 1024
  @title_budget 40

  @type delivery :: %{
          chat_target: String.t(),
          chat_type: 1 | 2,
          respond_req_id: String.t() | nil
        }

  @doc "Delivers one `card` outbox operation as a template card (or Markdown fallback)."
  @spec deliver(GenServer.server(), delivery(), OutboxEntry.t()) ::
          {:ok, map()} | {:error, term()}
  def deliver(client, delivery, %OutboxEntry{} = outbox) do
    output = fetch_value(outbox.payload || %{}, "interactive_output") || %{}

    case render(output, outbox) do
      {:card, task_id, card} ->
        client
        |> send_card(delivery, card)
        |> card_result(task_id)

      :fallback ->
        send_fallback_text(client, delivery, outbox)
    end
  end

  @doc false
  @spec render(map(), OutboxEntry.t()) :: {:card, String.t(), map()} | :fallback
  def render(output, %OutboxEntry{} = outbox) do
    interaction_id = optional_text(output, "interaction_id")
    control_id = optional_text(output, "control_id") || "choice"
    source_actor_event_id = optional_text(output, "source_actor_event_id")
    version = integer_value(fetch_value(output, "version")) || 1
    locked? = optional_text(output, "state") in ["answered", "expired", "cancelled", "superseded"]

    buttons =
      output
      |> fetch_list("choices")
      |> Enum.flat_map(&button_descriptor(&1, interaction_id, version, control_id))
      |> Enum.take(@max_buttons)

    cond do
      locked? or buttons == [] or is_nil(source_actor_event_id) or
          Enum.any?(buttons, &(byte_size(&1["key"]) > @max_key_bytes)) ->
        :fallback

      true ->
        task_id = "ankole:#{source_actor_event_id}"

        {:card, task_id,
         %{
           "card_type" => "button_interaction",
           "main_title" => %{"title" => card_title(output, outbox)},
           "sub_title_text" => card_body(output, outbox),
           "task_id" => task_id,
           "button_list" => buttons
         }}
    end
  end

  defp button_descriptor(choice, interaction_id, version, control_id) do
    option_id = optional_text(choice, "id") || optional_text(choice, "option_id")
    label = optional_text(choice, "label") || optional_text(choice, "text") || option_id

    if is_binary(option_id) and is_binary(label) and is_binary(interaction_id) do
      option_value = to_string(fetch_value(choice, "value") || option_id)

      [
        %{
          "text" => label,
          "style" => 1,
          "key" =>
            "ank2:" <>
              Torque.encode!([interaction_id, version, control_id, option_id, option_value])
        }
      ]
    else
      []
    end
  end

  @doc false
  def parse_managed_key("ank2:" <> json) when byte_size(json) <= @max_key_bytes - 5 do
    case Torque.decode(json) do
      {:ok, [interaction, version, control, option, value]}
      when is_binary(interaction) and is_integer(version) and is_binary(control) and
             is_binary(option) and is_binary(value) ->
        {:ok, action_value(interaction, version, control, option, value)}

      _invalid ->
        :unmanaged
    end
  end

  # Already sent cards can still deliver their original callback key.
  def parse_managed_key("ank1|" <> rest) do
    case String.split(rest, "|") do
      [interaction, version, control, option, value] ->
        {:ok, action_value(interaction, parse_integer(version), control, option, value)}

      _invalid ->
        :unmanaged
    end
  end

  def parse_managed_key(_key), do: :unmanaged

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> 0
    end
  end

  defp action_value(interaction, version, control, option, value) do
    %{
      "version" => Ankole.SignalsGateway.ReplyPresentation.action_protocol(),
      "answerKind" => "choice",
      "interactionId" => interaction,
      "interactionVersion" => version,
      "controlId" => control,
      "selectedOptionId" => option,
      "optionValue" => value
    }
  end

  defp card_title(output, outbox) do
    text =
      optional_text(output, "title") || optional_text(output, "body") ||
        to_string(outbox.fallback_visible_text)

    text
    |> String.split("\n", parts: 2)
    |> List.first()
    |> to_string()
    |> String.replace(~r/^#+\s*/, "")
    |> String.trim()
    |> case do
      "" -> "请选择"
      line -> String.slice(line, 0, @title_budget)
    end
  end

  defp card_body(output, outbox) do
    body =
      optional_text(output, "body") || optional_text(output, "text") ||
        to_string(outbox.fallback_visible_text)

    String.slice(body, 0, 160)
  end

  defp send_card(client, %{respond_req_id: req_id}, card) when is_binary(req_id) do
    Bot.reply_template_card(client, req_id, card)
  end

  defp send_card(client, delivery, card) do
    Bot.send_template_card(client, delivery.chat_target, delivery.chat_type, card)
  end

  defp card_result({:ok, ack}, task_id) do
    {:ok, %{created_source_entry_id: task_id, raw_payload: ack}}
  end

  defp card_result({:error, _reason} = error, _task_id), do: error

  defp send_fallback_text(client, delivery, outbox) do
    content =
      outbox.fallback_visible_text
      |> to_string()
      |> Markdown.to_wecom()

    result =
      case delivery do
        %{respond_req_id: req_id} when is_binary(req_id) ->
          Bot.reply_markdown(client, req_id, content)

        _proactive ->
          Bot.send_markdown(client, delivery.chat_target, delivery.chat_type, content)
      end

    case result do
      {:ok, ack} ->
        {:ok,
         %{
           created_source_entry_id:
             "wecom:card-fallback:#{outbox.idempotency_key || outbox.outbound_key}",
           synthetic_entry_id: true,
           raw_payload: ack
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(_value), do: nil
end
