defmodule Ankole.Conversations.AdapterContext do
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
  `Ankole.Conversations.Observe`.
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

  @doc "Runs all chat consumers in order and collects their results."
  @spec dispatch_chat([map()], (map() -> term())) :: {:ok, [term()]} | {:error, term()}
  def dispatch_chat(consumers, fun) do
    consumers
    |> Enum.filter(&match?(%{kind: :chat}, &1))
    |> Enum.map(fun)
    |> Ankole.Attrs.collect_results()
  end

  @doc "Observes a platform subject and returns its human Principal UID."
  @spec observe_platform_subject_uid(t(), map()) :: {:ok, String.t()} | {:error, term()}
  def observe_platform_subject_uid(context, attrs) do
    case observe_platform_subject(context, attrs) do
      {:ok, %{principal: principal}} -> {:ok, principal.uid}
      {:error, _reason} = error -> error
    end
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
