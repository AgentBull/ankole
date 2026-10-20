defmodule Ankole.AIGateway.Artifacts.ReferenceBudget do
  @moduledoc false

  @limit 100 * 1024 * 1024

  @spec consume(non_neg_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, :request_too_large}
  def consume(current, added)
      when is_integer(current) and current >= 0 and is_integer(added) and added >= 0 do
    total = current + added
    if total <= @limit, do: {:ok, total}, else: {:error, :request_too_large}
  end
end
