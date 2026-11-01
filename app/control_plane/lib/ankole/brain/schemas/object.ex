defmodule Ankole.Brain.Schemas.Object do
  @moduledoc "A current knowledge page with explicit content, ownership, and projection writes."
  use Ankole.Ash.Resource,
    authorizers: [Ankole.AuthZ.Authorizer],
    tenancy: :tenant,
    domain: Ankole.Brain,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:site_console)
    allow(:console_list, resource: "site_console:brain", action: "read")
    allow(:console_create, resource: "site_console:brain", action: "update")
    allow(:console_update, resource: "site_console:brain", action: "update")
    allow(:fork_library_page, resource: "site_console:brain", action: "update")
    allow(:console_rollback, resource: "site_console:brain", action: "update")
    allow(:console_forget, resource: "site_console:brain", action: "update")
    allow(:restore_object, resource: "site_console:brain", action: "update")
  end

  # The resource gives summary fields. `GET /api/v2/brain/objects/show` gives
  # the page body, Claims, and links.
  json_api do
    type("brain_object")
    derive_filter?(false)
    derive_sort?(false)

    default_fields([
      :slug,
      :type,
      :subtype,
      :title,
      :effective_date,
      :managed_by_source_id,
      :deleted_at,
      :updated_at
    ])
  end

  postgres do
    table("brain_objects")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(slug: "brain_objects_slug_key")
    foreign_key_names([{:managed_by_source_id, "brain_objects_managed_by_source_id_fkey"}])

    check_constraints do
      check_constraint(:slug, "brain_objects_slug_present")
      check_constraint(:type, "brain_objects_type_present")
      check_constraint(:title, "brain_objects_title_present")
      check_constraint(:meta, "brain_objects_meta_object")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:slug, :string, allow_nil?: false, public?: true, constraints: [trim?: false])
    attribute(:type, :string, allow_nil?: false, public?: true, constraints: [trim?: false])
    attribute(:subtype, :string, public?: true, constraints: [trim?: false])
    attribute(:title, :string, allow_nil?: false, public?: true, constraints: [trim?: false])

    attribute(:body, :string,
      allow_nil?: false,
      default: "",
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:meta, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    attribute(:effective_date, :date, public?: true)
    attribute(:content_hash, :string, constraints: [trim?: false])
    attribute(:chunking_signature, :string, constraints: [trim?: false])
    attribute(:last_retrieved_at, :utc_datetime_usec)
    attribute(:links_extracted_at, :utc_datetime_usec)
    attribute(:timelines_extracted_at, :utc_datetime_usec)
    attribute(:deleted_at, :utc_datetime_usec, public?: true)
    attribute(:managed_by_source_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
    # Projection writes must not advance the logical content clock.
    attribute(:updated_at, :utc_datetime_usec,
      allow_nil?: false,
      public?: true,
      default: &DateTime.utc_now/0
    )
  end

  identities do
    identity(:slug, [:slug])
  end

  @content [
    :title,
    :body,
    :meta,
    :subtype,
    :effective_date,
    :content_hash,
    :updated_at,
    :links_extracted_at,
    :timelines_extracted_at
  ]
  @initial [
    :id,
    :slug,
    :type,
    :title,
    :body,
    :meta,
    :subtype,
    :effective_date,
    :content_hash,
    :updated_at,
    :created_at
  ]

  actions do
    defaults([:read])

    # The Console list: a slug prefix, a title or slug search, and the live
    # or the soft-deleted objects.
    read :console_list do
      pagination(keyset?: true, default_limit: 100, max_page_size: 100, countable: false)

      argument(:prefix, :string, constraints: [trim?: false])
      argument(:search, :string)
      argument(:deleted, :boolean, default: false)
      prepare(__MODULE__.Preparations)
    end

    create :create do
      accept(@initial)
    end

    create :create_projection do
      accept([:managed_by_source_id | @initial])
      require_attributes([:managed_by_source_id])
    end

    create_if_absent :ensure_canonical do
      accept(@initial)
      upsert_identity(:slug)
    end

    update :edit do
      require_atomic?(true)
      accept(@content)
      argument(:expected_content_hash, :string, allow_nil?: false, constraints: [trim?: false])

      change(
        filter(
          expr(
            is_nil(managed_by_source_id) and is_nil(deleted_at) and
              content_hash == ^arg(:expected_content_hash)
          )
        )
      )
    end

    update :project do
      require_atomic?(true)
      accept([:type, :deleted_at | @content])
      argument(:source_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
      change(filter(expr(managed_by_source_id == ^arg(:source_id))))
    end

    update :forget do
      require_atomic?(true)
      accept([:meta, :content_hash])
      change(filter(expr(is_nil(managed_by_source_id))))
      change(set_attribute(:deleted_at, &DateTime.utc_now/0))
    end

    update :restore do
      require_atomic?(true)
      accept([:meta, :content_hash])
      change(filter(expr(is_nil(managed_by_source_id))))
      change(set_attribute(:deleted_at, nil))
    end

    update :withdraw_projection do
      require_atomic?(true)
      accept([])
      argument(:source_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
      change(filter(expr(managed_by_source_id == ^arg(:source_id) and is_nil(deleted_at))))
      change(set_attribute(:deleted_at, &DateTime.utc_now/0))
    end

    update :fork do
      require_atomic?(true)
      accept([])
      change(filter(expr(not is_nil(managed_by_source_id) and type != "agent-skills")))
      change(set_attribute(:managed_by_source_id, nil))
    end

    update :retype do
      require_atomic?(true)
      accept([:slug, :type])
      change(filter(expr(is_nil(managed_by_source_id) and is_nil(deleted_at))))
      change(set_attribute(:updated_at, &DateTime.utc_now/0))
    end

    update :refresh_hash do
      require_atomic?(true)
      accept([:content_hash])
    end

    update :rename_references do
      accept([:body])
      change(set_attribute(:updated_at, &DateTime.utc_now/0))
    end

    update :stamp_chunking do
      require_atomic?(true)
      accept([:chunking_signature])
    end

    update :stamp_links do
      require_atomic?(true)
      accept([])
      change(atomic_update(:links_extracted_at, expr(updated_at)))
    end

    update :stamp_timelines do
      require_atomic?(true)
      accept([])
      argument(:content_updated_at, :utc_datetime_usec, allow_nil?: false)
      change(filter(expr(updated_at == ^arg(:content_updated_at))))
      change(atomic_update(:timelines_extracted_at, expr(updated_at)))
    end

    update :touch_retrieved do
      require_atomic?(true)
      accept([])
      change(set_attribute(:last_retrieved_at, &DateTime.utc_now/0))
    end

    destroy :purge do
      require_atomic?(true)
      change(filter(expr(not is_nil(deleted_at) and is_nil(managed_by_source_id))))
    end

    destroy :merge_duplicate do
      require_atomic?(true)
      change(filter(expr(is_nil(managed_by_source_id))))
    end

    action :fork_library_page, :struct do
      constraints(instance_of: __MODULE__)
      argument(:slug, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])

      run(__MODULE__.Actions)
    end

    action :restore_object, :struct do
      constraints(instance_of: __MODULE__)
      argument(:slug, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])

      run(__MODULE__.Actions)
    end

    # The Console operations. The operator is the actor of the action
    # (Ankole.Brain.Console).
    action :console_create, :struct do
      constraints(instance_of: __MODULE__)
      argument(:slug, :string, allow_nil?: false)
      argument(:type, :string, allow_nil?: false)
      argument(:subtype, :string)
      argument(:title, :string, allow_nil?: false)
      argument(:body, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])
      argument(:meta, Ankole.Ash.Types.JSONMap, allow_nil?: false)
      argument(:effective_date, :date)
      argument(:tags, {:array, :string}, default: [])

      run(__MODULE__.Actions)
    end

    # The content hash is a compare-and-swap token: the edit fails when the
    # object changed after the editor read it. Without tags, the tags stay.
    action :console_update, :struct do
      constraints(instance_of: __MODULE__)
      argument(:slug, :string, allow_nil?: false, constraints: [trim?: false])
      argument(:expected_content_hash, :string, allow_nil?: false)
      argument(:subtype, :string)
      argument(:title, :string, allow_nil?: false)
      argument(:body, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])
      argument(:meta, Ankole.Ash.Types.JSONMap, allow_nil?: false)
      argument(:effective_date, :date)
      argument(:tags, {:array, :string})

      run(__MODULE__.Actions)
    end

    action :console_rollback, :struct do
      constraints(instance_of: __MODULE__)
      argument(:slug, :string, allow_nil?: false, constraints: [trim?: false])
      argument(:version_id, :uuid, allow_nil?: false)

      run(__MODULE__.Actions)
    end

    action :console_forget, :struct do
      constraints(instance_of: __MODULE__)
      argument(:slug, :string, allow_nil?: false, constraints: [trim?: false])
      argument(:reason, :string, constraints: [trim?: false, allow_empty?: true])

      run(__MODULE__.Actions)
    end
  end

  relationships do
    has_many :tags, Ankole.Brain.Schemas.Tag do
      source_attribute(:slug)
      destination_attribute(:object_slug)
    end
  end

  @doc false
  def verify_content_hash(_object, nil), do: {:error, :missing_expected_content_hash}

  def verify_content_hash(%__MODULE__{content_hash: current}, expected),
    do: if(current == expected, do: :ok, else: {:error, :content_hash_conflict})

  @type t :: %__MODULE__{}
end
