defmodule Ankole.Repo.Migrations.CreateAIGatewayArtifacts do
  use Ecto.Migration

  def up do
    create table(:ai_gateway_artifacts, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :subject_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          null: false

      add :message_id,
          references(:ai_gateway_messages, type: :uuid, on_delete: :delete_all)

      add :kind, :text, null: false
      add :filename, :text
      add :purpose, :text
      add :mime_type, :text, null: false
      add :byte_size, :bigint, null: false
      add :sha256, :binary, null: false
      add :payload, :binary, null: false
      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ai_gateway_artifacts, [:subject_uid, :kind, :inserted_at, :id],
             name: :ai_gateway_artifacts_owner_list_index
           )

    create index(:ai_gateway_artifacts, [:message_id],
             name: :ai_gateway_artifacts_message_index,
             where: "message_id IS NOT NULL"
           )

    create index(:ai_gateway_artifacts, [:expires_at],
             name: :ai_gateway_artifacts_expiry_index,
             where: "expires_at IS NOT NULL"
           )

    create constraint(:ai_gateway_artifacts, :ai_gateway_artifacts_kind_check,
             check: "kind IN ('uploaded_file', 'generated_image')"
           )

    create constraint(:ai_gateway_artifacts, :ai_gateway_artifacts_payload_size_check,
             check: "byte_size >= 0 AND byte_size = octet_length(payload)"
           )

    create constraint(:ai_gateway_artifacts, :ai_gateway_artifacts_sha256_size_check,
             check: "octet_length(sha256) = 32"
           )

    create constraint(:ai_gateway_artifacts, :ai_gateway_artifacts_uploaded_file_contract,
             check:
               "kind <> 'uploaded_file' OR (message_id IS NULL AND filename IS NOT NULL AND purpose = 'vision')"
           )

    create constraint(:ai_gateway_artifacts, :ai_gateway_artifacts_generated_image_contract,
             check: "kind <> 'generated_image' OR purpose IS NULL"
           )

    execute(
      "COMMENT ON TABLE ai_gateway_artifacts IS 'Principal-scoped uploaded files and generated images for AIGateway hosted tools.'",
      ""
    )
  end

  def down do
    drop table(:ai_gateway_artifacts)
  end
end
