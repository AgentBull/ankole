defmodule Ankole.Repo.Migrations.AddClaimGradedInputHash do
  use Ecto.Migration

  def change do
    alter table(:brain_claims) do
      add :graded_input_hash, :text
    end

    create constraint(:brain_claims, :brain_claims_graded_input_shape,
             check: """
             graded_input_hash IS NULL OR (
               claim_type = 'take' AND graded_at IS NOT NULL AND
               graded_quality IS NOT NULL AND graded_confidence IS NOT NULL AND
               graded_input_hash ~ '^[0-9a-f]{32}$'
             )
             """
           )
  end
end
