defmodule Ankole.Repo.Migrations.RetireDailySessionResets do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE oban_jobs SET state = 'cancelled', cancelled_at = now()
    WHERE worker = 'Ankole.Sessions.Jobs.EnqueueDailySessionResets'
      AND state IN ('available', 'scheduled', 'retryable', 'executing')
    """)
  end

  def down, do: :ok
end
