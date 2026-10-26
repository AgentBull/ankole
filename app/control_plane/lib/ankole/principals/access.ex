defmodule Ankole.Principals.Access do
  @moduledoc "Console access review and recovery operations."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.Principals,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:site_console)
    resolve_param(:uid, :principal_key)
    allow(:show, resource: "site_console:principal:{uid}", action: "read")
    allow(:disable, resource: "site_console:principal:{uid}", action: "update")
    allow(:restore, resource: "site_console:principal:{uid}", action: "update")
    allow(:clear_restriction, resource: "site_console:principal:{uid}", action: "update")
    allow(:retry_cleanup, resource: "site_console:principal:{uid}", action: "update")
    allow(:unresolved_work, resource: "site_console:principals", action: "update")
    allow(:classify_work, resource: "site_console:principals", action: "update")
  end

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("human_access")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :show, Ankole.Principals.AccessView do
      argument(:uid, :string, allow_nil?: false)
      transaction?(false)
      run(__MODULE__.Actions)
    end

    action :disable, Ankole.Principals.AccessView do
      argument(:uid, :string, allow_nil?: false)

      argument(:disposition, :atom,
        allow_nil?: false,
        constraints: [one_of: [:suspended, :offboarded]]
      )

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

    action :clear_restriction, Ankole.Principals.AccessView do
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

    action :restore, Ankole.Principals.AccessView do
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

    action :retry_cleanup, Ankole.Principals.AccessView do
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
            constraints: [items: [fields: Ankole.Principals.AccessView.work_fields()]]
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
            constraints: [items: [fields: Ankole.Principals.AccessView.work_fields()]]
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
  end
end
