defmodule Ankole.Files.Domain do
  @moduledoc false
  use Ankole.Ash.Domain

  resources do
    resource Ankole.Files.Schemas.Blob do
      define(:get_blob, action: :read, get_by: [:sha256], not_found_error?: false)
      define(:list_blobs, action: :read)
      define(:store_blob, action: :store)
      define(:reference_blob, action: :reference)
      define(:mark_for_collection_blob, action: :mark_for_collection)
      define(:keep_referenced_blob, action: :keep_referenced)
      define(:collect_blob, action: :collect)
    end

    resource Ankole.Files.Schemas.DriveFile do
      define(:get_drive_file, action: :read, get_by: [], not_found_error?: false)
      define(:list_drive_files, action: :read)
      define(:commit_drive_file, action: :commit)
      define(:move_drive_file, action: :move)
    end
  end
end
