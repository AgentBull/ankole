defmodule Ankole.Files.Schemas.DriveFile do
  @moduledoc """
  Owns a path in an Agent or Pod drive.

  The tenant, nullable Agent, and path form the existing natural identity.
  Pod paths use a nil Agent. Size comes from the referenced content row.
  """
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Files.Domain
  require Ecto.Query

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
        {:error, reason} -> {:error, Ankole.Ash.DomainError.exception(reason: reason)}
      end
    end)
  end

  actions do
    defaults([:read])

    create :commit do
      transaction?(false)
      change(Ankole.Ash.RequireTransaction)

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
      transaction?(false)
      change(Ankole.Ash.RequireTransaction)

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

    action :remove_paths, {:array, :struct} do
      transaction?(false)
      constraints(items: [instance_of: __MODULE__])
      argument(:agent_uid, Ankole.Ash.Types.PrincipalKey)
      argument(:path, :string, allow_nil?: false, constraints: [trim?: false])

      run(fn input, _context ->
        unless Ankole.Repo.in_transaction?(), do: raise(ArgumentError, "transaction required")

        case Ankole.Files.normalize_path(input.arguments.path) do
          {:ok, path} ->
            prefix = Ankole.Repo.escape_like(path) <> "/%"

            query =
              Ecto.Query.from(file in __MODULE__,
                where: file.path == ^path or like(file.path, ^prefix),
                select: file
              )

            query =
              case input.arguments.agent_uid do
                nil -> Ecto.Query.where(query, [file], is_nil(file.agent_uid))
                uid -> Ecto.Query.where(query, [file], file.agent_uid == ^uid)
              end

            {_count, files} = Ankole.Repo.delete_all(query)
            {:ok, files}

          {:error, reason} ->
            {:error, Ankole.Ash.DomainError.exception(reason: reason)}
        end
      end)
    end
  end

  @type t :: %__MODULE__{}
  defdelegate sources(), to: Ankole.Files.Source, as: :all
end
