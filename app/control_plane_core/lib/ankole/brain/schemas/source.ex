defmodule Ankole.Brain.Schemas.Source do
  @moduledoc "A stable learning source with explicit archive, sync, and extraction writes."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Brain.Domain

  postgres do
    table("brain_sources")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(upstream: "brain_sources_kind_upstream_key")

    check_constraints do
      check_constraint(:upstream_id, "brain_sources_upstream_present")
      check_constraint(:kind, "brain_sources_kind_present")
      check_constraint(:name, "brain_sources_name_present")
      check_constraint(:default_audience_scope, "brain_sources_default_scope_format")
      check_constraint(:config, "brain_sources_config_object")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:upstream_id, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:kind, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:name, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:default_audience_scope, :string, constraints: [trim?: false])
    attribute(:config, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    attribute(:upstream_revision, :string, constraints: [trim?: false])
    attribute(:last_sync_at, :utc_datetime_usec)
    attribute(:archived_at, :utc_datetime_usec)
    attribute(:extracted_through_at, :utc_datetime_usec)
    attribute(:extracted_through_seq, :integer, constraints: [min: 0])
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
  end

  identities do
    identity(:upstream, [:kind, :upstream_id])
  end

  actions do
    defaults([:read])

    create :register do
      accept([
        :id,
        :kind,
        :upstream_id,
        :name,
        :default_audience_scope,
        :config,
        :upstream_revision,
        :last_sync_at,
        :created_at
      ])
    end

    create_if_absent :ensure do
      transaction?(false)

      accept([
        :id,
        :kind,
        :upstream_id,
        :name,
        :default_audience_scope,
        :config,
        :upstream_revision,
        :last_sync_at,
        :created_at
      ])

      upsert_identity(:upstream)
    end

    atomic_in_tx_update :archive do
      accept([])
      change(filter(expr(is_nil(archived_at))))
      change(set_attribute(:archived_at, &DateTime.utc_now/0))
      change(set_attribute(:updated_at, &DateTime.utc_now/0))
    end

    atomic_in_tx_update :set_default_scope do
      accept([:default_audience_scope])
      change(filter(expr(is_nil(archived_at) and kind == "oidc_client")))
      change(set_attribute(:updated_at, &DateTime.utc_now/0))
    end

    update :record_revision do
      transaction?(false)
      require_atomic?(true)
      accept([:upstream_revision])
      change(filter(expr(is_nil(archived_at))))
      change(set_attribute(:last_sync_at, &DateTime.utc_now/0))
      change(set_attribute(:updated_at, &DateTime.utc_now/0))
    end

    update :record_sync do
      transaction?(false)
      require_atomic?(true)
      accept([])
      change(filter(expr(is_nil(archived_at))))
      change(set_attribute(:last_sync_at, &DateTime.utc_now/0))
      change(set_attribute(:updated_at, &DateTime.utc_now/0))
    end

    update :record_watermark do
      transaction?(false)
      require_atomic?(true)
      accept([:extracted_through_at, :extracted_through_seq])
      require_attributes([:extracted_through_at, :extracted_through_seq])
      change(filter(expr(is_nil(archived_at))))
    end

    atomic_in_tx_update :invalidate_extraction do
      accept([])
      change(set_attribute(:extracted_through_seq, 0))
      change(set_attribute(:extracted_through_at, nil))
      change(set_attribute(:upstream_revision, &Ecto.UUID.generate/0))
      change(set_attribute(:updated_at, &DateTime.utc_now/0))
    end
  end

  @type t :: %__MODULE__{}
end
