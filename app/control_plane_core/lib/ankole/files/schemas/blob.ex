defmodule Ankole.Files.Schemas.Blob do
  @moduledoc """
  Owns stored byte content and its collection fence.

  References refresh the row while it is not marked for deletion. Collection
  checks every tenant's durable references before it marks or removes content.
  """
  use Ankole.Ash.Resource, tenancy: :site, domain: Ankole.Files.Domain
  require Ash.Expr

  @unreferenced Ash.Expr.expr(
                  fragment(
                    """
                    NOT EXISTS (SELECT 1 FROM drive_files AS drive WHERE drive.sha256 = ?)
                    AND NOT EXISTS (
                      SELECT 1 FROM deliveries AS intent
                      WHERE intent.status IN ('pending', 'failed', 'unknown')
                        AND intent.payload @> jsonb_build_object('attachments',
                          jsonb_build_array(jsonb_build_object('blob_ref', encode(?, 'hex'))))
                    )
                    AND NOT EXISTS (
                      SELECT 1 FROM conversation_messages AS message,
                        unnest(message.attachments) AS attachment(value)
                      WHERE attachment.value->>'blob_ref' = encode(?, 'hex')
                    )
                    """,
                    sha256,
                    sha256,
                    sha256
                  )
                )

  postgres do
    table("files")
    repo(Ankole.Repo)
    migrate?(false)

    check_constraints do
      check_constraint(:sha256, "files_sha256_length")
      check_constraint(:size, "files_size_non_negative")
    end
  end

  attributes do
    attribute(:sha256, :binary, primary_key?: true, allow_nil?: false)
    attribute(:size, :integer, allow_nil?: false, constraints: [min: 0])
    attribute(:deleting, :boolean, default: false, allow_nil?: false)

    attribute(:created_at, :utc_datetime_usec,
      allow_nil?: false,
      generated?: true,
      writable?: false
    )

    attribute(:last_referenced_at, :utc_datetime_usec,
      allow_nil?: false,
      generated?: true,
      writable?: false
    )
  end

  actions do
    defaults([:read])

    create :store do
      transaction?(false)
      accept([:sha256, :size])
      validate(byte_size(:sha256, exact: 32))

      manual(fn changeset, _context ->
        %{columns: columns, rows: [row]} =
          Ankole.Repo.query!(
            """
            INSERT INTO files (sha256, size, deleting, created_at, last_referenced_at)
            VALUES ($1, $2, false, now(), now())
            ON CONFLICT (sha256) DO UPDATE
              SET last_referenced_at = now(), deleting = false
            RETURNING sha256, size, deleting, created_at, last_referenced_at
            """,
            [
              Ash.Changeset.get_attribute(changeset, :sha256),
              Ash.Changeset.get_attribute(changeset, :size)
            ]
          )

        {:ok, Ankole.Repo.load(__MODULE__, {columns, row})}
      end)
    end

    atomic_in_tx_update :reference do
      accept([])
      change(filter(expr(not deleting)))
      change(set_attribute(:last_referenced_at, &DateTime.utc_now/0))
    end

    update :mark_for_collection do
      transaction?(false)
      require_atomic?(true)
      accept([])
      change(filter(expr(not deleting and last_referenced_at < ago(1, :day))))
      change(filter(@unreferenced))
      change(set_attribute(:deleting, true))
    end

    atomic_in_tx_update :keep_referenced do
      accept([])
      change(set_attribute(:deleting, false))
    end

    destroy :collect do
      transaction?(false)
      require_atomic?(true)
      change(filter(expr(deleting)))
      change(filter(@unreferenced))
    end
  end

  @type t :: %__MODULE__{}
end
