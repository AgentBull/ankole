defmodule Ankole.Files.Config do
  @moduledoc "Declared Drive lifecycle policy."
  alias Ankole.AppConfigure.{Definition, Schema}

  def definitions do
    [
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

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp non_negative_integer(_), do: {:error, :invalid_non_negative_integer}
end
