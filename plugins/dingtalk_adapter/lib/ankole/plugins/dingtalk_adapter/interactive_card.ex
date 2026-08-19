defmodule Ankole.Plugins.DingTalkAdapter.InteractiveCard do
  @moduledoc """
  Template-hosted rendering for DingTalk card instances.

  DingTalk cards cannot be composed as free-form JSON: the operator builds the
  standard Ankole AI card template on the card platform (variable schema in
  `priv/card_template/README.md`) and every instance only injects that fixed
  variable set. This module owns the `cardParamMap` rendering shared by the
  streaming `AICard` lifecycle and the non-streaming `card` outbox operation,
  finalizes a non-streaming card through DingTalk's native AI card lifecycle,
  and owns the open-space/deliver models derived from a `{:dm, userid}` or
  `{:group, conversation_id}` target.

  Action buttons are rendered as a structured JSON list bound to the template's
  action area. Each button submits its `value` map verbatim, so a card callback
  round-trips the portable `ankole.interactive_output.action.v1` protocol
  instead of a folded display string.
  """

  alias Ankole.Plugins.DingTalkAdapter.Markdown
  alias Ankole.Plugins.MapHelpers
  alias Ankole.SignalsGateway.OutboxEntry
  alias DingTalkOpenAPI.Card
  alias DingTalkOpenAPI.Client
  alias DingTalkOpenAPI.Error

  import MapHelpers, only: [fetch_list: 2, fetch_value: 2, optional_text: 2]

  @action_value_version "ankole.interactive_output.action.v1"

  @type space :: {:dm, String.t()} | {:group, String.t()}

  # --- card outbox operation ------------------------------------------------

  @doc """
  Delivers one non-streaming `card` outbox operation as a card instance.

  The instance is keyed by an `outTrackId` derived from the outbox idempotency
  key, so an outbox retry re-delivers the same instance instead of a duplicate.
  """
  @spec deliver(Client.t(), String.t(), String.t(), space(), OutboxEntry.t()) ::
          {:ok, map()} | {:error, Error.t() | term()}
  def deliver(%Client{} = client, template_id, robot_code, space, %OutboxEntry{} = outbox) do
    out_track_id = "ankole:outbox:#{outbox.idempotency_key || outbox.outbound_key}"
    card_param_map = outbox_param_map(outbox)

    params =
      %{
        "cardTemplateId" => template_id,
        "outTrackId" => out_track_id,
        "callbackType" => "STREAM",
        "cardData" => %{"cardParamMap" => card_param_map}
      }
      |> Map.merge(create_model(space))
      |> Map.merge(deliver_model(space, robot_code))

    with {:ok, body} <- Card.create_and_deliver(client, params),
         {:ok, _stream_body} <- finalize(client, out_track_id, card_param_map["answer"]) do
      {:ok, %{created_source_entry_id: out_track_id, raw_payload: body}}
    end
  end

  defp outbox_param_map(%OutboxEntry{payload: payload, fallback_visible_text: fallback}) do
    output = fetch_value(payload || %{}, "interactive_output") || %{}

    body =
      optional_text(output, "body") || optional_text(output, "text") ||
        fallback || ""

    %{
      "state" => optional_text(output, "state") || "",
      "answer" => Markdown.display_chunk(body),
      "thought" => "",
      "plan" => "",
      "activity" => "",
      "results" => "",
      "receipts" => "",
      "actions" => render_output_actions(output),
      "meta" => ""
    }
  end

  # A card outbox row carries a finished payload. Creating an AI card starts its
  # native lifecycle, so one full streaming update displays the answer and moves
  # the instance to its completed state. The content-derived guid makes retries
  # idempotent without adding another durable ledger.
  defp finalize(client, out_track_id, answer) do
    Card.streaming_update(client, %{
      "outTrackId" => out_track_id,
      "guid" => stream_guid(out_track_id, answer),
      "key" => "answer",
      "content" => answer,
      "isFull" => true,
      "isFinalize" => true,
      "isError" => false
    })
  end

  defp stream_guid(out_track_id, answer) do
    :crypto.hash(:sha256, "#{out_track_id}:completed:#{answer}")
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
  end

  # A `card` outbox payload carries the portable interaction output shape
  # (`choices` + interaction ids), not presentation actions.
  defp render_output_actions(output) do
    interaction_id = optional_text(output, "interaction_id")
    control_id = optional_text(output, "control_id") || "choice"
    source_actor_event_id = optional_text(output, "source_actor_event_id")
    version = integer_value(fetch_value(output, "version")) || 1
    locked? = optional_text(output, "state") in ["answered", "expired", "cancelled", "superseded"]

    output
    |> fetch_list("choices")
    |> Enum.flat_map(fn choice ->
      option_id = optional_text(choice, "id") || optional_text(choice, "option_id")
      label = optional_text(choice, "label") || optional_text(choice, "text") || option_id

      if is_binary(option_id) and is_binary(label) and is_binary(interaction_id) and
           is_binary(source_actor_event_id) do
        [
          %{
            "id" => option_id,
            "label" => label,
            "style" => "default",
            "disabled" => locked?,
            "value" => %{
              "version" => @action_value_version,
              "answerKind" => "choice",
              "interactionId" => interaction_id,
              "interactionVersion" => version,
              "controlId" => control_id,
              "selectedOptionId" => option_id,
              "optionValue" => to_string(fetch_value(choice, "value") || option_id),
              "sourceActorEventId" => source_actor_event_id
            }
          }
        ]
      else
        []
      end
    end)
    |> encode_actions()
  end

  # --- presentation actions ---------------------------------------------------

  @doc """
  Renders normalized presentation actions into the template's `actions` JSON
  variable. Buttons and single-input forms carry the full portable callback
  value; actions missing protocol fields render nothing rather than a dead
  control.
  """
  @spec render_presentation_actions([map()]) :: String.t()
  def render_presentation_actions(actions) when is_list(actions) do
    actions
    |> Enum.flat_map(&presentation_action_descriptor/1)
    |> encode_actions()
  end

  def render_presentation_actions(_actions), do: ""

  defp presentation_action_descriptor(
         %{
           "type" => "button",
           "id" => id,
           "label" => label,
           "interaction_id" => interaction_id,
           "source_actor_event_id" => source_actor_event_id,
           "control_id" => control_id,
           "selected_option_id" => selected_option_id,
           "option_value" => option_value,
           "revision" => revision
         } = action
       )
       when is_binary(id) and is_binary(label) and is_binary(interaction_id) and
              is_binary(source_actor_event_id) and is_binary(control_id) and
              is_binary(selected_option_id) and is_binary(option_value) and
              is_integer(revision) do
    [
      %{
        "id" => id,
        "label" => if(action["selected"], do: "#{label}（已选择）", else: label),
        "style" => action["style"] || "default",
        "disabled" => action["disabled"] == true,
        "value" => %{
          "version" => @action_value_version,
          "answerKind" => "choice",
          "interactionId" => interaction_id,
          "interactionVersion" => revision,
          "controlId" => control_id,
          "selectedOptionId" => selected_option_id,
          "optionValue" => option_value,
          "sourceActorEventId" => source_actor_event_id
        }
      }
    ]
  end

  defp presentation_action_descriptor(
         %{
           "type" => "form",
           "id" => id,
           "label" => label,
           "interaction_id" => interaction_id,
           "source_actor_event_id" => source_actor_event_id,
           "control_id" => control_id,
           "revision" => revision,
           "fields" => [%{"type" => "input", "id" => input_name} = field]
         } = action
       )
       when is_binary(id) and is_binary(label) and is_binary(interaction_id) and
              is_binary(source_actor_event_id) and is_binary(control_id) and
              is_integer(revision) and is_binary(input_name) do
    if action["disabled"] == true do
      []
    else
      [
        %{
          "id" => id,
          "label" => label,
          "style" => action["style"] || "primary",
          "disabled" => false,
          "input" => %{
            "name" => input_name,
            "placeholder" => field["placeholder"] || "",
            "required" => field["required"] == true
          },
          "value" => %{
            "version" => @action_value_version,
            "answerKind" => "free_text",
            "interactionId" => interaction_id,
            "interactionVersion" => revision,
            "controlId" => control_id,
            "inputName" => input_name,
            "sourceActorEventId" => source_actor_event_id
          }
        }
      ]
    end
  end

  defp presentation_action_descriptor(_action), do: []

  defp encode_actions([]), do: ""
  defp encode_actions(descriptors), do: Ankole.JSON.encode!(descriptors)

  # --- open space -------------------------------------------------------------

  @doc "Create-time open-space model for a card instance."
  @spec create_model(space()) :: map()
  def create_model({:group, _conversation_id}),
    do: %{"imGroupOpenSpaceModel" => %{"supportForward" => true}}

  def create_model({:dm, _userid}),
    do: %{"imRobotOpenSpaceModel" => %{"supportForward" => true}}

  @doc "Deliver-time open-space id and deliver model for a card instance."
  @spec deliver_model(space(), String.t()) :: map()
  def deliver_model({:group, conversation_id}, robot_code) do
    %{
      "openSpaceId" => "dtv1.card//IM_GROUP.#{conversation_id}",
      "imGroupOpenDeliverModel" => %{"robotCode" => robot_code}
    }
  end

  def deliver_model({:dm, userid}, robot_code) do
    %{
      "openSpaceId" => "dtv1.card//IM_ROBOT.#{userid}",
      "imRobotOpenDeliverModel" => %{"spaceType" => "IM_ROBOT", "robotCode" => robot_code}
    }
  end

  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(_value), do: nil
end
