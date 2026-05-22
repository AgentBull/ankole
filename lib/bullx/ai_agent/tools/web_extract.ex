defmodule BullX.AIAgent.Tools.WebExtract do
  @moduledoc false

  alias BullX.AIAgent.Tools.Context
  alias BullX.AIAgent.Tools.Web

  @spec execute(map(), Context.t()) :: {:ok, map()} | {:error, BullX.AIAgent.Tools.Error.t()}
  def execute(args, %Context{} = context) when is_map(args) do
    urls =
      args
      |> list_arg(:urls)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.take(5)

    Web.extract(%{urls: urls}, context.metadata)
  end

  defp list_arg(args, key) do
    case Map.get(args, key) || Map.get(args, Atom.to_string(key)) do
      values when is_list(values) -> Enum.filter(values, &is_binary/1)
      _value -> []
    end
  end
end
