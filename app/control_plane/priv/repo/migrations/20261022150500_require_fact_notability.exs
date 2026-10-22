defmodule Ankole.Repo.Migrations.RequireFactNotability do
  use Ecto.Migration

  def up, do: replace_shape(true)

  def down, do: replace_shape(false)

  defp replace_shape(required?) do
    notability = if required?, do: "notability IS NOT NULL AND", else: ""

    execute("ALTER TABLE brain_claims DROP CONSTRAINT brain_claims_type_shape")

    execute("""
    ALTER TABLE brain_claims ADD CONSTRAINT brain_claims_type_shape CHECK (
      (claim_type = 'fact'
        AND kind IN ('event', 'preference', 'commitment', 'belief', 'fact')
        AND #{notability} notability IN ('high', 'medium', 'low')
        AND valid_from IS NOT NULL
        AND confidence IS NOT NULL AND confidence >= 0 AND confidence <= 1
        AND num_nonnulls(weight, since_date, until_date, active, graded_quality,
          graded_confidence, graded_at, resolved_at, resolved_outcome, resolved_quality,
          resolved_value, resolved_unit, resolution_provenance, resolved_by) = 0)
      OR
      (claim_type = 'take'
        AND weight IS NOT NULL AND weight >= 0 AND weight <= 1
        AND active IS NOT NULL
        AND num_nonnulls(notability, context, valid_from, valid_until, expired_at,
          consolidated_at, consolidated_into, confidence) = 0)
    )
    """)
  end
end
