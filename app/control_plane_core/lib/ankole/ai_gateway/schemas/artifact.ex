defmodule Ankole.AIGateway.Schemas.Artifact do
  @moduledoc "Principal-owned image bytes with explicit payload selection and atomic collection."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.AIGateway

  postgres do
    table("ai_gateway_artifacts")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names(
      subject_uid: "ai_gateway_artifacts_subject_uid_fkey",
      message_id: "ai_gateway_artifacts_message_id_fkey"
    )

    check_constraints do
      check_constraint(:kind, "ai_gateway_artifacts_kind_check")
      check_constraint(:payload, "ai_gateway_artifacts_payload_size_check")
      check_constraint(:sha256, "ai_gateway_artifacts_sha256_size_check")
      check_constraint(:purpose, "ai_gateway_artifacts_uploaded_file_contract")
      check_constraint(:purpose, "ai_gateway_artifacts_generated_image_contract")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:subject_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false)
    attribute(:message_id, Ankole.Ash.Types.UUIDv7)

    attribute(:kind, :atom,
      allow_nil?: false,
      constraints: [one_of: [:uploaded_file, :generated_image]]
    )

    attribute(:provider_item_id, :string, constraints: [trim?: false])
    attribute(:filename, :string, constraints: [trim?: false])
    attribute(:purpose, :string, constraints: [trim?: false])
    attribute(:mime_type, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:byte_size, :integer, allow_nil?: false, constraints: [min: 0])
    attribute(:sha256, :binary, allow_nil?: false)
    attribute(:payload, :binary, allow_nil?: false, sensitive?: true, select_by_default?: false)
    attribute(:expires_at, :utc_datetime_usec)
    create_timestamp(:inserted_at, type: :utc_datetime_usec)
    update_timestamp(:updated_at, type: :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    create :upload do
      accept([:subject_uid, :filename, :purpose, :mime_type, :payload, :expires_at])
      change(set_attribute(:kind, :uploaded_file))
      change(Ankole.AIGateway.Changes.PrepareArtifact, only_when_valid?: true)
      validate(present([:filename, :purpose]))

      validate(fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :filename) do
          value when is_binary(value) ->
            if String.trim(value) == "",
              do: {:error, field: :filename, message: "is required"},
              else: :ok

          _missing ->
            :ok
        end
      end)

      validate(one_of(:purpose, ["vision"]))
    end

    create :generate_image do
      accept([
        :id,
        :subject_uid,
        :message_id,
        :provider_item_id,
        :filename,
        :mime_type,
        :payload,
        :expires_at
      ])

      change(set_attribute(:kind, :generated_image))
      change(Ankole.AIGateway.Changes.PrepareArtifact, only_when_valid?: true)
    end

    destroy :remove do
      require_atomic?(true)
      change(filter(expr(kind == :uploaded_file)))
    end

    destroy :collect do
      require_atomic?(true)
      argument(:now, :utc_datetime_usec, allow_nil?: false, public?: false)

      change(
        filter(
          expr(
            (not is_nil(expires_at) and expires_at <= ^arg(:now)) or
              (kind == :generated_image and is_nil(expires_at) and
                 (is_nil(message_id) or
                    fragment(
                      "EXISTS (SELECT 1 FROM ai_gateway_messages AS message WHERE message.id = ? AND message.tenant_id = ? AND message.status = 'error')",
                      message_id,
                      tenant_id
                    )))
          )
        )
      )
    end

    action :persist_output, :term do
      argument(:subject_uid, :term, allow_nil?: false)
      argument(:output, :term, allow_nil?: false)
      argument(:options, :term, allow_nil?: false, default: [])

      run(fn input, _context ->
        input.arguments
        |> Ankole.AIGateway.ImageStreamPersistence.persist_output()
        |> Ankole.Errors.wrap()
      end)
    end
  end

  @type t :: %__MODULE__{}
end
