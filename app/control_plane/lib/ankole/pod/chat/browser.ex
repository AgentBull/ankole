defmodule Ankole.Pod.Chat.Browser do
  @moduledoc "The current human's native conversations and model selection."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.Pod,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:pod)
    allow(:agents, check: :guardrail)
    allow(:teammates, check: :guardrail)
    allow(:update, check: :guardrail)
    allow(:manage_participants, check: :guardrail)
    allow(:answer_interaction, check: :guardrail)
    allow(:list, check: :guardrail)
    allow(:show, check: :guardrail)
    allow(:execution, check: :guardrail)
    allow(:create, check: :guardrail)
    allow(:post_message, check: :guardrail)
    allow(:update_queue, check: :guardrail)
    allow(:delete, check: :guardrail)
    allow(:model_profiles, check: :guardrail)
    allow(:model_selection, check: :guardrail)
    allow(:set_model_selection, check: :guardrail)
  end

  alias Ankole.Conversations
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
      constraints(fields: [agents: [type: {:array, Ankole.Pod.Chat.Member}, allow_nil?: false]])

      run(fn _input, context ->
        {:ok, %{agents: Enum.map(Conversations.agents(context.actor), &Presentation.agent/1)}}
      end)
    end

    action :teammates, :map do
      constraints(
        fields: [teammates: [type: {:array, Ankole.Pod.Chat.Member}, allow_nil?: false]]
      )

      argument(:query, :string)

      run(fn input, context ->
        {:ok,
         %{
           teammates:
             Enum.map(
               Conversations.teammates(context.actor, input.arguments[:query]),
               &Presentation.agent/1
             )
         }}
      end)
    end

    action :list, :map do
      constraints(
        fields: [
          conversations: [type: {:array, Conversation}, allow_nil?: false],
          nextCursor: [type: UUIDv7]
        ]
      )

      argument(:pageID, UUIDv7)
      argument(:query, :string)
      argument(:cursor, UUIDv7)
      argument(:limit, :integer, default: 50, constraints: [min: 1, max: 100])
      argument(:order, :atom, default: :pinned, constraints: [one_of: [:pinned, :recent]])

      run(fn input, context ->
        limit = input.arguments.limit

        rows =
          Conversations.list_rooms(context.actor,
            page_id: input.arguments[:pageID],
            query: input.arguments[:query],
            cursor: input.arguments[:cursor],
            order: input.arguments.order,
            limit: limit + 1
          )

        items = Enum.take(rows, limit)

        {:ok,
         %{
           conversations: Presentation.conversations(items),
           nextCursor: if(length(rows) > limit, do: List.last(items).conversation.id)
         }}
      end)
    end

    action :update, Detail do
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:title, :string, constraints: [trim?: false, allow_empty?: true])
      argument(:accessScope, :atom, constraints: [one_of: [:participants, :anchor_page]])
      argument(:pinned, :boolean)
      argument(:muted, :boolean)
      argument(:lastReadSeq, :integer, constraints: [min: 0])

      run(fn input, context ->
        attrs = input.arguments

        Conversations.update_conversation(context.actor, attrs.id, %{
          title: attrs[:title],
          access_scope: attrs[:accessScope],
          pinned: attrs[:pinned],
          muted: attrs[:muted],
          last_read_seq: attrs[:lastReadSeq]
        })
        |> APIError.result(&Presentation.detail/1)
      end)
    end

    action :manage_participants, :boolean do
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:addUIDs, {:array, PrincipalKey})
      argument(:removeUIDs, {:array, PrincipalKey})
      argument(:agentUID, PrincipalKey)
      argument(:mayIntervene, :boolean)

      run(fn input, context ->
        attrs = input.arguments

        Conversations.manage_participants(context.actor, attrs.id, %{
          add_uids: attrs[:addUIDs],
          remove_uids: attrs[:removeUIDs],
          agent_uid: attrs[:agentUID],
          may_intervene: attrs[:mayIntervene]
        })
        |> APIError.result(fn _ -> true end)
      end)
    end

    action :answer_interaction, Detail do
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:interaction_id, :string, allow_nil?: false)
      argument(:choiceID, :string)
      argument(:text, :string, constraints: [trim?: false])
      argument(:links, {:array, Ankole.Pod.Chat.Link})
      argument(:attachments, {:array, :string})
      argument(:mentions, {:array, Ankole.Pod.Chat.Mention})

      run(fn input, context ->
        attrs = input.arguments

        Conversations.answer_interaction(context.actor, attrs.id, attrs.interaction_id, %{
          choice_id: attrs[:choiceID],
          answer_text: attrs[:text],
          attachments: attrs[:attachments],
          mentions: mentions(attrs),
          links: links(attrs)
        })
        |> APIError.result(&Presentation.detail/1)
      end)
    end

    action :show, Detail do
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:loadedFirstSeq, :integer, constraints: [min: 1])
      argument(:beforeSeq, :integer, constraints: [min: 1])

      run(fn input, context ->
        Conversations.get(context.actor, input.arguments.id,
          before_seq: input.arguments[:beforeSeq],
          loaded_first_seq: input.arguments[:loadedFirstSeq]
        )
        |> APIError.result(&Presentation.detail/1)
      end)
    end

    action :execution, :map do
      constraints(
        fields: [
          text: [
            type: :string,
            allow_nil?: false,
            constraints: [trim?: false, allow_empty?: true]
          ],
          nextCursor: [type: :string]
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)

      argument(:kind, :atom,
        allow_nil?: false,
        constraints: [one_of: [:background_agent_job, :workflow]]
      )

      argument(:run_id, :integer,
        allow_nil?: false,
        constraints: [min: Ankole.ModelIntegerID.minimum(), max: Ankole.ModelIntegerID.maximum()]
      )

      argument(:cursor, :string)

      run(fn input, context ->
        attrs = input.arguments

        Presentation.execution(context.actor, attrs.id, attrs.kind, attrs.run_id, attrs[:cursor])
        |> APIError.result()
      end)
    end

    action :create, Detail do
      argument(:conversationID, UUIDv7, allow_nil?: false)
      argument(:messageID, UUIDv7, allow_nil?: false)
      argument(:agentUID, PrincipalKey)
      argument(:agentUIDs, {:array, PrincipalKey})
      argument(:participantUIDs, {:array, PrincipalKey})
      argument(:accessScope, :atom, constraints: [one_of: [:participants, :anchor_page]])
      argument(:text, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])
      argument(:pageID, UUIDv7)
      argument(:modelProfile, :string)
      argument(:deliveryMode, :atom, constraints: [one_of: [:steer, :queue]])
      argument(:attachments, {:array, :string})
      argument(:targetAgentUID, PrincipalKey)

      argument(:mentions, {:array, Ankole.Pod.Chat.Mention})

      argument(:links, {:array, Ankole.Pod.Chat.Link})

      run(fn input, context ->
        Conversations.create(context.actor, creation(input.arguments))
        |> APIError.result(&Presentation.detail/1)
      end)
    end

    action :post_message, Detail do
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:messageID, UUIDv7, allow_nil?: false)
      argument(:text, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])
      argument(:deliveryMode, :atom, constraints: [one_of: [:steer, :queue]])
      argument(:attachments, {:array, :string})
      argument(:targetAgentUID, PrincipalKey)

      argument(:mentions, {:array, Ankole.Pod.Chat.Mention})

      argument(:links, {:array, Ankole.Pod.Chat.Link})

      run(fn input, context ->
        Conversations.post(context.actor, input.arguments.id, message(input.arguments))
        |> APIError.result(&Presentation.detail/1)
      end)
    end

    action :update_queue, Detail do
      argument(:id, UUIDv7, allow_nil?: false)

      argument(:action, :atom,
        allow_nil?: false,
        constraints: [
          one_of: [
            :edit,
            :steer,
            :retract,
            :reorder,
            :stop,
            :resume,
            :regenerate,
            :edit_last
          ]
        ]
      )

      argument(:messageID, UUIDv7)
      argument(:messageIDs, {:array, UUIDv7})
      argument(:agentUID, PrincipalKey, allow_nil?: false)
      argument(:text, :string, constraints: [trim?: false, allow_empty?: true])
      argument(:commandID, UUIDv7)
      argument(:expectedVersion, :string)
      argument(:expectedText, :string, constraints: [trim?: false, allow_empty?: true])

      argument(:links, {:array, Ankole.Pod.Chat.Link})
      argument(:expectedLinks, {:array, Ankole.Pod.Chat.Link})
      argument(:mentions, {:array, Ankole.Pod.Chat.Mention})
      argument(:expectedMentions, {:array, Ankole.Pod.Chat.Mention})

      run(fn input, context ->
        Conversations.update_queue(context.actor, input.arguments.id, queue(input.arguments))
        |> APIError.result(&Presentation.detail/1)
      end)
    end

    action :delete, :boolean do
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:forceStop, :boolean, default: false)

      run(fn input, context ->
        Conversations.delete(context.actor, input.arguments.id,
          force_stop: input.arguments.forceStop
        )
        |> APIError.result(fn _ -> true end)
      end)
    end

    action :model_profiles, :map do
      constraints(fields: [profiles: @profiles])
      argument(:uid, PrincipalKey, allow_nil?: false)

      run(fn input, context ->
        APIError.result(Conversations.model_profiles(context.actor, input.arguments.uid))
      end)
    end

    action :model_selection, :map do
      constraints(fields: @selection)
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:agentUID, PrincipalKey)

      run(fn input, context ->
        Conversations.model_preferences(
          context.actor,
          input.arguments.id,
          input.arguments[:agentUID]
        )
        |> APIError.result(&selection/1)
      end)
    end

    action :set_model_selection, :map do
      constraints(fields: @selection)
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:profile, :string)
      argument(:agentUID, PrincipalKey)

      run(fn input, context ->
        Conversations.set_model_profile(
          context.actor,
          input.arguments.id,
          input.arguments[:profile],
          input.arguments[:agentUID]
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
      delivery_mode: string(attrs[:deliveryMode]),
      mentions: mentions(attrs),
      links: links(attrs),
      target_agent_uid: attrs[:targetAgentUID]
    }

  defp creation(attrs),
    do:
      Map.merge(message(attrs), %{
        conversation_id: attrs.conversationID,
        agent_uid: attrs[:agentUID],
        agent_uids: attrs[:agentUIDs],
        participant_uids: attrs[:participantUIDs],
        access_scope: attrs[:accessScope],
        page_id: attrs[:pageID],
        model_profile: attrs[:modelProfile]
      })

  defp queue(attrs),
    do: %{
      action: to_string(attrs.action),
      agent_uid: attrs[:agentUID],
      message_id: attrs[:messageID],
      message_ids: attrs[:messageIDs],
      text: attrs[:text],
      command_id: attrs[:commandID],
      expected_version: attrs[:expectedVersion],
      expected_text: attrs[:expectedText],
      links: attrs[:links],
      expected_links: attrs[:expectedLinks],
      mentions: if(attrs[:mentions], do: mentions(attrs)),
      expected_mentions:
        if(attrs[:expectedMentions], do: mentions(%{mentions: attrs[:expectedMentions]}))
    }

  defp string(nil), do: nil
  defp string(value), do: to_string(value)

  defp links(attrs) do
    Enum.map(attrs[:links] || [], fn link ->
      link
      |> Ankole.Attrs.normalize_external_attrs()
      |> Map.update!("kind", &string/1)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
    end)
  end

  defp mentions(attrs),
    do: Enum.map(attrs[:mentions] || [], &Map.update!(&1, :type, fn type -> string(type) end))
end
