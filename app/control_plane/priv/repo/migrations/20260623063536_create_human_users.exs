defmodule Ankole.Repo.Migrations.CreateHumanUsers do
  use Ecto.Migration

  def change do
    create table(:human_users, primary_key: false) do
      add :principal_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          primary_key: true

      add :email, :text
      add :mobile, :text
      add :job_title, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:human_users, [:email],
             name: :human_users_email_index,
             where: "email IS NOT NULL"
           )

    create unique_index(:human_users, [:mobile],
             name: :human_users_mobile_index,
             where: "mobile IS NOT NULL"
           )
  end
end
