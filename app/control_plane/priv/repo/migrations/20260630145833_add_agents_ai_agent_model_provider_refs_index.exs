defmodule Ankole.Repo.Migrations.AddAgentsAiAgentModelProviderRefsIndex do
  use Ecto.Migration

  def change do
    execute(
      """
      CREATE INDEX agents_ai_agent_model_provider_ids_index
      ON agents
      USING gin (
        (jsonb_path_query_array(options, 'lax $.ai_agent.models.*.provider_id'::jsonpath))
        jsonb_path_ops
      )
      """,
      "DROP INDEX agents_ai_agent_model_provider_ids_index"
    )
  end
end
