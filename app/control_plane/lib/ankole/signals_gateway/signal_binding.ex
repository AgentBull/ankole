defmodule Ankole.SignalsGateway.SignalBinding do
  @moduledoc """
  Per-agent signal ingress route configured by an operator.

  A binding is the unit of "this agent listens to this provider source": it ties
  an `{agent_uid, name}` to an `adapter` plus a `config_ref` (the provider
  credential/config the adapter resolves separately). It also carries the
  admission `filters` (see `BindingFilters`) and the policy for unaddressed group
  messages. Every `emit_*` call in `SignalsGateway` is routed by looking up the
  binding for an `{agent_uid, binding_name}` pair, so the binding is effectively
  the gateway's routing key.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.Principals.Principal
  alias Ankole.SignalsGateway.JsonPayload

  @primary_key false
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "signal_bindings" do
    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: :string,
      primary_key: true

    field :name, :string, primary_key: true
    field :adapter, :string
    field :config_ref, :string
    # v1 admission filter, stored as the `{"eq" => ...}` JSON object that
    # BindingFilters understands; empty object means accept everything.
    field :filters, :map, default: %{}

    # What the agent does with a group message that does NOT explicitly address
    # it: stay out (:ignore), just mirror it for context (:record_only), or be
    # allowed to jump in (:may_intervene → ambient "may_intervene" actor input).
    # Default :ignore so a freshly bound agent is silent in shared rooms until an
    # operator opts into more.
    field :unaddressed_group_message_policy, Ecto.Enum,
      values: [:ignore, :record_only, :may_intervene],
      default: :ignore

    field :enabled, :boolean, default: true
    # When set on an enabled binding, ingress is refused with this reason instead
    # of accepted — lets an operator soft-disable a route (e.g. revoked provider
    # creds) without deleting it. See SignalsGateway.get_binding/2.
    field :unavailable_reason, :string

    timestamps()
  end

  @doc false
  def changeset(binding, attrs) do
    binding
    |> cast(attrs, [
      :agent_uid,
      :name,
      :adapter,
      :config_ref,
      :filters,
      :unaddressed_group_message_policy,
      :enabled,
      :unavailable_reason
    ])
    |> normalize_blank([:agent_uid, :name, :adapter, :config_ref, :unavailable_reason])
    |> normalize_uid(:agent_uid)
    |> validate_required([
      :agent_uid,
      :name,
      :adapter,
      :config_ref,
      :filters,
      :unaddressed_group_message_policy,
      :enabled
    ])
    |> JsonPayload.validate_map(:filters)
    |> foreign_key_constraint(:agent_uid)
    |> unique_constraint([:agent_uid, :name], name: :signal_bindings_pkey)
    |> check_constraint(:name, name: :signal_bindings_name_present)
    |> check_constraint(:adapter, name: :signal_bindings_adapter_present)
    |> check_constraint(:config_ref, name: :signal_bindings_config_ref_present)
    |> check_constraint(:filters, name: :signal_bindings_filters_object)
  end

  defp normalize_blank(changeset, fields) when is_list(fields) do
    Enum.reduce(fields, changeset, &normalize_blank(&2, &1))
  end

  defp normalize_blank(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      value ->
        value
    end)
  end

  defp normalize_uid(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> String.downcase(value)
      value -> value
    end)
  end
end
