defmodule Ankole.Signals.Binding do
  @moduledoc """
  Per-agent signal ingress route configured by an operator.

  A binding is the unit of "this agent listens to this provider source": it ties
  an `{agent_uid, name}` to an `adapter` plus a `config_ref` (the provider
  credential/config the adapter resolves separately). It also carries the
  admission `filters` (see `BindingFilters`) and the policy for unaddressed group
  messages. Every `emit_*` call in `Conversations.Observe` is routed by looking up the
  binding for an `{agent_uid, binding_name}` pair, so the binding is effectively
  the gateway's routing key.
  """

  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Signals.Domain

  alias Ankole.Signals.Target, as: ExecutionTarget
  alias Ankole.Signals.BindingFilters

  @type t :: %__MODULE__{}

  postgres do
    table("signal_bindings")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:agent_uid, "signal_bindings_agent_uid_fkey"}])
    unique_index_names([{[:agent_uid, :name], "signal_bindings_pkey"}])

    check_constraints do
      check_constraint(:name, "signal_bindings_name_present")
      check_constraint(:adapter, "signal_bindings_adapter_present")
      check_constraint(:config_ref, "signal_bindings_config_ref_present")
      check_constraint(:filters, "signal_bindings_filters_object")
      check_constraint(:target, "signal_bindings_target_object")
    end
  end

  attributes do
    attribute(:agent_uid, Ankole.Ash.Types.PrincipalKey,
      primary_key?: true,
      allow_nil?: false,
      public?: true
    )

    attribute(:name, :string,
      constraints: [trim?: true],
      primary_key?: true,
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

  actions do
    defaults([:read])

    create :put do
      primary?(true)
      transaction?(false)
      upsert?(true)

      upsert_fields([
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

    in_tx_update :disable do
      accept([])
      change(set_attribute(:enabled, false))
      change(set_attribute(:unavailable_reason, nil))
    end

    destroy :remove do
      transaction?(false)
      require_atomic?(false)
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
