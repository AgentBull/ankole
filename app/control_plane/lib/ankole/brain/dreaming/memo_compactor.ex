defmodule Ankole.Brain.Dreaming.MemoCompactor do
  @moduledoc "Keeps the Agent's resident long-term memory memo within its token budget."

  alias Ankole.AIGateway
  alias Ankole.Brain.Citations
  alias Ankole.Brain.Config
  alias Ankole.Brain.Knowledge
  alias Ankole.Brain.Scope

  @memo_type "agent_system_pinned_memo"

  @spec run(String.t(), keyword()) ::
          {:ok, :missing | :within_budget | :compacted} | {:error, term()}
  def run(owner_uid, opts \\ []) when is_binary(owner_uid) do
    with {:ok, %{"pinned_memo_max_tokens" => budget}} <- Config.knowledge(),
         {:ok, scope} <- Scope.for_store(owner_uid, "self"),
         {:ok, entries} <-
           Knowledge.list_entries(scope, type: @memo_type, store_key: "self", limit: 1) do
      case entries do
        [] ->
          {:ok, :missing}

        [entry] ->
          compact_entry(scope, entry.id, owner_uid, budget, opts)
      end
    end
  end

  defp compact_entry(scope, entry_id, owner_uid, budget, opts) do
    with {:ok, projection} <- Knowledge.open(scope, entry_id, block_limit: :all) do
      text = resident_text(projection.blocks)

      if token_count(text) <= budget do
        {:ok, :within_budget}
      else
        with {:ok, compacted} <- request_compaction(owner_uid, text, budget, opts),
             :ok <- validate_compacted(compacted, budget),
             {:ok, _result} <- replace_blocks(scope, projection.blocks, compacted, owner_uid),
             {:ok, verified} <- Knowledge.open(scope, entry_id, block_limit: :all),
             :ok <- validate_compacted(resident_text(verified.blocks), budget) do
          {:ok, :compacted}
        end
      end
    end
  end

  defp request_compaction(owner_uid, text, budget, opts) do
    request = %{
      "model" => "light",
      "store" => false,
      "max_output_tokens" => budget,
      "input" => [
        %{
          "role" => "system",
          "content" => [
            %{
              "type" => "input_text",
              "text" =>
                "You compress the resident memo of the long-term memory system (codename Brain). It preserves chat messages, curated current knowledge entries, and external materials that people ask it to learn so future work can retrieve the few most relevant items. Preserve each actionable rule's subject or scope, trigger, required behavior, and failure behavior. Merge duplicates and remove history, database identifiers, timestamps, headings without rules, and prose that cannot change behavior. Return only the replacement memo text. The result must fit within #{budget} o200k-base tokens."
            }
          ]
        },
        %{
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => text}]
        }
      ]
    }

    with {:ok, %{body: body}} <-
           AIGateway.create_response(owner_uid, request, Keyword.get(opts, :request_opts, [])),
         {:ok, text} <- response_text(body) do
      {:ok, String.trim(text)}
    end
  end

  defp replace_blocks(_scope, [], _compacted, _owner_uid), do: {:error, :memo_has_no_body}

  defp replace_blocks(scope, [first | rest], compacted, owner_uid) do
    operations =
      [
        %{
          "operation" => "edit_block",
          "entry_id" => first.entry_id,
          "block_id" => first.id,
          "body" => compacted,
          "expected_block_lock_version" => first.lock_version
        }
      ] ++
        Enum.map(rest, fn block ->
          %{
            "operation" => "delete_block",
            "entry_id" => block.entry_id,
            "block_id" => block.id,
            "expected_block_lock_version" => block.lock_version
          }
        end)

    Knowledge.apply_operations(
      scope,
      operations,
      %{kind: :dreaming, uid: owner_uid},
      metadata: %{"surface" => "memo_compaction"}
    )
  end

  defp validate_compacted(text, budget) do
    cond do
      String.trim(text) == "" -> {:error, :empty_memo_compaction}
      token_count(text) > budget -> {:error, :memo_compaction_over_budget}
      true -> :ok
    end
  end

  defp resident_text(blocks) do
    blocks
    |> Enum.map(&Citations.remove_markers(&1.body))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp token_count(text), do: Ankole.Kernel.estimate_o200k_base_tokens(text)

  defp response_text(%{"output_text" => text}) when is_binary(text), do: {:ok, text}

  defp response_text(%{"output" => output}) when is_list(output) do
    text =
      output
      |> Enum.flat_map(fn
        %{"content" => content} when is_list(content) -> content
        _item -> []
      end)
      |> Enum.flat_map(fn
        %{"text" => text} when is_binary(text) -> [text]
        _part -> []
      end)
      |> Enum.join("\n")
      |> String.trim()

    if text == "", do: {:error, :missing_memo_compaction_text}, else: {:ok, text}
  end

  defp response_text(_body), do: {:error, :missing_memo_compaction_text}
end
