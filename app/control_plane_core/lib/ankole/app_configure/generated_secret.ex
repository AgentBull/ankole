defmodule Ankole.AppConfigure.GeneratedSecret do
  @moduledoc """
  Generated secret helper for AppConfigure definitions.
  """

  alias Ankole.Kernel, as: NativeKernel

  @doc """
  Generates a random secret using the shared native kernel.
  """
  @spec generate(keyword()) :: String.t()
  def generate(_opts \\ []) do
    NativeKernel.generate_key()
  end

  @doc """
  Returns a zero-arity generator suitable for an AppConfigure definition.

  Reads never persist generated secrets. The function is wrapped so setup code
  can explicitly call and store the generated value when it owns that decision.
  """
  @spec generator(keyword()) :: (-> String.t())
  def generator(opts \\ []) do
    fn -> generate(opts) end
  end
end
