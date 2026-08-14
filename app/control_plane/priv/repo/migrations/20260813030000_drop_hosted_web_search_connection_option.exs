defmodule Ankole.Repo.Migrations.DropHostedWebSearchConnectionOption do
  use Ecto.Migration

  # Hosted web search is part of the OpenAI Responses protocol, so a connection
  # that declares `endpoint_kind = "responses"` already states it. The separate
  # `hosted_web_search` switch said the same thing a second time, and the write
  # path only ever accepted it together with that endpoint kind. Whether an Agent
  # uses the capability is now the Agent's own setting.
  def up do
    execute("""
    UPDATE ai_gateway_providers
    SET connection_options = connection_options - 'hosted_web_search'
    WHERE jsonb_typeof(connection_options) = 'object'
      AND connection_options ? 'hosted_web_search'
    """)
  end

  # The option no longer exists, so restoring it would write a value the write
  # path rejects as an unknown key.
  def down, do: :ok
end
