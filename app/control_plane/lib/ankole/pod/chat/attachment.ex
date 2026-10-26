defmodule Ankole.Pod.Chat.Attachment do
  @moduledoc "A conversation attachment available to its participants."
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        path: [type: :string, allow_nil?: false],
        blob_ref: [type: :string, allow_nil?: false],
        name: [type: :string, allow_nil?: false],
        size: [type: :integer, allow_nil?: false],
        mime_type: [type: :string],
        content_type: [type: :string],
        attachment_id: [type: :integer],
        upload_id: [type: :string],
        resource_type: [type: :string]
      ]
    ]
end
