defmodule Ankole.SignalsGateway.AdapterContext do
  @moduledoc """
  Concrete ingress API handed to a signal adapter for one binding.
  """

  alias Ankole.Principals
  alias Ankole.SignalsGateway

  @enforce_keys [:agent_uid, :binding_name, :adapter, :user_name]
  defstruct [:agent_uid, :binding_name, :adapter, :user_name]

  @type t :: %__MODULE__{
          agent_uid: String.t(),
          binding_name: String.t(),
          adapter: String.t(),
          user_name: String.t()
        }

  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    %__MODULE__{
      agent_uid: fetch!(attrs, :agent_uid),
      binding_name: fetch!(attrs, :binding_name),
      adapter: fetch!(attrs, :adapter),
      user_name: fetch(attrs, :user_name) || fetch!(attrs, :adapter)
    }
  end

  @spec emit_entry(t(), map(), keyword()) :: SignalsGateway.ingress_result()
  def emit_entry(%__MODULE__{} = context, input, options \\ []) do
    SignalsGateway.emit_entry(context.agent_uid, context.binding_name, input, options)
  end

  @spec emit_entry_deleted(t(), map(), keyword()) :: SignalsGateway.ingress_result()
  def emit_entry_deleted(%__MODULE__{} = context, input, options \\ []) do
    SignalsGateway.emit_entry_deleted(context.agent_uid, context.binding_name, input, options)
  end

  @spec emit_entry_recalled(t(), map(), keyword()) :: SignalsGateway.ingress_result()
  def emit_entry_recalled(%__MODULE__{} = context, input, options \\ []) do
    SignalsGateway.emit_entry_recalled(context.agent_uid, context.binding_name, input, options)
  end

  @spec emit_reaction(t(), map(), keyword()) :: SignalsGateway.ingress_result()
  def emit_reaction(%__MODULE__{} = context, input, options \\ []) do
    SignalsGateway.emit_reaction(context.agent_uid, context.binding_name, input, options)
  end

  @spec emit_action(t(), map(), keyword()) :: SignalsGateway.ingress_result()
  def emit_action(%__MODULE__{} = context, input, options \\ []) do
    SignalsGateway.emit_action(context.agent_uid, context.binding_name, input, options)
  end

  @spec get_logger(t(), String.t() | nil) :: module()
  def get_logger(%__MODULE__{}, _prefix \\ nil), do: Logger

  @spec get_user_name(t()) :: String.t()
  def get_user_name(%__MODULE__{user_name: user_name}), do: user_name

  @spec observe_platform_subject(t(), map()) :: {:ok, map()} | {:error, term()}
  def observe_platform_subject(%__MODULE__{} = context, attrs) when is_map(attrs) do
    attrs
    |> put_default(:provider, context.binding_name)
    |> Principals.upsert_platform_subject_human()
  end

  defp put_default(attrs, key, value) do
    cond do
      Map.has_key?(attrs, key) -> attrs
      Map.has_key?(attrs, Atom.to_string(key)) -> attrs
      true -> Map.put(attrs, key, value)
    end
  end

  defp fetch(attrs, key) do
    cond do
      Keyword.keyword?(attrs) -> Keyword.get(attrs, key)
      Map.has_key?(attrs, key) -> Map.fetch!(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.fetch!(attrs, Atom.to_string(key))
      true -> nil
    end
  end

  defp fetch!(attrs, key) do
    cond do
      Keyword.keyword?(attrs) -> Keyword.fetch!(attrs, key)
      Map.has_key?(attrs, key) -> Map.fetch!(attrs, key)
      true -> Map.fetch!(attrs, Atom.to_string(key))
    end
  end
end
