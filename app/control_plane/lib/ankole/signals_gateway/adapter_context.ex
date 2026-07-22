defmodule Ankole.SignalsGateway.AdapterContext do
  @moduledoc """
  Binding runtime context and helper access handed to a signal adapter.
  """

  alias Ankole.Principals

  @enforce_keys [:agent_uid, :binding_name, :adapter, :user_name]
  defstruct [:agent_uid, :binding_name, :adapter, :user_name]

  @type t :: %__MODULE__{
          agent_uid: String.t(),
          binding_name: String.t(),
          adapter: String.t(),
          user_name: String.t()
        }

  @doc """
  Builds the adapter-facing context for one configured signal binding.

  The context carries only binding identity and lightweight helper access.
  Adapters submit normalized provider facts through
  `Ankole.SignalsGateway.Ingress`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    %__MODULE__{
      agent_uid: fetch!(attrs, :agent_uid),
      binding_name: fetch!(attrs, :binding_name),
      adapter: fetch!(attrs, :adapter),
      # user_name is the human-facing display label; default it to the adapter id
      # so an adapter that doesn't supply one still has something to show.
      user_name: fetch(attrs, :user_name) || fetch!(attrs, :adapter)
    }
  end

  @doc """
  Returns the display name associated with this adapter context.
  """
  @spec get_user_name(t()) :: String.t()
  def get_user_name(%__MODULE__{user_name: user_name}), do: user_name

  @doc """
  Observes a provider-side subject and links it to a human principal.

  The binding name becomes the default provider so adapters do not have to repeat
  it for every subject observation.
  """
  @spec observe_platform_subject(t(), map()) :: {:ok, map()} | {:error, term()}
  def observe_platform_subject(%__MODULE__{} = context, attrs) when is_map(attrs) do
    attrs
    |> put_default(:provider, context.binding_name)
    |> Principals.upsert_platform_subject_human()
  end

  defp put_default(attrs, key, value) do
    Map.put_new(attrs, key, value)
  end

  defp fetch(attrs, key) do
    if Keyword.keyword?(attrs), do: Keyword.get(attrs, key), else: Map.get(attrs, key)
  end

  defp fetch!(attrs, key) do
    if Keyword.keyword?(attrs), do: Keyword.fetch!(attrs, key), else: Map.fetch!(attrs, key)
  end
end
