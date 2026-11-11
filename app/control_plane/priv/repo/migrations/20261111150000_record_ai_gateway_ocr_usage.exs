defmodule Ankole.Repo.Migrations.RecordAIGatewayOCRUsage do
  use Ecto.Migration

  # A usage row can name a call of an OCR model, which counts the pages that
  # the Provider processed.
  #
  # Replacing a check takes an exclusive lock on the table, and PostgreSQL
  # reads every row under that lock to validate the new check. Gateway calls
  # that write the usage ledger and quota checks that read it wait until the
  # migration commits, for a time that grows with the number of rows.
  #
  # Rolling back fails once an OCR row exists, because the narrower checks reject
  # it. Delete those rows first.
  def up do
    replace_checks(
      "capability IN ('llm', 'image_generate', 'decision', 'speech', 'transcription', 'ocr')",
      "unit IN ('image', 'character', 'second', 'page')"
    )
  end

  def down do
    replace_checks(
      "capability IN ('llm', 'image_generate', 'decision', 'speech', 'transcription')",
      "unit IN ('image', 'character', 'second')"
    )
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
