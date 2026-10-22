defmodule Ankole.AIGateway.Domain do
  @moduledoc "Durable AIGateway artifacts and provider usage."
  use Ash.Domain

  resources do
    resource(Ankole.AIGateway.Schemas.Artifact)
    resource(Ankole.AIGateway.Schemas.CompactionArtifact)
    resource(Ankole.AIGateway.Schemas.UsageRecord)
    resource(Ankole.AIGateway.Schemas.Conversation)
    resource(Ankole.AIGateway.Schemas.Message)
  end
end
