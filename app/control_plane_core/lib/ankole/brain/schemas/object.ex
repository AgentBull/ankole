defmodule Ankole.Brain.Schemas.Object do
  @moduledoc "A current knowledge page with explicit content, ownership, and projection writes."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Brain.Domain

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

    attribute(:slug, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:type, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:subtype, :string, constraints: [trim?: false])
    attribute(:title, :string, allow_nil?: false, constraints: [trim?: false])

    attribute(:body, :string,
      allow_nil?: false,
      default: "",
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:meta, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    attribute(:effective_date, :date)
    attribute(:content_hash, :string, constraints: [trim?: false])
    attribute(:chunking_signature, :string, constraints: [trim?: false])
    attribute(:last_retrieved_at, :utc_datetime_usec)
    attribute(:links_extracted_at, :utc_datetime_usec)
    attribute(:timelines_extracted_at, :utc_datetime_usec)
    attribute(:deleted_at, :utc_datetime_usec)
    attribute(:managed_by_source_id, Ankole.Ash.Types.UUIDv7)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
    # Projection writes must not advance the logical content clock.
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
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

    create :create do
      transaction?(false)
      change(Ankole.Ash.RequireTransaction)
      accept(@initial)
    end

    create :create_projection do
      transaction?(false)
      change(Ankole.Ash.RequireTransaction)
      accept([:managed_by_source_id | @initial])
      require_attributes([:managed_by_source_id])
    end

    create_if_absent :ensure_canonical do
      transaction?(false)
      change(Ankole.Ash.RequireTransaction)
      accept(@initial)
      upsert_identity(:slug)
    end

    atomic_in_tx_update :edit do
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

    atomic_in_tx_update :project do
      accept([:type, :deleted_at | @content])
      argument(:source_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
      change(filter(expr(managed_by_source_id == ^arg(:source_id))))
    end

    atomic_in_tx_update :forget do
      accept([:meta, :content_hash])
      change(filter(expr(is_nil(managed_by_source_id))))
      change(set_attribute(:deleted_at, &DateTime.utc_now/0))
    end

    atomic_in_tx_update :restore do
      accept([:meta, :content_hash])
      change(filter(expr(is_nil(managed_by_source_id))))
      change(set_attribute(:deleted_at, nil))
    end

    atomic_in_tx_update :withdraw_projection do
      accept([])
      argument(:source_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
      change(filter(expr(managed_by_source_id == ^arg(:source_id) and is_nil(deleted_at))))
      change(set_attribute(:deleted_at, &DateTime.utc_now/0))
    end

    atomic_in_tx_update :fork do
      accept([])
      change(filter(expr(not is_nil(managed_by_source_id) and type != "agent-skills")))
      change(set_attribute(:managed_by_source_id, nil))
    end

    atomic_in_tx_update :retype do
      accept([:slug, :type])
      change(filter(expr(is_nil(managed_by_source_id) and is_nil(deleted_at))))
      change(set_attribute(:updated_at, &DateTime.utc_now/0))
    end

    atomic_in_tx_update :refresh_hash do
      accept([:content_hash])
    end

    atomic_in_tx_update :stamp_chunking do
      accept([:chunking_signature])
    end

    atomic_in_tx_update :stamp_links do
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
      transaction?(false)
      require_atomic?(true)
      change(Ankole.Ash.RequireTransaction.Atomic)
      change(filter(expr(not is_nil(deleted_at) and is_nil(managed_by_source_id))))
    end

    destroy :merge_duplicate do
      transaction?(false)
      require_atomic?(true)
      change(Ankole.Ash.RequireTransaction.Atomic)
      change(filter(expr(is_nil(managed_by_source_id))))
    end
  end

  @doc false
  def verify_content_hash(_object, nil), do: {:error, :missing_expected_content_hash}

  def verify_content_hash(%__MODULE__{content_hash: current}, expected),
    do: if(current == expected, do: :ok, else: {:error, :content_hash_conflict})

  @type t :: %__MODULE__{}
end
