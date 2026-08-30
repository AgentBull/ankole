defmodule Ankole.SignalsGateway.Binding do
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
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Principals.Principal
  alias Ankole.SignalsGateway.BindingFilters
  alias Ankole.Ecto.JSONPayload

  @primary_key false
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "signal_gateway_bindings" do
    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey,
      primary_key: true

    field :name, :string, primary_key: true
    field :adapter, :string
    field :config_ref, :string
    # CEL admission filter, stored as `{"cel" => expression}`; empty object
    # means accept everything.
    field :filters, :map, default: %{}

    # What the agent does with a group message that does NOT explicitly address
    # it: stay out (:ignore), just mirror it for context (:record_only), or be
    # allowed to jump in (:may_intervene → ambient "may_intervene" actor event).
    # Default :record_only so a new group binding captures shared-room context
    # without waking the agent for unaddressed messages.
    field :unaddressed_group_message_policy, Ecto.Enum,
      values: [:ignore, :record_only, :may_intervene],
      default: :record_only

    # What ingress does with a sender that maps to no Principal: hold them for
    # manual binding in the console (:manual_review) or create a standalone
    # account on first sight (:create_standalone). Manual review fails closed,
    # so it is the default.
    field :unmatched_sender_policy, Ecto.Enum,
      values: [:manual_review, :create_standalone],
      default: :manual_review

    field :enabled, :boolean, default: true
    # When set on an enabled binding, ingress is refused with this reason instead
    # of accepted — lets an operator soft-disable a route (e.g. revoked provider
    # creds) without deleting it. See SignalsGateway.get_binding/2.
    field :unavailable_reason, :string

    timestamps()
  end

  @doc """
  Builds a changeset for signal binding rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(binding, attrs) do
    binding
    |> cast(attrs, [
      :agent_uid,
      :name,
      :adapter,
      :config_ref,
      :filters,
      :unaddressed_group_message_policy,
      :unmatched_sender_policy,
      :enabled,
      :unavailable_reason
    ])
    |> normalize_blank([:agent_uid, :name, :adapter, :config_ref, :unavailable_reason])
    |> validate_required([
      :agent_uid,
      :name,
      :adapter,
      :config_ref,
      :filters,
      :unaddressed_group_message_policy,
      :enabled
    ])
    |> JSONPayload.validate_map(:filters)
    |> validate_filters(:filters)
    |> foreign_key_constraint(:agent_uid)
    |> unique_constraint([:agent_uid, :name], name: :signal_gateway_bindings_pkey)
    |> check_constraint(:name, name: :signal_gateway_bindings_name_present)
    |> check_constraint(:adapter, name: :signal_gateway_bindings_adapter_present)
    |> check_constraint(:config_ref, name: :signal_gateway_bindings_config_ref_present)
    |> check_constraint(:filters, name: :signal_gateway_bindings_filters_object)
  end

  defp validate_filters(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case BindingFilters.validate_config(value) do
        :ok -> []
        {:error, reason} -> [{field, reason}]
      end
    end)
  end
end
