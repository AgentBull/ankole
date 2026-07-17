defmodule Ankole.Repo.Migrations.AddBackgroundAgentJobTrajectoryGroups do
  use Ecto.Migration

  def up do
    create table(:background_agent_job_turn_trajectory_groups, primary_key: false) do
      add(
        :turn_id,
        references(:background_agent_job_turns, type: :uuid, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:position, :integer, primary_key: true, null: false)
      add(:revision, :integer, null: false)
      add(:item_key, :text, null: false)
      add(:content, :map, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(:background_agent_job_turn_trajectory_groups, [:turn_id, :item_key],
        name: :background_agent_job_turn_trajectory_groups_item_index
      )
    )

    create(
      constraint(
        :background_agent_job_turn_trajectory_groups,
        :baj_turn_trajectory_groups_position_nonnegative,
        check: "position >= 0"
      )
    )

    create(
      constraint(
        :background_agent_job_turn_trajectory_groups,
        :baj_turn_trajectory_groups_revision_nonnegative,
        check: "revision >= 0"
      )
    )

    create(
      constraint(
        :background_agent_job_turn_trajectory_groups,
        :baj_turn_trajectory_groups_item_key_present,
        check: "length(btrim(item_key)) > 0"
      )
    )

    create(
      constraint(
        :background_agent_job_turn_trajectory_groups,
        :baj_turn_trajectory_groups_content_check,
        check: """
        jsonb_typeof(content) = 'object' AND
        jsonb_typeof(content->'messages') = 'array' AND
        jsonb_array_length(content->'messages') > 0 AND
        jsonb_array_length(jsonb_path_query_array(content, '$.messages[*].role')) =
          jsonb_array_length(content->'messages') AND
        jsonb_path_query_array(content, '$.messages[*].role') <@
          '["user","developer","assistant","tool"]'::jsonb
        """
      )
    )

    execute(backfill_groups_sql())

    execute(
      "UPDATE background_agent_job_turns SET trajectory = jsonb_set(trajectory, '{messages}', '[]'::jsonb)"
    )

    drop(constraint(:background_agent_job_turns, :background_agent_job_turns_trajectory_bytes))
  end

  def down do
    execute(assert_legacy_trajectory_size_sql())
    execute(restore_snapshots_sql())

    create(
      constraint(:background_agent_job_turns, :background_agent_job_turns_trajectory_bytes,
        check: "octet_length(trajectory::text) <= 524288"
      )
    )

    drop(table(:background_agent_job_turn_trajectory_groups))
  end

  defp backfill_groups_sql do
    """
    WITH expanded AS (
      SELECT
        turn.id AS turn_id,
        turn.revision,
        message.ordinality::integer - 1 AS message_position,
        message.value AS message,
        CASE
          WHEN message.value->>'role' = 'tool' THEN
            COALESCE(NULLIF(message.value->>'tool_call_id', ''), 'legacy:' || message.ordinality::text)
          WHEN message.value->>'role' = 'assistant'
               AND jsonb_typeof(message.value->'tool_calls') = 'array'
               AND jsonb_array_length(message.value->'tool_calls') = 1 THEN
            COALESCE(NULLIF(message.value->'tool_calls'->0->>'id', ''), 'legacy:' || message.ordinality::text)
          ELSE
            COALESCE(NULLIF(message.value->>'id', ''), 'legacy:' || message.ordinality::text)
        END AS item_key
      FROM background_agent_job_turns AS turn
      CROSS JOIN LATERAL jsonb_array_elements(turn.trajectory->'messages')
        WITH ORDINALITY AS message(value, ordinality)
    ), grouped AS (
      SELECT
        turn_id,
        MIN(message_position)::integer AS position,
        revision,
        item_key,
        jsonb_build_object('messages', jsonb_agg(message ORDER BY message_position)) AS content
      FROM expanded
      GROUP BY turn_id, revision, item_key
    )
    INSERT INTO background_agent_job_turn_trajectory_groups
      (turn_id, position, revision, item_key, content, inserted_at)
    SELECT turn_id, position, revision, item_key, content, timezone('UTC', now())
    FROM grouped
    ORDER BY turn_id, position
    """
  end

  defp assert_legacy_trajectory_size_sql do
    """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM background_agent_job_turns AS turn
        LEFT JOIN LATERAL (
          SELECT COALESCE(
            jsonb_agg(message.value ORDER BY group_row.position, message.ordinality),
            '[]'::jsonb
          ) AS messages
          FROM background_agent_job_turn_trajectory_groups AS group_row
          CROSS JOIN LATERAL jsonb_array_elements(group_row.content->'messages')
            WITH ORDINALITY AS message(value, ordinality)
          WHERE group_row.turn_id = turn.id
        ) AS restored ON TRUE
        WHERE octet_length(
          jsonb_set(turn.trajectory, '{messages}', COALESCE(restored.messages, '[]'::jsonb))::text
        ) > 524288
      ) THEN
        RAISE EXCEPTION
          'cannot restore the legacy BackgroundAgentJob trajectory snapshot: at least one Turn exceeds 512 KiB';
      END IF;
    END
    $$
    """
  end

  defp restore_snapshots_sql do
    """
    UPDATE background_agent_job_turns AS turn
    SET trajectory = jsonb_set(turn.trajectory, '{messages}', restored.messages)
    FROM (
      SELECT
        group_row.turn_id,
        jsonb_agg(message.value ORDER BY group_row.position, message.ordinality) AS messages
      FROM background_agent_job_turn_trajectory_groups AS group_row
      CROSS JOIN LATERAL jsonb_array_elements(group_row.content->'messages')
        WITH ORDINALITY AS message(value, ordinality)
      GROUP BY group_row.turn_id
    ) AS restored
    WHERE restored.turn_id = turn.id
    """
  end
end
