defmodule Ankole.Brain.CurationGuide do
  @moduledoc "Reads the one human-maintained public Brain curation policy as semantic text."

  alias Ankole.Brain.Knowledge
  alias Ankole.Brain.Scope

  @entry_type "brain_curation_guide"

  @spec load(String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def load(owner_uid) when is_binary(owner_uid) do
    with {:ok, scope} <- Scope.for_store(owner_uid, "public"),
         {:ok, entries} <-
           Knowledge.list_entries(scope, type: @entry_type, store_key: "public", limit: 1) do
      case entries do
        [entry] -> open_body(scope, entry.id)
        [] -> {:ok, nil}
      end
    end
  end

  def load(_owner_uid), do: {:error, :invalid_owner_uid}

  defp open_body(scope, entry_id) do
    with {:ok, %{blocks: blocks}} <- Knowledge.open(scope, entry_id, block_limit: :all) do
      body =
        blocks
        |> Enum.map(&String.trim(&1.body))
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n\n")

      if body == "", do: {:ok, nil}, else: {:ok, body}
    end
  end
end
