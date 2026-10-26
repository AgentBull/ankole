defmodule Ankole.Principals.AccessView do
  @moduledoc "The member access and permission review shared by Pod and site administration."
  @work_fields [
    kind: [type: :string, allow_nil?: false],
    id: [type: :string, allow_nil?: false],
    agent_uid: [type: :string, allow_nil?: false],
    status: [type: :string, allow_nil?: false],
    authorization_kind: [type: :string, allow_nil?: false],
    human_uid: [type: :string],
    human_access_version: [type: :integer],
    can_reauthorize: [type: :boolean, allow_nil?: false],
    updated_at: [type: :utc_datetime_usec, allow_nil?: false]
  ]
  @review_fields [
    fingerprint: [type: :string, allow_nil?: false],
    permissions: [
      type: :map,
      allow_nil?: false,
      constraints: [
        fields: [
          principal: [
            type: :map,
            allow_nil?: false,
            constraints: [
              fields: [
                uid: [type: :string, allow_nil?: false],
                display_name: [type: :string],
                avatar_url: [type: :string],
                access_version: [type: :integer, allow_nil?: false]
              ]
            ]
          ],
          groups: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: [
                  id: [type: :string, allow_nil?: false],
                  name: [type: :string, allow_nil?: false],
                  domain: [type: :string, allow_nil?: false],
                  kind: [type: :string, allow_nil?: false],
                  condition: [type: Ankole.Ash.Types.JSONValue]
                ]
              ]
            ]
          ],
          userset_grants: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: [
                  id: [type: :string, allow_nil?: false],
                  source_page_id: [type: :string, allow_nil?: false],
                  source_action: [type: :string, allow_nil?: false],
                  target_page_id: [type: :string, allow_nil?: false],
                  target_scope: [type: :string, allow_nil?: false],
                  resource_pattern: [type: :string, allow_nil?: false],
                  action: [type: :string, allow_nil?: false],
                  condition: [type: Ankole.Ash.Types.JSONValue, allow_nil?: false]
                ]
              ]
            ]
          ],
          grants: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: [
                  id: [type: :string, allow_nil?: false],
                  principal_uid: [type: :string],
                  group_id: [type: :string],
                  resource_pattern: [type: :string, allow_nil?: false],
                  action: [type: :string, allow_nil?: false],
                  condition: [type: Ankole.Ash.Types.JSONValue]
                ]
              ]
            ]
          ]
        ]
      ]
    ]
  ]
  @view_fields [
    uid: [type: :string, allow_nil?: false],
    status: [type: :string, allow_nil?: false],
    access_version: [type: :integer, allow_nil?: false],
    access_revoked_at: [type: :utc_datetime_usec],
    permission_review: [type: :map, allow_nil?: false, constraints: [fields: @review_fields]],
    restrictions: [
      type: {:array, :map},
      allow_nil?: false,
      constraints: [
        items: [
          fields: [
            id: [type: :string, allow_nil?: false],
            source: [type: :string, allow_nil?: false],
            disposition: [type: :string, allow_nil?: false],
            reason: [type: :string, allow_nil?: false],
            provider_time: [type: :utc_datetime_usec],
            recovery_verified_at: [type: :utc_datetime_usec],
            cleared_at: [type: :utc_datetime_usec],
            inserted_at: [type: :utc_datetime_usec, allow_nil?: false]
          ]
        ]
      ]
    ],
    history: [
      type: {:array, :map},
      allow_nil?: false,
      constraints: [
        items: [
          fields: [
            id: [type: :string, allow_nil?: false],
            source: [type: :string, allow_nil?: false],
            action: [type: :string, allow_nil?: false],
            reason: [type: :string, allow_nil?: false],
            actor: [type: Ankole.Ash.Types.ActorRef],
            access_version: [type: :integer, allow_nil?: false],
            details: [type: Ankole.Ash.Types.JSONValue],
            inserted_at: [type: :utc_datetime_usec, allow_nil?: false]
          ]
        ]
      ]
    ],
    work: [type: {:array, :map}, allow_nil?: false, constraints: [items: [fields: @work_fields]]],
    cleanup_jobs: [
      type: {:array, :map},
      allow_nil?: false,
      constraints: [
        items: [
          fields: [
            id: [type: :integer, allow_nil?: false],
            state: [type: :string, allow_nil?: false],
            attempt: [type: :integer, allow_nil?: false],
            max_attempts: [type: :integer, allow_nil?: false],
            scheduled_at: [type: :utc_datetime_usec],
            completed_at: [type: :utc_datetime_usec],
            discarded_at: [type: :utc_datetime_usec]
          ]
        ]
      ]
    ]
  ]

  def work_fields, do: @work_fields

  use Ash.Type.NewType, subtype_of: :map, constraints: [fields: @view_fields]
end
