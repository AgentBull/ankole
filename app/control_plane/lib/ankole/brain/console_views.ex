defmodule Ankole.Brain.ConsoleViews do
  @moduledoc "Console views and operations that combine Brain resources."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    domain: Ankole.Brain,
    data_layer: Ash.DataLayer.Simple,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:site_console)
    allow(:health, resource: "site_console:brain", action: "read")
    allow(:dream, resource: "site_console:brain", action: "update")
    allow(:object_types, resource: "site_console:brain", action: "read")
    allow(:show_object, resource: "site_console:brain", action: "read")
    allow(:search_preview, resource: "site_console:brain", action: "read")
    allow(:principal_knowledge, resource: "site_console:brain", action: "read")
  end

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("brain_console_view")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :health, Ankole.Brain.ConsoleTypes.BrainHealthResponse do
      transaction?(false)
      run(__MODULE__.Actions)
    end

    action :dream, Ankole.Brain.ConsoleTypes.BrainDreamResponse do
      transaction?(false)
      run(__MODULE__.Actions)
    end

    action :object_types, Ankole.Brain.ConsoleTypes.BrainObjectTypesResponse do
      transaction?(false)
      run(__MODULE__.Actions)
    end

    action :show_object, Ankole.Brain.ConsoleTypes.BrainObjectShowResponse do
      transaction?(false)
      argument(:slug, :string, allow_nil?: false, constraints: [trim?: false])
      run(__MODULE__.Actions)
    end

    action :search_preview, Ankole.Brain.ConsoleTypes.BrainSearchPreviewResponse do
      transaction?(false)
      argument(:principal_uid, :string, allow_nil?: false)
      argument(:query, :string, allow_nil?: false)
      argument(:disclosure_mode, :string)
      argument(:asker_uid, :string)
      argument(:present_uids, {:array, :string}, default: [])
      run(__MODULE__.Actions)
    end

    action :principal_knowledge, Ankole.Brain.ConsoleTypes.BrainClaimListResponse do
      transaction?(false)
      argument(:principal_uid, :string, allow_nil?: false)
      run(__MODULE__.Actions)
    end
  end
end
