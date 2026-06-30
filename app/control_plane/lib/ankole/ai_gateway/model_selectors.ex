defmodule Ankole.AIGateway.ModelSelectors do
  @moduledoc """
  Maps agent model-profile names to public AIGateway model selectors.

  LLM profiles keep their familiar names such as `primary`, while embedding and
  rerank expose explicit default selectors. This keeps `/models` and request
  resolution readable for API clients without leaking the internal profile row
  names as the only public contract.
  """

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

  @doc """
  Returns the selector that should be shown to callers for a profile.

  Embedding and rerank use capability-specific defaults because the bare word
  `default` is ambiguous once one request can target several model capabilities.
  """
  @spec public_selector(String.t(), String.t()) :: String.t()
  def public_selector(capability, profile) do
    case Map.fetch(@default_bindings, capability) do
      {:ok, %{profile: ^profile, selector: selector}} -> selector
      _binding -> profile
    end
  end

  @doc """
  Resolves a public default selector back to the stored profile name.

  Explicit provider selectors are handled by `Ankole.AIGateway.Resolver`; this
  helper only owns the built-in default aliases.
  """
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
