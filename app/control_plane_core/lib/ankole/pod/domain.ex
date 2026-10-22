defmodule Ankole.Pod.Domain do
  @moduledoc false
  use Ankole.Ash.Domain

  resources do
    resource Ankole.Pod.DbTable do
      define(:get_db_table, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_db_tables, action: :read)
      define(:create_db_table, action: :create_in_tx)
      define(:commit_write_db_table, action: :commit_write)
      define(:initialize_copy_db_table, action: :initialize_copy)
      define(:remove_db_table, action: :remove)
    end

    resource Ankole.Pod.DbField do
      define(:get_db_field, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_db_fields, action: :read)
      define(:create_db_field, action: :create_in_tx)
      define(:update_definition_db_field, action: :update_definition)
      define(:remove_db_field, action: :remove)
    end

    resource Ankole.Pod.DbView do
      define(:get_db_view, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_db_views, action: :read)
      define(:create_db_view, action: :create_in_tx)
      define(:update_definition_db_view, action: :update_definition)
      define(:remove_db_view, action: :remove)
    end

    resource Ankole.Pod.DbRecord do
      define(:get_db_record, action: :read, get_by: [:id, :table_id], not_found_error?: false)
      define(:list_db_records, action: :read)
      define(:create_db_record, action: :create_in_tx)
      define(:update_values_db_record, action: :update_values)
      define(:remove_db_record, action: :remove)
    end

    resource Ankole.Pod.Page do
      define(:get_page, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_pages, action: :read)
      define(:create_page, action: :create_in_tx)
      define(:edit_page, action: :edit)
      define(:move_page, action: :move)
      define(:position_page, action: :position)
      define(:sharing_page, action: :sharing)
      define(:trash_page, action: :trash)
      define(:restore_page, action: :restore)
      define(:begin_purge_page, action: :begin_purge)
      define(:advance_revision_page, action: :advance_revision)
      define(:purge_page, action: :purge)
    end

    resource Ankole.Pod.PageContent do
      define(:get_page_content, action: :read, get_by: [:page_id], not_found_error?: false)
      define(:list_page_contents, action: :read)
      define(:create_page_content, action: :create_in_tx)
      define(:replace_page_content, action: :replace)
      define(:purge_page_content, action: :purge)
    end

    resource Ankole.Pod.PageChange do
      define(:get_page_change,
        action: :read,
        get_by: [:page_id, :revision],
        not_found_error?: false
      )

      define(:list_page_changes, action: :read)
      define(:append_page_change, action: :append)
      define(:prune_page_change, action: :prune)
    end

    resource Ankole.Pod.PageUserState do
      define(:get_page_user_state,
        action: :read,
        get_by: [:principal_uid, :page_id],
        not_found_error?: false
      )

      define(:list_page_user_states, action: :read)
      define(:put_page_user_state, action: :put)
      define(:remove_empty_page_user_state, action: :remove_empty)
      define(:purge_page_user_state, action: :purge)
    end
  end
end
