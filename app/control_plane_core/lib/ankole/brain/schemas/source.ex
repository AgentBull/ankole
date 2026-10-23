defmodule Ankole.Brain.Schemas.Source do
  @moduledoc "A stable learning source with explicit archive, sync, and extraction writes."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Brain,
    extensions: [AshJsonApi.Resource]

  json_api do
    type("brain_source")
    derive_filter?(false)
    derive_sort?(false)

    default_fields([
      :upstream_id,
      :kind,
      :name,
      :default_audience_scope,
      :upstream_revision,
      :last_sync_at,
      :archived_at
    ])
  end

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

    attribute(:upstream_id, :string,
      allow_nil?: false,
      public?: true,
      constraints: [trim?: false]
    )

    attribute(:kind, :string, allow_nil?: false, public?: true, constraints: [trim?: false])
    attribute(:name, :string, allow_nil?: false, public?: true, constraints: [trim?: false])
    attribute(:default_audience_scope, :string, public?: true, constraints: [trim?: false])
    attribute(:config, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    attribute(:upstream_revision, :string, public?: true, constraints: [trim?: false])
    attribute(:last_sync_at, :utc_datetime_usec, public?: true)
    attribute(:archived_at, :utc_datetime_usec, public?: true)
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

    # The Console list: the 100 most recently changed Sources.
    read :console_list do
      prepare(build(sort: [updated_at: :desc], limit: 100))
    end

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

    update :archive do
      require_atomic?(true)
      accept([])
      change(filter(expr(is_nil(archived_at))))
      change(set_attribute(:archived_at, &DateTime.utc_now/0))
      change(set_attribute(:updated_at, &DateTime.utc_now/0))
    end

    update :set_default_scope do
      require_atomic?(true)
      accept([:default_audience_scope])
      change(filter(expr(is_nil(archived_at) and kind == "oidc_client")))
      change(set_attribute(:updated_at, &DateTime.utc_now/0))
    end

    update :record_revision do
      require_atomic?(true)
      accept([:upstream_revision])
      change(filter(expr(is_nil(archived_at))))
      change(set_attribute(:last_sync_at, &DateTime.utc_now/0))
      change(set_attribute(:updated_at, &DateTime.utc_now/0))
    end

    update :record_sync do
      require_atomic?(true)
      accept([])
      change(filter(expr(is_nil(archived_at))))
      change(set_attribute(:last_sync_at, &DateTime.utc_now/0))
      change(set_attribute(:updated_at, &DateTime.utc_now/0))
    end

    update :record_watermark do
      require_atomic?(true)
      accept([:extracted_through_at, :extracted_through_seq])
      require_attributes([:extracted_through_at, :extracted_through_seq])
      change(filter(expr(is_nil(archived_at))))
    end

    update :invalidate_extraction do
      require_atomic?(true)
      accept([])
      change(set_attribute(:extracted_through_seq, 0))
      change(set_attribute(:extracted_through_at, nil))
      change(set_attribute(:upstream_revision, &Ecto.UUID.generate/0))
      change(set_attribute(:updated_at, &DateTime.utc_now/0))
    end

    # The Console registers a file or a URL Source;
    # Ankole.Brain.SourceLearning validates the kind and the scope.
    action :console_register, :struct do
      constraints(instance_of: __MODULE__)
      argument(:upstream_id, :string, allow_nil?: false, constraints: [trim?: false])
      argument(:kind, :string, allow_nil?: false)
      argument(:name, :string, allow_nil?: false)
      argument(:default_audience_scope, :string)
      argument(:config, Ankole.Ash.Types.JSONMap, default: %{})

      run(__MODULE__.Actions)
    end

    action :console_learn do
      argument(:source_id, :uuid, allow_nil?: false)

      run(__MODULE__.Actions)
    end

    # Each operation owns its transaction; Ankole.Brain.Sources gives the steps.
    action :archive_source, :struct do
      constraints(instance_of: __MODULE__)
      argument(:source_id, :uuid, allow_nil?: false)

      run(__MODULE__.Actions)
    end

    action :update_default_scope, :struct do
      constraints(instance_of: __MODULE__)
      argument(:source_id, :uuid, allow_nil?: false)
      argument(:scope, :string, constraints: [trim?: false, allow_empty?: true])

      run(__MODULE__.Actions)
    end

    # One learning run commits its page, its Claims, and the Source revision
    # together; Ankole.Brain.SourceLearning gives the steps.
    action :commit_learning_run, :map do
      argument(:run, :map, allow_nil?: false)

      run(__MODULE__.Actions)
    end

    # One OIDC Client conversation replaces its page and its Claims together;
    # Ankole.Brain.OIDCClientLearning gives the steps.
    action :learn_oidc_conversation, :map do
      argument(:run, :map, allow_nil?: false)

      run(__MODULE__.Actions)
    end

    # One conversation slice commits its memory writes and the extraction
    # watermark together; Ankole.Brain.ConversationsLearning gives the steps.
    action :finalize_conversation_slice, :map do
      argument(:slice, :map, allow_nil?: false)

      run(__MODULE__.Actions)
    end

    # The end of one Library projection withdraws the pages that left the set
    # and records the set revision; Ankole.Brain.LibraryKnowledge gives the steps.
    action :finish_library_projection, :integer do
      argument(:source, :struct, allow_nil?: false, constraints: [instance_of: __MODULE__])
      argument(:live_slugs, {:array, :string}, allow_nil?: false)
      argument(:fingerprint, :string, allow_nil?: false, constraints: [trim?: false])

      run(__MODULE__.Actions)
    end
  end

  @type t :: %__MODULE__{}
end
