defmodule Ankole.Conversations.Domain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource(Ankole.Conversations.Conversation)
    resource(Ankole.Conversations.Participant)
    resource(Ankole.Conversations.Message)
    resource(Ankole.Conversations.ExternalMessageRef)
    resource(Ankole.Conversations.InputTombstone)
    resource(Ankole.Conversations.InboundBatch)
    resource(Ankole.Conversations.Delivery.PreviewState)
    resource(Ankole.Conversations.Delivery.Intent)
  end
end
