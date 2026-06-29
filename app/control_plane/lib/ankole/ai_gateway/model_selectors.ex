defmodule Ankole.AIGateway.ModelSelectors do
  @moduledoc false

  @default_bindings %{
    "embedding" => %{
      profile: "embedding",
      selector: "embedding.default"
    },
    "rerank" => %{
      profile: "rerank",
      selector: "rerank.default"
    }
  }

  @spec public_selector(String.t(), String.t()) :: String.t()
  def public_selector(capability, profile) do
    case Map.fetch(@default_bindings, capability) do
      {:ok, %{profile: ^profile, selector: selector}} -> selector
      _binding -> profile
    end
  end

  @spec default_profile(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, {:unknown_model_selector, String.t(), String.t()}}
  def default_profile(capability, "default") do
    case Map.fetch(@default_bindings, capability) do
      {:ok, %{profile: profile}} -> {:ok, profile}
      :error -> {:error, {:unknown_model_selector, capability, "default"}}
    end
  end

  def default_profile(capability, selector) do
    case Map.fetch(@default_bindings, capability) do
      {:ok, %{profile: profile, selector: ^selector}} ->
        {:ok, profile}

      _binding ->
        {:error, {:unknown_model_selector, capability, selector}}
    end
  end
end
