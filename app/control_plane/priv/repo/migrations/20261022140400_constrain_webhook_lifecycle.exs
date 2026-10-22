defmodule Ankole.Repo.Migrations.ConstrainWebhookLifecycle do
  use Ecto.Migration

  def up do
    create(
      constraint(:signal_webhook_endpoints, :signal_webhook_endpoints_lifecycle_check,
        check: """
        (status = 'fired' AND fired_at IS NOT NULL AND cancelled_at IS NULL)
        OR (status = 'cancelled' AND cancelled_at IS NOT NULL AND fired_at IS NULL)
        OR (status IN ('armed', 'active', 'expired') AND fired_at IS NULL AND cancelled_at IS NULL)
        """
      )
    )
  end

  def down do
    drop(constraint(:signal_webhook_endpoints, :signal_webhook_endpoints_lifecycle_check))
  end
end
