defmodule Ankole.Files.Schemas.DriveFile do
  @moduledoc """
  Owns a path in an Agent or Pod drive.

  The tenant, nullable Agent, and path form the existing natural identity.
  Pod paths use a nil Agent. Size comes from the referenced content row.
  """
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Files

  resource do
    require_primary_key?(false)
  end

  postgres do
    table("drive_files")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(drive_path: "drive_files_identity_index")

    foreign_key_names([
      {:agent_uid, "agent_files_agent_uid_fkey"},
      {:sha256, "agent_files_sha256_fkey"},
      {:conversation_id, "agent_files_conversation_id_fkey"},
      {:message_id, "agent_files_message_id_fkey"}
    ])

    check_constraints do
      check_constraint(:path, "agent_files_path_shape")
      check_constraint(:mode, "agent_files_mode")
      check_constraint(:source, "drive_files_source")
    end
  end

  attributes do
    attribute(:agent_uid, Ankole.Ash.Types.PrincipalKey)
    attribute(:path, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:sha256, :binary, allow_nil?: false)

    attribute(:mode, :integer,
      default: 0o644,
      allow_nil?: false,
      constraints: [min: 0, max: 0o777]
    )

    attribute(:content_type, :string, allow_nil?: false)
    attribute(:source, :string, allow_nil?: false)
    attribute(:conversation_id, Ankole.Ash.Types.UUIDv7)
    attribute(:message_id, Ankole.Ash.Types.UUIDv7)
    create_timestamp(:inserted_at, type: :utc_datetime_usec, writable?: true)
    update_timestamp(:updated_at, type: :utc_datetime_usec)
  end

  identities do
    identity(:drive_path, [:agent_uid, :path], nils_distinct?: false)
  end

  relationships do
    belongs_to :blob, Ankole.Files.Schemas.Blob do
      source_attribute(:sha256)
      destination_attribute(:sha256)
      define_attribute?(false)
      allow_nil?(false)
    end
  end

  aggregates do
    first(:size, :blob, :size)
  end

  validations do
    validate(attribute_in(:source, Ankole.Files.Source.all()))
    validate(byte_size(:sha256, exact: 32))

    validate(fn changeset, _context ->
      case Ankole.Files.normalize_path(Ash.Changeset.get_attribute(changeset, :path)) do
        {:ok, _path} -> :ok
        {:error, reason} -> {:error, Ankole.Errors.Invalid.Rejected.exception(reason: reason)}
      end
    end)
  end

  actions do
    defaults([:read])

    create :commit do
      accept([
        :agent_uid,
        :path,
        :sha256,
        :mode,
        :content_type,
        :source,
        :conversation_id,
        :message_id
      ])

      upsert?(true)
      upsert_identity(:drive_path)

      upsert_fields([
        :sha256,
        :mode,
        :content_type,
        :source,
        :conversation_id,
        :message_id,
        :updated_at
      ])
    end

    create :move do
      accept([
        :agent_uid,
        :path,
        :sha256,
        :mode,
        :content_type,
        :source,
        :conversation_id,
        :message_id,
        :inserted_at
      ])

      upsert?(true)
      upsert_identity(:drive_path)
      upsert_fields([:path])
      upsert_condition(expr(false))
    end

    # Drive operations. Each one owns its transaction and takes the drive lock
    # before it reads or changes paths.
    action :commit_paths, :term do
      argument(:drive, :term)
      argument(:upserts, :term)
      argument(:deletes, :term)

      run(fn %{arguments: a}, _context ->
        Ankole.Errors.wrap(Ankole.Files.commit(Ankole.Repo, a.drive, a.upserts, a.deletes))
      end)
    end

    action :move_paths, :term do
      argument(:drive, :term)
      argument(:from, :term)
      argument(:to, :term)

      run(fn %{arguments: a}, _context ->
        Ankole.Errors.wrap(Ankole.Files.move_in_tx(a.drive, a.from, a.to))
      end)
    end

    action :delete_paths, :term do
      argument(:drive, :term)
      argument(:path, :term)

      run(fn %{arguments: a}, _context ->
        Ankole.Errors.wrap(Ankole.Files.delete_in_tx(a.drive, a.path))
      end)
    end

    action :list_snapshot, :term do
      argument(:drive, :term)
      argument(:prefix, :term)
      argument(:opts, :term)

      run(fn %{arguments: a}, _context ->
        Ankole.Errors.wrap(Ankole.Files.list_snapshot_in_tx(a.drive, a.prefix, a.opts))
      end)
    end
  end

  @doc """
  Deletes a drive path and its descendants in the caller's transaction.

  `nil` selects the Pod drive. The result gives the deleted rows. The table has
  no primary key, so AshPostgres has no destroy action for it; one statement
  removes the subtree of the current tenant.
  """
  def remove_paths_in_tx(agent_uid, path) do
    unless Ankole.Repo.in_transaction?(),
      do:
        raise(Ankole.Errors.Framework.TransactionRequired,
          operation: {__MODULE__, :remove_paths_in_tx}
        )

    with {:ok, path} <- Ankole.Files.normalize_path(path) do
      prefix = Ankole.Repo.escape_like(path) <> "/%"

      {drive, params} =
        if agent_uid, do: {"agent_uid = $4", [agent_uid]}, else: {"agent_uid IS NULL", []}

      %{columns: columns, rows: rows} =
        Ankole.Repo.query!(
          """
          DELETE FROM drive_files
          WHERE tenant_id = $1::text::uuid AND #{drive} AND (path = $2 OR path LIKE $3)
          RETURNING #{Enum.join(__schema__(:fields), ", ")}
          """,
          [Ankole.Repo.tenant_id!(), path, prefix | params]
        )

      {:ok, Enum.map(rows, &Ankole.Repo.load(__MODULE__, {columns, &1}))}
    end
  end

  @type t :: %__MODULE__{}
  defdelegate sources(), to: Ankole.Files.Source, as: :all
end
