defmodule Ankole.AIGateway.ProviderConfigs.CredentialPoolView do
  @moduledoc """
  The operator view of a provider credential pool: the selection strategy and,
  for each credential, its metadata, account facts, and current health.

  It contains no credential value. `Ankole.AIGateway.ProviderConfigs.projection/1`
  gives the same fields to the v1 credential routes.
  """

  @entry_fields [
    id: [type: :string, allow_nil?: false],
    label: [type: :string, allow_nil?: false],
    source: [type: :string, allow_nil?: false],
    priority: [type: :integer, allow_nil?: false],
    disabled_at: [type: :string],
    credential_present: [type: :boolean, allow_nil?: false],
    status: [
      type: :atom,
      allow_nil?: false,
      constraints: [one_of: ~w(ok exhausted dead disabled)a]
    ],
    retry_at: [type: :string],
    request_count: [type: :integer, allow_nil?: false],
    rate_limits: [type: :map, allow_nil?: false],
    usage: [type: :map, allow_nil?: false],
    last_selected_at: [type: :string],
    last_error_code: [type: :string],
    last_error_reason: [type: :string],
    last_error_message: [type: :string],
    provider_status: [type: :integer],
    reauth_required: [type: :boolean],
    account_id: [type: :string],
    plan_type: [type: :string],
    email: [type: :string],
    last_refresh: [type: :string],
    auth_type: [type: :string]
  ]

  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        strategy: [
          type: :atom,
          allow_nil?: false,
          constraints: [one_of: ~w(fill_first round_robin least_used random)a]
        ],
        entries: [
          type: {:array, :map},
          allow_nil?: false,
          constraints: [items: [fields: @entry_fields]]
        ]
      ]
    ]
end
