defmodule Ankole.Pod.Page do
  @moduledoc "One page tree node, its document revision, and its trash state."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Pod

  postgres do
    table("pages")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:parent_id, "pages_tenant_id_parent_id_fkey"}])
    unique_index_names([{[:id], "pages_pkey"}])

    check_constraints do
      check_constraint(:type, "pages_type_check")
      check_constraint(:parent_id, "pages_private_owner")
      check_constraint(:purge_started_at, "pages_purge_state")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:parent_id, Ankole.Ash.Types.UUIDv7)
    attribute(:private_owner_uid, Ankole.Ash.Types.PrincipalKey)

    attribute(:type, :atom,
      allow_nil?: false,
      constraints: [one_of: [:doc, :database, :applet, :file]]
    )

    attribute(:title, :string,
      allow_nil?: false,
      default: "",
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:icon, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:position, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:inherit_permissions, :boolean, allow_nil?: false, default: true)
    attribute(:revision, :integer, allow_nil?: false, default: 0, constraints: [min: 0])
    attribute(:saved_from_message_id, Ankole.Ash.Types.UUIDv7)
    attribute(:created_by, Ankole.Ash.Types.ActorRef, allow_nil?: false)
    attribute(:deleted_at, :utc_datetime_usec)
    attribute(:purge_started_at, :utc_datetime_usec)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false)
  end

  calculations do
    calculate(:role, :string, expr(nil))
  end

  relationships do
    has_many :children, __MODULE__ do
      source_attribute(:id)
      destination_attribute(:parent_id)
    end

    has_one :content, Ankole.Pod.PageContent do
      source_attribute(:id)
      destination_attribute(:page_id)
    end
  end

  actions do
    defaults([:read])

    create :create_in_tx do
      accept([
        :id,
        :parent_id,
        :private_owner_uid,
        :type,
        :title,
        :icon,
        :position,
        :inherit_permissions,
        :revision,
        :saved_from_message_id,
        :created_by,
        :deleted_at,
        :purge_started_at,
        :created_at,
        :updated_at
      ])

      validate(Ankole.Pod.Validations.PageState)
    end

    update :edit do
      accept([:title, :icon, :updated_at])
    end

    update :move do
      accept([:parent_id, :private_owner_uid, :position, :updated_at])
      validate(Ankole.Pod.Validations.PageState)
    end

    update :position do
      require_atomic?(true)
      accept([:position])
    end

    update :sharing do
      require_atomic?(true)
      accept([:inherit_permissions])
    end

    update :trash do
      require_atomic?(true)
      accept([])
      change(set_attribute(:deleted_at, &DateTime.utc_now/0))
    end

    update :restore do
      require_atomic?(true)
      change(filter(expr(not is_nil(deleted_at) and is_nil(purge_started_at))))
      accept([])
      change(set_attribute(:deleted_at, nil))
    end

    update :begin_purge do
      require_atomic?(true)
      change(filter(expr(not is_nil(deleted_at))))
      accept([])
      change(set_attribute(:purge_started_at, &DateTime.utc_now/0))
    end

    update :advance_revision do
      require_atomic?(true)
      accept([:updated_at])
      change(atomic_update(:revision, expr(revision + 1)))
    end

    destroy :purge do
      require_atomic?(true)
      change(filter(expr(not exists(children, true))))
    end

    # Tree and permission writes. Each action owns its transaction; the body
    # takes the tree lock before page and permission rows.
    action :create_page, :term do
      argument(:uid, :term)
      argument(:attrs, :term)
      argument(:authority, :term)
      after_commit({Ankole.Pod.Pages, :committed})

      run(fn %{arguments: a}, _context ->
        Ankole.Pod.Access.write(a.authority, fn ->
          Ankole.Pod.Pages.create_in_tx(a.uid, a.attrs)
        end)
      end)
    end

    action :update_page, :term do
      argument(:uid, :term)
      argument(:id, :term)
      argument(:attrs, :term)
      argument(:authority, :term)
      after_commit({Ankole.Pod.Pages, :committed_page})

      run(fn %{arguments: a}, _context ->
        Ankole.Pod.Access.write(a.authority, fn ->
          Ankole.Pod.Pages.update_in_tx(a.uid, a.id, a.attrs)
        end)
      end)
    end

    action :move_page, :term do
      argument(:uid, :term)
      argument(:id, :term)
      argument(:attrs, :term)
      argument(:authority, :term)
      after_commit({Ankole.Pod.Pages, :committed})

      run(fn %{arguments: a}, _context ->
        Ankole.Pod.Access.write(a.authority, fn ->
          Ankole.Pod.Pages.move_in_tx(a.uid, a.id, a.attrs)
        end)
      end)
    end

    action :delete_page, :term do
      argument(:uid, :term)
      argument(:id, :term)
      argument(:authority, :term)
      after_commit({Ankole.Pod.Pages, :committed})

      run(fn %{arguments: a}, _context ->
        Ankole.Pod.Access.write(a.authority, fn -> Ankole.Pod.Pages.delete_in_tx(a.uid, a.id) end)
      end)
    end

    action :delete_embedded_page, :term do
      allow_nil?(true)
      argument(:uid, :term)
      argument(:parent_id, :term)
      argument(:child_id, :term)
      argument(:authority, :term)
      after_commit({Ankole.Pod.Pages, :committed})

      run(fn %{arguments: a}, _context ->
        Ankole.Pod.Access.write(a.authority, fn ->
          Ankole.Pod.Pages.delete_embed_in_tx(a.uid, a.parent_id, a.child_id)
        end)
      end)
    end

    action :restore_page, :term do
      argument(:uid, :term)
      argument(:id, :term)
      argument(:authority, :term)
      after_commit({Ankole.Pod.Pages, :committed})

      run(fn %{arguments: a}, _context ->
        Ankole.Pod.Access.write(a.authority, fn -> Ankole.Pod.Pages.restore_in_tx(a.uid, a.id) end)
      end)
    end

    action :set_page_sharing, :term do
      argument(:uid, :term)
      argument(:id, :term)
      argument(:attrs, :term)
      argument(:authority, :term)
      after_commit({Ankole.Pod.Pages, :committed})

      run(fn %{arguments: a}, _context ->
        Ankole.Pod.Access.write(a.authority, fn ->
          Ankole.Pod.Pages.set_sharing_in_tx(a.uid, a.id, a.attrs)
        end)
      end)
    end

    action :set_space_role, :term do
      argument(:uid, :term)
      argument(:role, :term)
      argument(:authority, :term)
      after_commit({Ankole.Pod.Pages, :committed})

      run(fn %{arguments: a}, _context ->
        Ankole.Pod.Access.write(a.authority, fn ->
          Ankole.Pod.Pages.set_space_in_tx(a.uid, a.role)
        end)
      end)
    end

    action :set_space_agent, :term do
      argument(:uid, :term)
      argument(:agent_uid, :term)
      argument(:role, :term)
      argument(:authority, :term)
      after_commit({Ankole.Pod.Pages, :committed})

      run(fn %{arguments: a}, _context ->
        Ankole.Pod.Access.write(a.authority, fn ->
          Ankole.Pod.Pages.space_agent_in_tx(a.uid, a.agent_uid, a.role)
        end)
      end)
    end

    action :remove_space_agent, :term do
      argument(:uid, :term)
      argument(:agent_uid, :term)
      argument(:authority, :term)
      after_commit({Ankole.Pod.Pages, :committed})

      run(fn %{arguments: a}, _context ->
        Ankole.Pod.Access.write(a.authority, fn ->
          Ankole.Pod.Pages.remove_space_agent_in_tx(a.uid, a.agent_uid)
        end)
      end)
    end

    # Reads under a shared page lock, so the page and its content or files
    # come from one revision.
    action :read_page, :term do
      argument(:uid, :term)
      argument(:id, :term)

      run(fn %{arguments: a}, _context ->
        Ankole.Errors.wrap(Ankole.Pod.Pages.get_in_tx(a.uid, a.id))
      end)
    end

    action :read_page_changes, :term do
      argument(:uid, :term)
      argument(:id, :term)
      argument(:revision, :term)

      run(fn %{arguments: a}, _context ->
        Ankole.Errors.wrap(Ankole.Pod.Documents.since_in_tx(a.uid, a.id, a.revision))
      end)
    end

    action :read_page_files, :term do
      argument(:uid, :term)
      argument(:id, :term)

      run(fn %{arguments: a}, _context ->
        Ankole.Errors.wrap(Ankole.Pod.Files.manifest_in_tx(a.uid, a.id))
      end)
    end

    action :read_applet, :term do
      argument(:uid, :term)
      argument(:id, :term)
      argument(:revision, :term)

      run(fn %{arguments: a}, _context ->
        Ankole.Errors.wrap(Ankole.Pod.Applets.published_in_tx(a.uid, a.id, a.revision))
      end)
    end

    # Content writes under the page row lock.
    action :write_document, :term do
      argument(:uid, :term)
      argument(:id, :term)
      argument(:base_revision, :term)
      argument(:validation, :term)
      argument(:authority, :term)
      after_commit({Ankole.Pod.Documents, :committed})

      run(fn %{arguments: a}, _context ->
        Ankole.Pod.Access.write(a.authority, fn ->
          Ankole.Pod.Documents.write_in_tx(a.uid, a.id, a.base_revision, a.validation)
        end)
      end)
    end

    action :apply_document_changes, :term do
      argument(:uid, :term)
      argument(:id, :term)
      argument(:batch, :term)
      argument(:authority, :term)
      after_commit({Ankole.Pod.Documents, :committed})

      run(fn %{arguments: a}, _context ->
        Ankole.Pod.Access.write(a.authority, fn ->
          Ankole.Pod.Documents.apply_in_tx(a.uid, a.id, a.batch)
        end)
      end)
    end

    action :commit_page_file, :term do
      argument(:uid, :term)
      argument(:id, :term)
      argument(:upload, :term)
      argument(:authority, :term)
      after_commit({Ankole.Pod.Files, :committed})

      run(fn %{arguments: a}, _context ->
        Ankole.Pod.Access.write(a.authority, fn ->
          Ankole.Pod.Files.commit_upload_in_tx(a.uid, a.id, a.upload)
        end)
      end)
    end

    action :publish_applet, :term do
      argument(:uid, :term)
      argument(:id, :term)
      argument(:base_revision, :term)
      argument(:upserts, :term)
      argument(:authority, :term)
      after_commit({Ankole.Pod.Files, :committed})

      run(fn %{arguments: a}, _context ->
        Ankole.Pod.Access.write(a.authority, fn ->
          Ankole.Pod.Files.publish_in_tx(a.uid, a.id, a.base_revision, a.upserts)
        end)
      end)
    end

    # Purge steps of a deleted subtree. Each step commits alone, so an
    # interrupted purge continues from the remaining rows.
    action :start_purge, :term do
      allow_nil?(true)
      argument(:id, :term)

      run(fn %{arguments: a}, _context ->
        Ankole.Errors.wrap(Ankole.Pod.Jobs.PurgePage.start_in_tx(a.id))
      end)
    end

    action :purge_page_references, :term do
      argument(:id, :term)

      run(fn %{arguments: a}, _context ->
        Ankole.Errors.wrap(Ankole.Pod.Jobs.PurgePage.remove_references_in_tx(a.id))
      end)
    end

    action :purge_pages, :term do
      argument(:ids, :term)

      run(fn %{arguments: a}, _context ->
        Ankole.Errors.wrap(Ankole.Pod.Jobs.PurgePage.remove_pages_in_tx(a.ids))
      end)
    end
  end

  @type t :: %__MODULE__{}
end
