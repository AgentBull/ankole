defmodule Ankole.Pod.Chat.Attachment do
  @moduledoc "A conversation attachment available to its participants."
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        path: [type: :string, allow_nil?: false],
        object_id: [type: :uuid, allow_nil?: false],
        node_id: [type: :uuid],
        position: [type: :integer, allow_nil?: false, constraints: [min: 0]],
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
