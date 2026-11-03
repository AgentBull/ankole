defmodule Ankole.Repo.Migrations.IndexSignalBindingSources do
  use Ecto.Migration

  def change do
    create index(:signal_bindings, [:tenant_id, :config_ref, :id],
             name: :signal_bindings_source_index
           )
  end
end
