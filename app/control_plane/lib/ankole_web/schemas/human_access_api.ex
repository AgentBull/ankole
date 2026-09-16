defmodule AnkoleWeb.Schemas.HumanAccessAPI do
  @moduledoc "Console contracts for Human access and recovery."
  alias OpenApiSpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.JSONValue

  defmodule AccessReasonRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AccessReasonRequest",
        type: :object,
        properties: %{
          reason: %Schema{type: :string, minLength: 1, maxLength: 2000},
          operation_id: %Schema{type: :string, minLength: 1, maxLength: 200}
        },
        required: [:reason, :operation_id],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AccessRestoreRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AccessRestoreRequest",
        type: :object,
        properties: %{
          reason: %Schema{type: :string},
          operation_id: %Schema{type: :string},
          review_fingerprint: %Schema{type: :string},
          identity_verified: %Schema{type: :boolean}
        },
        required: [:reason, :operation_id, :review_fingerprint, :identity_verified],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule WorkClassifyRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "WorkClassifyRequest",
        type: :object,
        properties: %{
          kind: %Schema{type: :string},
          id: %Schema{type: :string},
          authorization_kind: %Schema{type: :string, enum: ["human", "service"]},
          human_uid: %Schema{type: :string, nullable: true},
          reason: %Schema{type: :string}
        },
        required: [:kind, :id, :authorization_kind, :reason],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AccessRestrictionItem do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AccessRestrictionItem",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          source: %Schema{type: :string},
          reason: %Schema{type: :string},
          provider_time: %Schema{type: :string, nullable: true},
          recovery_verified_at: %Schema{type: :string, nullable: true},
          cleared_at: %Schema{type: :string, nullable: true},
          inserted_at: %Schema{type: :string}
        },
        required: [
          :id,
          :source,
          :reason,
          :provider_time,
          :recovery_verified_at,
          :cleared_at,
          :inserted_at
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AccessHistoryItem do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AccessHistoryItem",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          source: %Schema{type: :string},
          action: %Schema{type: :string},
          reason: %Schema{type: :string},
          actor_uid: %Schema{type: :string, nullable: true},
          access_version: %Schema{type: :integer},
          details: JSONValue,
          inserted_at: %Schema{type: :string}
        },
        required: [
          :id,
          :source,
          :action,
          :reason,
          :actor_uid,
          :access_version,
          :details,
          :inserted_at
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AccessReviewPrincipal do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AccessReviewPrincipal",
        type: :object,
        properties: %{
          uid: %Schema{type: :string},
          display_name: %Schema{type: :string, nullable: true},
          avatar_url: %Schema{type: :string, nullable: true},
          access_version: %Schema{type: :integer}
        },
        required: [:uid, :display_name, :avatar_url, :access_version],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AccessReviewGroup do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AccessReviewGroup",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          name: %Schema{type: :string},
          domain: %Schema{type: :string},
          kind: %Schema{type: :string},
          condition: JSONValue
        },
        required: [:id, :name, :domain, :kind, :condition],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AccessReviewGrant do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AccessReviewGrant",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          principal_uid: %Schema{type: :string, nullable: true},
          group_id: %Schema{type: :string, nullable: true},
          resource_pattern: %Schema{type: :string},
          action: %Schema{type: :string},
          condition: JSONValue
        },
        required: [:id, :principal_uid, :group_id, :resource_pattern, :action, :condition],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AccessReviewPermissions do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AccessReviewPermissions",
        type: :object,
        properties: %{
          principal: AccessReviewPrincipal,
          groups: %Schema{type: :array, items: AccessReviewGroup},
          grants: %Schema{type: :array, items: AccessReviewGrant}
        },
        required: [:principal, :groups, :grants],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AccessPermissionReview do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AccessPermissionReview",
        type: :object,
        properties: %{
          fingerprint: %Schema{type: :string},
          permissions: AccessReviewPermissions
        },
        required: [:fingerprint, :permissions],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule HumanWorkItem do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "HumanWorkItem",
        type: :object,
        properties: %{
          kind: %Schema{type: :string},
          id: %Schema{type: :string},
          agent_uid: %Schema{type: :string},
          status: %Schema{type: :string},
          authorization_kind: %Schema{type: :string},
          human_uid: %Schema{type: :string, nullable: true},
          human_access_version: %Schema{type: :integer, nullable: true},
          updated_at: %Schema{type: :string}
        },
        required: [
          :kind,
          :id,
          :agent_uid,
          :status,
          :authorization_kind,
          :human_uid,
          :human_access_version,
          :updated_at
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule WorkReviewResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "WorkReviewResponse",
        type: :object,
        properties: %{
          work: %Schema{type: :array, items: HumanWorkItem}
        },
        required: [:work],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule CleanupJobItem do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "CleanupJobItem",
        type: :object,
        properties: %{
          id: %Schema{type: :integer},
          state: %Schema{type: :string},
          attempt: %Schema{type: :integer},
          max_attempts: %Schema{type: :integer},
          scheduled_at: %Schema{type: :string, nullable: true},
          completed_at: %Schema{type: :string, nullable: true},
          discarded_at: %Schema{type: :string, nullable: true}
        },
        required: [
          :id,
          :state,
          :attempt,
          :max_attempts,
          :scheduled_at,
          :completed_at,
          :discarded_at
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule HumanAccessResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "HumanAccessResponse",
        type: :object,
        properties: %{
          uid: %Schema{type: :string},
          status: %Schema{type: :string},
          access_version: %Schema{type: :integer},
          access_revoked_at: %Schema{type: :string, nullable: true},
          restrictions: %Schema{type: :array, items: AccessRestrictionItem},
          history: %Schema{type: :array, items: AccessHistoryItem},
          permission_review: AccessPermissionReview,
          work: %Schema{type: :array, items: HumanWorkItem},
          cleanup_jobs: %Schema{type: :array, items: CleanupJobItem}
        },
        required: [
          :uid,
          :status,
          :access_version,
          :access_revoked_at,
          :restrictions,
          :history,
          :permission_review,
          :work,
          :cleanup_jobs
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule DirectorySnapshot do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "DirectorySnapshot",
        type: :object,
        properties: %{
          provider_id: %Schema{type: :string},
          status: %Schema{type: :string},
          revision: %Schema{type: :integer},
          scope_fingerprint: %Schema{type: :string, nullable: true},
          snapshot_fingerprint: %Schema{type: :string, nullable: true},
          approved_scope_fingerprint: %Schema{type: :string, nullable: true},
          member_uids: %Schema{type: :array, items: %Schema{type: :string}},
          missing_uids: %Schema{type: :array, items: %Schema{type: :string}},
          last_started_at: %Schema{type: :string, nullable: true},
          last_success_at: %Schema{type: :string, nullable: true},
          last_error: %Schema{type: :string, nullable: true},
          reviewed_by: %Schema{type: :string, nullable: true},
          reviewed_at: %Schema{type: :string, nullable: true},
          review_reason: %Schema{type: :string, nullable: true}
        },
        required: [
          :provider_id,
          :status,
          :revision,
          :scope_fingerprint,
          :snapshot_fingerprint,
          :approved_scope_fingerprint,
          :member_uids,
          :missing_uids,
          :last_started_at,
          :last_success_at,
          :last_error,
          :reviewed_by,
          :reviewed_at,
          :review_reason
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule DirectoryEventItem do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "DirectoryEventItem",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          event_id: %Schema{type: :string},
          event_type: %Schema{type: :string},
          external_ids: %Schema{type: :array, items: %Schema{type: :string}},
          reason: %Schema{type: :string, nullable: true},
          provider_time: %Schema{type: :string, nullable: true},
          status: %Schema{type: :string},
          last_error: %Schema{type: :string, nullable: true},
          processed_at: %Schema{type: :string, nullable: true},
          reviewed_by: %Schema{type: :string, nullable: true},
          review_reason: %Schema{type: :string, nullable: true},
          inserted_at: %Schema{type: :string}
        },
        required: [
          :id,
          :event_id,
          :event_type,
          :external_ids,
          :reason,
          :provider_time,
          :status,
          :last_error,
          :processed_at,
          :reviewed_by,
          :review_reason,
          :inserted_at
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule DirectoryAccessResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "DirectoryAccessResponse",
        type: :object,
        properties: %{
          snapshot: %Schema{allOf: [DirectorySnapshot], nullable: true},
          events: %Schema{type: :array, items: DirectoryEventItem}
        },
        required: [:snapshot, :events],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule DirectoryApproveRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "DirectoryApproveRequest",
        type: :object,
        properties: %{
          snapshot_fingerprint: %Schema{type: :string},
          reason: %Schema{type: :string},
          confirm_removals: %Schema{type: :boolean}
        },
        required: [:snapshot_fingerprint, :reason, :confirm_removals],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule DirectoryEventReviewRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "DirectoryEventReviewRequest",
        type: :object,
        properties: %{
          action: %Schema{type: :string, enum: ["retry", "dismiss"]},
          reason: %Schema{type: :string}
        },
        required: [:action, :reason],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule LogoutDeliveryItem do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "LogoutDeliveryItem",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          session_id: %Schema{type: :string},
          principal_uid: %Schema{type: :string},
          status: %Schema{type: :string},
          attempt_count: %Schema{type: :integer},
          last_attempt_at: %Schema{type: :string, nullable: true},
          next_attempt_at: %Schema{type: :string, nullable: true},
          delivered_at: %Schema{type: :string, nullable: true},
          deadline: %Schema{type: :string},
          last_error: %Schema{type: :string, nullable: true}
        },
        required: [
          :id,
          :session_id,
          :principal_uid,
          :status,
          :attempt_count,
          :last_attempt_at,
          :next_attempt_at,
          :delivered_at,
          :deadline,
          :last_error
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule LogoutDeliveriesResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "LogoutDeliveriesResponse",
        type: :object,
        properties: %{
          deliveries: %Schema{type: :array, items: LogoutDeliveryItem}
        },
        required: [:deliveries],
        additionalProperties: false
      },
      struct?: false
    )
  end
end
