defmodule Ankole.Files.Config do
  @moduledoc "Declared Drive lifecycle policy."
  alias Ankole.AppConfigure.{Definition, Schema}

  def definitions do
    [
      Definition.new!(
        key: "drive.vfs_max_upload_bytes",
        scope: :global,
        encrypted: false,
        schema: Schema.new(&non_negative_integer/1),
        default_value: 0,
        description: "Maximum bytes per Drive VFS upload; 0 uses the object store limit."
      ),
      Definition.new!(
        key: "drive.trash_retention_days",
        scope: :tenant,
        encrypted: false,
        schema: Schema.new(&non_negative_integer/1),
        default_value: 30,
        description:
          "Days to retain deleted Drive nodes before automatic purge; 0 keeps them until this changes."
      )
    ]
  end

  def trash_retention_days,
    do: Ankole.AppConfigure.get_by_key("drive.trash_retention_days")

  def vfs_upload_limit do
    with {:ok, store} <- Ankole.Files.upload_limit(),
         {:ok, site} <- Ankole.AppConfigure.get_by_key("drive.vfs_max_upload_bytes"),
         do: {:ok, if(site > 0, do: min(store, site), else: store)}
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp non_negative_integer(_), do: {:error, :invalid_non_negative_integer}
end
