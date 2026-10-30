defmodule Ankole.Repo.Migrations.AddPageChildrenView do
  use Ecto.Migration

  def up do
    alter table(:pages) do
      add :children_view, :map, null: false, default: %{}
    end

    create constraint(:pages, :pages_children_view_object,
             check: "jsonb_typeof(children_view) = 'object'"
           )
  end

  def down do
    drop constraint(:pages, :pages_children_view_object)

    alter table(:pages) do
      remove :children_view
    end
  end
end
