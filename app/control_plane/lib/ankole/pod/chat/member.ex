defmodule Ankole.Pod.Chat.Member do
  @moduledoc "A room member and the Agent's current conversation settings."
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        uid: [type: Ankole.Ash.Types.PrincipalKey, allow_nil?: false],
        displayName: [type: :string, allow_nil?: false],
        avatarURL: [type: :string],
        type: [type: :string, allow_nil?: false],
        agentType: [type: :string],
        aliases: [type: {:array, :string}],
        role: [type: :string],
        canChat: [type: :boolean],
        active: [type: :boolean, allow_nil?: false],
        mayIntervene: [type: :boolean, allow_nil?: false],
        modelProfile: [type: :string]
      ]
    ]
end
