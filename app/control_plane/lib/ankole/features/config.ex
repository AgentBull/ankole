defmodule Ankole.Features.Config do
  @moduledoc false

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Schema

  def flags, do: Application.get_env(:ankole, :feature_flags, [])

  def definitions, do: Enum.map(flags(), fn {key, opts} -> definition(key, opts) end)

  defp definition(key, opts) do
    AppConfigure.define(
      key: "features." <> key,
      scope: :global,
      encrypted: false,
      schema: Schema.new(&validate/1),
      default_value: %{
        "enabled" => Keyword.get(opts, :default, false),
        "percent" => 100,
        "targets" => %{}
      },
      description: "Availability policy for " <> key <> "."
    )
  end

  defp validate(%{"enabled" => enabled, "percent" => percent, "targets" => targets} = value)
       when is_boolean(enabled) and is_integer(percent) and percent in 0..100 and is_map(targets) do
    if map_size(value) == 3 and
         Enum.all?(targets, fn {key, value} -> is_binary(key) and is_boolean(value) end),
       do: {:ok, value},
       else: {:error, :invalid_feature_policy}
  end

  defp validate(_value), do: {:error, :invalid_feature_policy}
end
