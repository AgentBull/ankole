defmodule Ankole.Repo.Migrations.DefaultAzureOpenAIToResponses do
  use Ecto.Migration

  # Azure OpenAI connections default to the Responses endpoint, because current
  # OpenAI reasoning models such as gpt-6.1-sol reject function tools with
  # reasoning on Chat Completions, and every Agent request carries tools. The
  # Console stored the former `chat_completions` default on each connection it
  # created, so those rows move to Responses too. An operator who serves a
  # model that only speaks Chat Completions selects it again in the connection
  # settings.
  def up do
    execute("""
    UPDATE ai_gateway_providers
    SET connection_options = connection_options || '{"endpoint_kind": "responses"}'::jsonb
    WHERE provider_kind = 'azure_openai'
      AND coalesce(connection_options->>'endpoint_kind', 'chat_completions') = 'chat_completions'
    """)
  end

  # Rows that chose Responses on purpose cannot be told apart from moved rows.
  def down, do: :ok
end
