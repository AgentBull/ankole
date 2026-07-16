defmodule Ankole.Repo.Migrations.AddSubagentTurnRuntimeSnapshot do
  use Ecto.Migration

  def up do
    alter table(:subagent_delegation_turns) do
      add :progress, :map,
        null: false,
        default: %{
          "completed_items" => 0,
          "tool_calls" => 0,
          "tools_used" => [],
          "files_changed" => []
        }
    end

    execute("""
    UPDATE subagent_delegation_turns
    SET usage = CASE
      WHEN usage IS NULL OR usage = '{}'::jsonb THEN NULL
      WHEN usage ? 'thread_total' AND usage ? 'last_model_call' THEN usage
      ELSE jsonb_strip_nulls(jsonb_build_object(
        'thread_total', jsonb_build_object(
          'total_tokens', COALESCE((COALESCE(usage->'total', usage->'last')->>'totalTokens')::bigint, 0),
          'input_tokens', COALESCE((COALESCE(usage->'total', usage->'last')->>'inputTokens')::bigint, 0),
          'cached_input_tokens', COALESCE((COALESCE(usage->'total', usage->'last')->>'cachedInputTokens')::bigint, 0),
          'output_tokens', COALESCE((COALESCE(usage->'total', usage->'last')->>'outputTokens')::bigint, 0),
          'reasoning_output_tokens', COALESCE((COALESCE(usage->'total', usage->'last')->>'reasoningOutputTokens')::bigint, 0)
        ),
        'last_model_call', jsonb_build_object(
          'total_tokens', COALESCE((COALESCE(usage->'last', usage->'total')->>'totalTokens')::bigint, 0),
          'input_tokens', COALESCE((COALESCE(usage->'last', usage->'total')->>'inputTokens')::bigint, 0),
          'cached_input_tokens', COALESCE((COALESCE(usage->'last', usage->'total')->>'cachedInputTokens')::bigint, 0),
          'output_tokens', COALESCE((COALESCE(usage->'last', usage->'total')->>'outputTokens')::bigint, 0),
          'reasoning_output_tokens', COALESCE((COALESCE(usage->'last', usage->'total')->>'reasoningOutputTokens')::bigint, 0)
        ),
        'model_context_window', CASE
          WHEN jsonb_typeof(usage->'modelContextWindow') = 'number' THEN usage->'modelContextWindow'
          ELSE NULL
        END
      ))
    END
    """)

    alter table(:subagent_delegation_turns) do
      modify :usage, :map, null: true, default: nil, from: {:map, null: false, default: %{}}
      remove :last_activity_at, :utc_datetime_usec
    end

    create constraint(:subagent_delegation_turns, :subagent_delegation_turns_progress_object,
             check: "jsonb_typeof(progress) = 'object'"
           )
  end

  def down do
    drop constraint(:subagent_delegation_turns, :subagent_delegation_turns_progress_object)

    alter table(:subagent_delegation_turns) do
      add :last_activity_at, :utc_datetime_usec
    end

    execute("""
    UPDATE subagent_delegation_turns
    SET
      last_activity_at = updated_at,
      usage = CASE
        WHEN usage IS NULL THEN '{}'::jsonb
        ELSE jsonb_strip_nulls(jsonb_build_object(
          'total', jsonb_build_object(
            'totalTokens', usage->'thread_total'->'total_tokens',
            'inputTokens', usage->'thread_total'->'input_tokens',
            'cachedInputTokens', usage->'thread_total'->'cached_input_tokens',
            'outputTokens', usage->'thread_total'->'output_tokens',
            'reasoningOutputTokens', usage->'thread_total'->'reasoning_output_tokens'
          ),
          'last', jsonb_build_object(
            'totalTokens', usage->'last_model_call'->'total_tokens',
            'inputTokens', usage->'last_model_call'->'input_tokens',
            'cachedInputTokens', usage->'last_model_call'->'cached_input_tokens',
            'outputTokens', usage->'last_model_call'->'output_tokens',
            'reasoningOutputTokens', usage->'last_model_call'->'reasoning_output_tokens'
          ),
          'modelContextWindow', usage->'model_context_window'
        ))
      END
    """)

    alter table(:subagent_delegation_turns) do
      modify :last_activity_at, :utc_datetime_usec, null: false
      modify :usage, :map, null: false, default: %{}, from: {:map, null: true, default: nil}
      remove :progress, :map
    end
  end
end
