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

  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Signals,
    extensions: [AshJsonApi.Resource]

  alias Ankole.Signals.Target, as: ExecutionTarget
  alias Ankole.Signals.BindingFilters
  alias Ankole.Signals.Bindings

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

  json_api do
    type("signal_binding")
    derive_filter?(false)
    derive_sort?(false)

    default_fields([
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
      keys([:agent_uid, :name])
      delimiter("~")
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

    update :disable do
      accept([])
      change(set_attribute(:enabled, false))
      change(set_attribute(:unavailable_reason, nil))
    end

    destroy(:remove)

    action :assign, :term do
      argument(:assignment, :map, allow_nil?: false)
      after_commit({Bindings, :cache_committed_assignment})

      run(fn input, _context ->
        Ankole.Errors.wrap(Bindings.assign_in_tx(Ankole.Repo, input.arguments.assignment))
      end)
    end

    action :reassign, :term do
      argument(:assignment, :map, allow_nil?: false)
      after_commit({Bindings, :cache_committed_assignment})

      run(fn input, _context ->
        Ankole.Errors.wrap(Bindings.reassign_in_tx(Ankole.Repo, input.arguments.assignment))
      end)
    end

    action :put_cloud, :term do
      argument(:binding, :map, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Errors.wrap(Bindings.put_cloud_binding_in_tx(Ankole.Repo, input.arguments.binding))
      end)
    end

    action :move_cloud, :term do
      argument(:source, :struct, allow_nil?: false, constraints: [instance_of: __MODULE__])
      argument(:current_config, :map, allow_nil?: false)
      argument(:binding, :map, allow_nil?: false)

      run(fn input, _context ->
        args = input.arguments

        Ankole.Errors.wrap(
          Bindings.move_cloud_binding_in_tx(
            Ankole.Repo,
            args.source,
            args.current_config,
            args.binding
          )
        )
      end)
    end

    # The Console disables a binding of one Agent. An unknown Agent or binding
    # reads as not found.
    action :console_disable, :struct do
      constraints(instance_of: __MODULE__)
      argument(:agent_uid, :string, allow_nil?: false)
      argument(:name, :string, allow_nil?: false)

      run(fn input, _context ->
        args = input.arguments

        Ankole.Repo
        |> Bindings.disable_binding_in_tx(args.agent_uid, args.name)
        |> Ankole.Errors.not_found([:agent_not_found, :binding_not_found], __MODULE__)
        |> Ankole.Errors.wrap()
      end)
    end

    action :disable_by_name, :term do
      argument(:agent_uid, :term, allow_nil?: false)
      argument(:name, :term, allow_nil?: false)

      run(fn input, _context ->
        args = input.arguments
        Ankole.Errors.wrap(Bindings.disable_binding_in_tx(Ankole.Repo, args.agent_uid, args.name))
      end)
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
