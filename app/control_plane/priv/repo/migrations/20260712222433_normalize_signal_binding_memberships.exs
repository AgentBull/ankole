defmodule Ankole.Repo.Migrations.NormalizeSignalBindingMemberships do
  use Ecto.Migration

  def up do
    execute("""
    WITH normalized AS (
      SELECT
        principal_group.id,
        COALESCE(
          (
            SELECT jsonb_object_agg(
              membership.key,
              jsonb_strip_nulls(
                jsonb_build_object(
                  'agent_uid', membership.value->>'agent_uid',
                  'binding_name', membership.value->>'binding_name',
                  'state', membership.value->>'state',
                  'observed_at', COALESCE(
                    membership.value->>'observed_at',
                    membership.value->>'last_seen_at',
                    membership.value->>'last_left_at'
                  )
                )
              )
            )
            FROM jsonb_each(
              COALESCE(principal_group.metadata#>'{lark_im,sync_participants}', '{}'::jsonb) ||
              COALESCE(principal_group.metadata#>'{slack_im,sync_participants}', '{}'::jsonb) ||
              COALESCE(principal_group.metadata#>'{teams_im,sync_participants}', '{}'::jsonb)
            ) AS membership(key, value)
            WHERE jsonb_typeof(membership.value) = 'object'
              AND COALESCE(membership.value->>'agent_uid', '') <> ''
              AND COALESCE(membership.value->>'binding_name', '') <> ''
              AND membership.value->>'state' IN ('joined', 'left')
          ),
          '{}'::jsonb
        ) AS legacy_memberships
      FROM principal_groups AS principal_group
      WHERE principal_group.metadata ?| ARRAY['lark_im', 'slack_im', 'teams_im']
    ), cleaned AS (
      SELECT
        principal_group.id,
        ((principal_group.metadata #- '{lark_im,sync_participants}')
          #- '{slack_im,sync_participants}')
          #- '{teams_im,sync_participants}' AS metadata,
        normalized.legacy_memberships
      FROM principal_groups AS principal_group
      JOIN normalized ON normalized.id = principal_group.id
    )
    UPDATE principal_groups AS principal_group
    SET metadata =
      cleaned.metadata ||
      jsonb_build_object(
        'signals_gateway',
        COALESCE(cleaned.metadata->'signals_gateway', '{}'::jsonb) ||
        jsonb_build_object(
          'binding_memberships',
          cleaned.legacy_memberships ||
          COALESCE(
            principal_group.metadata#>'{signals_gateway,binding_memberships}',
            '{}'::jsonb
          )
        )
      )
    FROM cleaned
    WHERE principal_group.id = cleaned.id
    """)
  end

  def down do
    execute("""
    WITH provider_memberships AS (
      SELECT
        principal_group.id,
        COALESCE(
          jsonb_object_agg(
            membership.key,
            jsonb_strip_nulls(
              jsonb_build_object(
                'agent_uid', membership.value->>'agent_uid',
                'binding_name', membership.value->>'binding_name',
                'state', membership.value->>'state',
                'last_seen_at', CASE
                  WHEN membership.value->>'state' = 'joined'
                  THEN membership.value->>'observed_at'
                END,
                'last_left_at', CASE
                  WHEN membership.value->>'state' = 'left'
                  THEN membership.value->>'observed_at'
                END
              )
            )
          ) FILTER (WHERE binding.adapter = 'lark'),
          '{}'::jsonb
        ) AS lark_memberships,
        COALESCE(
          jsonb_object_agg(
            membership.key,
            jsonb_strip_nulls(
              jsonb_build_object(
                'agent_uid', membership.value->>'agent_uid',
                'binding_name', membership.value->>'binding_name',
                'state', membership.value->>'state',
                'last_seen_at', CASE
                  WHEN membership.value->>'state' = 'joined'
                  THEN membership.value->>'observed_at'
                END,
                'last_left_at', CASE
                  WHEN membership.value->>'state' = 'left'
                  THEN membership.value->>'observed_at'
                END
              )
            )
          ) FILTER (WHERE binding.adapter = 'slack'),
          '{}'::jsonb
        ) AS slack_memberships,
        COALESCE(
          jsonb_object_agg(
            membership.key,
            jsonb_strip_nulls(
              jsonb_build_object(
                'agent_uid', membership.value->>'agent_uid',
                'binding_name', membership.value->>'binding_name',
                'state', membership.value->>'state',
                'last_seen_at', CASE
                  WHEN membership.value->>'state' = 'joined'
                  THEN membership.value->>'observed_at'
                END,
                'last_left_at', CASE
                  WHEN membership.value->>'state' = 'left'
                  THEN membership.value->>'observed_at'
                END
              )
            )
          ) FILTER (WHERE binding.adapter = 'teams'),
          '{}'::jsonb
        ) AS teams_memberships
      FROM principal_groups AS principal_group
      CROSS JOIN LATERAL jsonb_each(
        COALESCE(
          principal_group.metadata#>'{signals_gateway,binding_memberships}',
          '{}'::jsonb
        )
      ) AS membership(key, value)
      LEFT JOIN signal_gateway_bindings AS binding
        ON binding.agent_uid = membership.value->>'agent_uid'
       AND binding.name = membership.value->>'binding_name'
      GROUP BY principal_group.id
    ), restored AS (
      SELECT
        principal_group.id,
        principal_group.metadata #- '{signals_gateway,binding_memberships}' AS base_metadata,
        provider_memberships.lark_memberships,
        provider_memberships.slack_memberships,
        provider_memberships.teams_memberships
      FROM principal_groups AS principal_group
      JOIN provider_memberships ON provider_memberships.id = principal_group.id
    )
    UPDATE principal_groups AS principal_group
    SET metadata =
      CASE
        WHEN restored.base_metadata->'signals_gateway' = '{}'::jsonb
        THEN restored.base_metadata - 'signals_gateway'
        ELSE restored.base_metadata
      END ||
      CASE
        WHEN restored.lark_memberships = '{}'::jsonb THEN '{}'::jsonb
        ELSE jsonb_build_object(
          'lark_im',
          COALESCE(restored.base_metadata->'lark_im', '{}'::jsonb) ||
          jsonb_build_object('sync_participants', restored.lark_memberships)
        )
      END ||
      CASE
        WHEN restored.slack_memberships = '{}'::jsonb THEN '{}'::jsonb
        ELSE jsonb_build_object(
          'slack_im',
          COALESCE(restored.base_metadata->'slack_im', '{}'::jsonb) ||
          jsonb_build_object('sync_participants', restored.slack_memberships)
        )
      END ||
      CASE
        WHEN restored.teams_memberships = '{}'::jsonb THEN '{}'::jsonb
        ELSE jsonb_build_object(
          'teams_im',
          COALESCE(restored.base_metadata->'teams_im', '{}'::jsonb) ||
          jsonb_build_object('sync_participants', restored.teams_memberships)
        )
      END
    FROM restored
    WHERE principal_group.id = restored.id
    """)
  end
end
