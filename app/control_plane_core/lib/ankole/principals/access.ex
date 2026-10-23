defmodule Ankole.Principals.Access do
  @moduledoc "Console access review and recovery operations."
  use Ash.Resource,
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.Principals,
    extensions: [AshJsonApi.Resource]

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("human_access")
    derive_filter?(false)
    derive_sort?(false)
  end

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

  actions do
    action :show, :map do
      constraints(fields: @view_fields)
      argument(:uid, :string, allow_nil?: false)
      transaction?(false)
      run(__MODULE__.Actions)
    end

    action :disable, :map do
      constraints(fields: @view_fields)
      argument(:uid, :string, allow_nil?: false)

      argument(:reason, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 2000]
      )

      argument(:operation_id, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 200]
      )

      transaction?(false)
      run(__MODULE__.Actions)
    end

    action :clear_restriction, :map do
      constraints(fields: @view_fields)
      argument(:uid, :string, allow_nil?: false)
      argument(:restriction_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)

      argument(:reason, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 2000]
      )

      argument(:operation_id, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 200]
      )

      transaction?(false)
      run(__MODULE__.Actions)
    end

    action :restore, :map do
      constraints(fields: @view_fields)
      argument(:uid, :string, allow_nil?: false)

      argument(:reason, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 2000]
      )

      argument(:operation_id, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 200]
      )

      argument(:review_fingerprint, :string, allow_nil?: false)
      argument(:identity_verified, :boolean, allow_nil?: false)
      transaction?(false)
      run(__MODULE__.Actions)
    end

    action :retry_cleanup, :map do
      constraints(fields: @view_fields)
      argument(:uid, :string, allow_nil?: false)
      transaction?(false)
      run(__MODULE__.Actions)
    end

    action :unresolved_work, :map do
      constraints(
        fields: [
          work: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @work_fields]]
          ]
        ]
      )

      transaction?(false)
      run(__MODULE__.Actions)
    end

    action :classify_work, :map do
      constraints(
        fields: [
          work: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @work_fields]]
          ]
        ]
      )

      argument(:kind, :string, allow_nil?: false)
      argument(:id, :string, allow_nil?: false)

      argument(:authorization_kind, :atom,
        allow_nil?: false,
        constraints: [one_of: [:human, :service]]
      )

      argument(:human_uid, :string)
      argument(:reason, :string, allow_nil?: false, constraints: [min_length: 1])
      transaction?(false)
      run(__MODULE__.Actions)
    end

    action :reset_local_password, :map do
      constraints(fields: [initial_password: [type: :string, allow_nil?: false]])
      argument(:uid, :string, allow_nil?: false)
      argument(:must_change_password, :boolean, default: true)
      transaction?(false)
      run(__MODULE__.Actions)
    end
  end
end
