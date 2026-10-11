defmodule Ankole.Repo.Migrations.IndexRecoverableOutboxDeadlines do
  use Ecto.Migration

  def change do
    create index(
             :signal_gateway_outbox_entries,
             [:status, :next_attempt_at, :platform_send_started_at],
             name: :outbox_recovery_deadlines_index,
             where: """
             status = 'created'
             OR (status IN ('failed', 'unknown_after_send') AND next_attempt_at IS NOT NULL)
             OR (status = 'sending' AND platform_send_started_at IS NOT NULL)
             """
           )
  end
end
