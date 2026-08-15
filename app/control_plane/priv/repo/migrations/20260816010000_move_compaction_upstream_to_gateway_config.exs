defmodule Ankole.Repo.Migrations.MoveCompactionUpstreamToGatewayConfig do
  use Ecto.Migration

  # Provider-native compaction is an instance decision, not a per-Agent
  # capability: a Provider-owned compaction item binds the rest of that history
  # to the same upstream, and one Ankole instance serves one enterprise. The
  # switch moves back to the `ai_gateway.compaction` settings that already own
  # every other compaction field. A stored Agent row that still carries the
  # retired capability fails validation on read, so it is removed here. An
  # instance that had turned it on for an Agent enables `upstream` once in the
  # gateway compaction settings.
  def up do
    execute("""
    UPDATE agents
    SET options = jsonb_set(
          options,
          '{ai_agent,provider_hosted}',
          (options #> '{ai_agent,provider_hosted}') - 'compaction'
        )
    WHERE jsonb_typeof(options #> '{ai_agent,provider_hosted}') = 'object'
      AND options #> '{ai_agent,provider_hosted}' ? 'compaction'
    """)
  end

  # The capability no longer exists in the schema, so restoring it would write a
  # value the write path rejects.
  def down, do: :ok
end
