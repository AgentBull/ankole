defmodule Ankole.Signals.Binding do
  @moduledoc "A tenant's adapter configuration, with either a fixed colleague or sender-owned assistant route."

  use Ankole.Ash.Resource,
    authorizers: [Ankole.AuthZ.Authorizer],
    tenancy: :tenant,
    domain: Ankole.Signals,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:site_console)
    resolve_param(:agent_uid, :principal_key)

    allow(:console_disable,
      resource: "site_console:signal_bindings",
      action: "delete",
      permissions: &Ankole.Signals.ConsoleActions.binding_permissions/4
    )
  end

  alias Ankole.Signals.Target, as: ExecutionTarget
  alias Ankole.Signals.BindingFilters

  @type t :: %__MODULE__{}

  postgres do
    table("signal_bindings")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:agent_uid, "signal_bindings_agent_uid_fkey"}])

    unique_index_names([
      {[:agent_uid, :name], "signal_bindings_agent_name_index"},
      {[:name], "signal_bindings_shared_name_index"}
    ])

    check_constraints do
      check_constraint(:routing_mode, "signal_bindings_routing_target")
      check_constraint(:name, "signal_bindings_name_present")
      check_constraint(:adapter, "signal_bindings_adapter_present")
      check_constraint(:config_ref, "signal_bindings_config_ref_present")
      check_constraint(:filters, "signal_bindings_filters_object")
      check_constraint(:target, "signal_bindings_target_object")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Kernel.gen_uuid_v7/0,
      public?: true
    )

    attribute(:agent_uid, Ankole.Ash.Types.PrincipalKey, public?: true)
    attribute(:name, :string, constraints: [trim?: true], allow_nil?: false, public?: true)

    attribute(:routing_mode, Ankole.Ash.Types.State,
      constraints: [one_of: [:ai_colleague, :sender_personal_assistant]],
      default: :ai_colleague,
      allow_nil?: false,
      public?: true
    )

    attribute(:adapter, :string, allow_nil?: false, public?: true)
    attribute(:config_ref, :string, allow_nil?: false, public?: true)
    attribute(:filters, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{}, public?: true)
    attribute(:target, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{}, public?: true)

    attribute(:unaddressed_group_message_policy, Ankole.Ash.Types.State,
      constraints: [one_of: [:ignore, :record_only, :may_intervene]],
      default: :record_only,
      allow_nil?: false,
      public?: true
    )

    attribute(:unmatched_sender_policy, Ankole.Ash.Types.State,
      constraints: [one_of: [:manual_review, :create_standalone]],
      default: :manual_review,
      allow_nil?: false,
      public?: true
    )

    attribute(:enabled, :boolean, default: true, allow_nil?: false, public?: true)
    attribute(:unavailable_reason, :string, public?: true)
    timestamps(type: :utc_datetime_usec)
  end

  json_api do
    type("signal_binding")
    derive_filter?(false)
    derive_sort?(false)

    default_fields([
      :routing_mode,
      :agent_uid,
      :name,
      :adapter,
      :config_ref,
      :target,
      :filters,
      :unaddressed_group_message_policy,
      :unmatched_sender_policy,
      :enabled,
      :unavailable_reason
    ])

    primary_key do
      keys([:id])
    end
  end

  actions do
    defaults([:read])

    read :lookup_across_tenants do
      multitenancy(:allow_global)
    end

    create :put do
      primary?(true)
      upsert?(true)

      upsert_fields([
        :agent_uid,
        :name,
        :routing_mode,
        :adapter,
        :config_ref,
        :filters,
        :target,
        :unaddressed_group_message_policy,
        :unmatched_sender_policy,
        :enabled,
        :unavailable_reason
      ])

      accept([
        :id,
        :routing_mode,
        :agent_uid,
        :name,
        :adapter,
        :config_ref,
        :filters,
        :target,
        :unaddressed_group_message_policy,
        :unmatched_sender_policy,
        :enabled,
        :unavailable_reason
      ])

      change(set_attribute(:unavailable_reason, nil, new?: true))
      change(fn changeset, _context -> normalize_target(changeset) end)

      validate(
        fn changeset, _context ->
          case BindingFilters.validate_config(Ash.Changeset.get_attribute(changeset, :filters)) do
            :ok -> :ok
            {:error, reason} -> {:error, field: :filters, message: reason}
          end
        end,
        where: [changing(:filters)],
        only_when_valid?: true
      )
    end

    update :disable do
      accept([])
      change(set_attribute(:enabled, false))
      change(set_attribute(:unavailable_reason, nil))
    end

    destroy(:remove)

    # The Console disables a binding of one Agent. An unknown Agent or binding
    # reads as not found.
    action :console_disable, :struct do
      constraints(instance_of: __MODULE__)
      argument(:id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)

      run(__MODULE__.Actions)
    end
  end

  defp normalize_target(changeset) do
    if Ash.Changeset.get_attribute(changeset, :adapter) == "cloudevents" do
      target = Ash.Changeset.get_attribute(changeset, :target)

      case target do
        %{} when map_size(target) == 1 ->
          case ExecutionTarget.parse(target) do
            {:conversation, id} ->
              Ash.Changeset.force_change_attribute(changeset, :target, %{"conversation_id" => id})

            {:session, key} ->
              if Ankole.Sessions.Key.routable?(key), do: changeset, else: target_error(changeset)

            :error ->
              target_error(changeset)
          end

        _ ->
          target_error(changeset)
      end
    else
      changeset
    end
  end

  defp target_error(changeset),
    do:
      Ash.Changeset.add_error(changeset,
        field: :target,
        message: "must name a conversation or a session"
      )
end
