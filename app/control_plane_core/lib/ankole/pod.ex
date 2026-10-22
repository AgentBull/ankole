defmodule Ankole.Pod do
  @moduledoc """
  The Pod domain: the page tree, page content, and Database schemas.

  The Ash resources own the pages, page content and changes, personal page
  state, and Database tables, fields, and views. Their generic actions own the
  transactions of the Pod operations; `Ankole.Pod.Pages`, `Ankole.Pod.Documents`,
  `Ankole.Pod.Files`, `Ankole.Pod.Applets`, and `Ankole.Pod.Database` run them.
  The Pod Database subsystem owns the `db_records` rows through the
  `Ankole.Pod.DbRecord` Ecto schema, because users define their fields at
  runtime.
  """
  use Ankole.Ash.Domain

  resources do
    resource(Ankole.Pod.Page)
    resource(Ankole.Pod.PageContent)
    resource(Ankole.Pod.PageChange)
    resource(Ankole.Pod.PageUserState)

    resource Ankole.Pod.DbTable do
      define(:get_db_table, action: :read, get_by: [:id], not_found_error?: false)
    end

    resource(Ankole.Pod.DbField)
    resource(Ankole.Pod.DbView)
  end
end
