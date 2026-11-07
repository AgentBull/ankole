defmodule Ankole.Brain.SearchIndexes do
  @moduledoc """
  Brain facade over `Ankole.SearchIndexes`, which maintains the shared BM25 and
  HNSW retrieval indexes across Brain and Pod.
  """

  defdelegate configuration_status(), to: Ankole.SearchIndexes
  defdelegate ensure_current(), to: Ankole.SearchIndexes
end
