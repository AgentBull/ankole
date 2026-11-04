defmodule Ankole.Repo.Migrations.RetireWorkerAuthKey do
  use Ecto.Migration

  # AppConfigure rejects undeclared keys, and Ankole does not declare this generated key.
  def up,
    do:
      execute("DELETE FROM site_app_configurations WHERE key = 'runtime_fabric.worker_auth_key'")

  def down, do: :ok
end
