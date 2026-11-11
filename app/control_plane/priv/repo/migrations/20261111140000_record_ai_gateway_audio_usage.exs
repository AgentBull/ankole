defmodule Ankole.Repo.Migrations.RecordAIGatewayAudioUsage do
  use Ecto.Migration

  # A usage row can name a speech or a transcription call. A speech call counts
  # the characters that it turned into audio, and a transcription call counts
  # the seconds of audio that the Provider reports.
  #
  # Replacing a check takes an exclusive lock on the table, and PostgreSQL
  # reads every row under that lock to validate the new check. Gateway calls
  # that write the usage ledger and quota checks that read it wait until the
  # migration commits, for a time that grows with the number of rows.
  #
  # Rolling back fails once a speech or a transcription row exists, because the narrower checks reject
  # it. Delete those rows first.
  def up do
    replace_checks(
      "capability IN ('llm', 'image_generate', 'decision', 'speech', 'transcription')",
      "unit IN ('image', 'character', 'second')"
    )
  end

  def down do
    replace_checks("capability IN ('llm', 'image_generate', 'decision')", "unit IN ('image')")
  end

  defp replace_checks(capability_check, unit_check) do
    drop constraint(:ai_gateway_usage_records, :ai_gateway_usage_records_capability_check)
    drop constraint(:ai_gateway_usage_records, :ai_gateway_usage_records_quantity_check)

    create constraint(
             :ai_gateway_usage_records,
             :ai_gateway_usage_records_capability_check,
             check: capability_check
           )

    create constraint(
             :ai_gateway_usage_records,
             :ai_gateway_usage_records_quantity_check,
             check: "(unit IS NULL AND quantity IS NULL) OR (#{unit_check} AND quantity >= 0)"
           )
  end
end
