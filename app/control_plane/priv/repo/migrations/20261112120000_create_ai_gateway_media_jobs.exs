defmodule Ankole.Repo.Migrations.CreateAIGatewayMediaJobs do
  use Ecto.Migration

  # A media job is one video or music generation, which the Provider finishes
  # after the gateway request has returned. A completed job references the
  # generated file in the tenant's object storage.
  #
  # Replacing the usage check takes an exclusive lock on the usage table, and
  # PostgreSQL reads every row under that lock to validate the new check.
  # Gateway calls that write the usage ledger and quota checks that read it
  # wait until the migration commits, for a time that grows with the number of
  # rows.
  #
  # Rolling back fails once a video or music usage row exists, because the
  # narrower check rejects it. Delete those rows first.
  def up do
    create table(:ai_gateway_media_jobs, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :tenant_id, references(:tenants, type: :uuid, on_delete: :restrict), null: false
      add :subject_uid, :text, null: false
      add :subject_type, :text
      add :capability, :text, null: false
      add :provider_id, :text, null: false
      add :model, :text, null: false
      add :request, :map, null: false
      add :request_context, :map, null: false
      add :status, :text, null: false
      add :upstream_job_id, :text
      add :result_url, :text
      add :usage, :map
      add :object_id, :uuid
      add :content_type, :text
      add :byte_size, :bigint
      add :error, :map
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:ai_gateway_media_jobs, [:tenant_id, :subject_uid])
    create index(:ai_gateway_media_jobs, [:tenant_id, :object_id])
    create index(:ai_gateway_media_jobs, [:expires_at])

    execute("""
    ALTER TABLE ai_gateway_media_jobs ADD CONSTRAINT ai_gateway_media_jobs_subject_uid_fkey
      FOREIGN KEY (tenant_id, subject_uid) REFERENCES principals (tenant_id, uid)
      ON DELETE CASCADE ON UPDATE CASCADE
    """)

    execute("""
    ALTER TABLE ai_gateway_media_jobs ADD CONSTRAINT ai_gateway_media_jobs_object_fkey
      FOREIGN KEY (tenant_id, object_id) REFERENCES file_objects (tenant_id, id)
      ON DELETE RESTRICT
    """)

    create constraint(:ai_gateway_media_jobs, :ai_gateway_media_jobs_capability_check,
             check: "capability IN ('video', 'music')"
           )

    create constraint(:ai_gateway_media_jobs, :ai_gateway_media_jobs_status_check,
             check: "status IN ('pending', 'in_progress', 'completed', 'failed')"
           )

    create constraint(:ai_gateway_media_jobs, :ai_gateway_media_jobs_completed_object_check,
             check: "(status = 'completed') = (object_id IS NOT NULL)"
           )

    replace_usage_capability_check(
      "capability IN ('llm', 'image_generate', 'decision', 'speech', 'transcription', 'ocr', 'video', 'music')"
    )
  end

  def down do
    replace_usage_capability_check(
      "capability IN ('llm', 'image_generate', 'decision', 'speech', 'transcription', 'ocr')"
    )

    drop table(:ai_gateway_media_jobs)
  end

  defp replace_usage_capability_check(check) do
    drop constraint(:ai_gateway_usage_records, :ai_gateway_usage_records_capability_check)

    create constraint(:ai_gateway_usage_records, :ai_gateway_usage_records_capability_check,
             check: check
           )
  end
end
