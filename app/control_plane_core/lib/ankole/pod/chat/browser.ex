defmodule Ankole.Pod.Chat.Browser do
  @moduledoc "The current human's native conversations and model selection."
  use Ash.Resource,
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.Pod,
    extensions: [AshJsonApi.Resource]

  alias Ankole.Conversations
  alias Ankole.Conversations.ModelPreferences
  alias Ankole.Pod.Chat.{Detail, Conversation, Presentation}
  alias Ankole.Pod.APIError
  alias Ankole.Ash.Types.{UUIDv7, PrincipalKey}

  @profiles [
    type: {:array, :map},
    allow_nil?: false,
    constraints: [
      items: [
        fields: [
          name: [type: :string, allow_nil?: false],
          description: [type: :string, allow_nil?: false, constraints: [allow_empty?: true]]
        ]
      ]
    ]
  ]
  @selection [profile: [type: :string], activeProfile: [type: :string], profiles: @profiles]

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("pod_chat_operation")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :agents, :map do
      constraints(
        fields: [
          agents: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: [
                  uid: [type: PrincipalKey, allow_nil?: false],
                  displayName: [type: :string, allow_nil?: false]
                ]
              ]
            ]
          ]
        ]
      )

      run(fn _input, _context ->
        {:ok, %{agents: Enum.map(Conversations.agents(), &Presentation.agent/1)}}
      end)
    end

    action :list, :map do
      constraints(fields: [conversations: [type: {:array, Conversation}, allow_nil?: false]])
      argument(:pageID, UUIDv7)

      run(fn input, context ->
        result =
          case input.arguments[:pageID] do
            nil -> {:ok, Conversations.list(context.actor.uid)}
            page -> Conversations.list_for_page(context.actor.uid, page)
          end

        APIError.result(
          result,
          &%{conversations: Enum.map(&1, fn detail -> Presentation.conversation(detail) end)}
        )
      end)
    end

    action :show, Detail do
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:loadedFirstSeq, :integer, constraints: [min: 1])
      argument(:beforeSeq, :integer, constraints: [min: 1])

      run(fn input, context ->
        Conversations.get(context.actor.uid, input.arguments.id,
          before_seq: input.arguments[:beforeSeq],
          loaded_first_seq: input.arguments[:loadedFirstSeq]
        )
        |> APIError.result(&Presentation.detail/1)
      end)
    end

    action :create, Detail do
      argument(:conversationID, UUIDv7, allow_nil?: false)
      argument(:messageID, UUIDv7, allow_nil?: false)
      argument(:agentUID, PrincipalKey, allow_nil?: false)
      argument(:text, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])
      argument(:pageID, UUIDv7)
      argument(:modelProfile, :string)
      argument(:deliveryMode, :atom, constraints: [one_of: [:steer, :queue]])
      argument(:attachments, {:array, :string})

      run(fn input, context ->
        Conversations.create(context.actor.uid, creation(input.arguments))
        |> APIError.result(&Presentation.detail/1)
      end)
    end

    action :post_message, Detail do
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:messageID, UUIDv7, allow_nil?: false)
      argument(:text, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])
      argument(:deliveryMode, :atom, constraints: [one_of: [:steer, :queue]])
      argument(:attachments, {:array, :string})

      run(fn input, context ->
        Conversations.post(context.actor.uid, input.arguments.id, message(input.arguments))
        |> APIError.result(&Presentation.detail/1)
      end)
    end

    action :update_queue, Detail do
      argument(:id, UUIDv7, allow_nil?: false)

      argument(:action, :atom,
        allow_nil?: false,
        constraints: [
          one_of: [:edit, :send_now, :remove, :reorder, :stop, :resume, :regenerate, :edit_last]
        ]
      )

      argument(:messageID, UUIDv7)
      argument(:messageIDs, {:array, UUIDv7})
      argument(:text, :string, constraints: [trim?: false, allow_empty?: true])
      argument(:commandID, UUIDv7)
      argument(:expectedVersion, :string)
      argument(:expectedText, :string, constraints: [trim?: false, allow_empty?: true])

      run(fn input, context ->
        Conversations.update_queue(context.actor.uid, input.arguments.id, queue(input.arguments))
        |> APIError.result(&Presentation.detail/1)
      end)
    end

    action :delete, :boolean do
      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        Conversations.delete(context.actor.uid, input.arguments.id)
        |> APIError.result(fn _ -> true end)
      end)
    end

    action :model_profiles, :map do
      constraints(fields: [profiles: @profiles])
      argument(:uid, PrincipalKey, allow_nil?: false)

      run(fn input, _context ->
        APIError.result(ModelPreferences.catalog(input.arguments.uid))
      end)
    end

    action :model_selection, :map do
      constraints(fields: @selection)
      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        Conversations.model_preferences(context.actor.uid, input.arguments.id)
        |> APIError.result(&selection/1)
      end)
    end

    action :set_model_selection, :map do
      constraints(fields: @selection)
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:profile, :string)

      run(fn input, context ->
        Conversations.set_model_profile(
          context.actor.uid,
          input.arguments.id,
          input.arguments[:profile]
        )
        |> APIError.result(&selection/1)
      end)
    end
  end

  defp selection(value),
    do: %{profile: value.profile, activeProfile: value.active_profile, profiles: value.profiles}

  defp message(attrs),
    do: %{
      message_id: attrs.messageID,
      text: attrs.text,
      attachments: attrs[:attachments],
      delivery_mode: string(attrs[:deliveryMode])
    }

  defp creation(attrs),
    do:
      Map.merge(message(attrs), %{
        conversation_id: attrs.conversationID,
        agent_uid: attrs.agentUID,
        page_id: attrs[:pageID],
        model_profile: attrs[:modelProfile]
      })

  defp queue(attrs),
    do: %{
      action: to_string(attrs.action),
      message_id: attrs[:messageID],
      message_ids: attrs[:messageIDs],
      text: attrs[:text],
      command_id: attrs[:commandID],
      expected_version: attrs[:expectedVersion],
      expected_text: attrs[:expectedText]
    }

  defp string(nil), do: nil
  defp string(value), do: to_string(value)
end
