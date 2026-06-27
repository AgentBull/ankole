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

  @doc """
  Builds the adapter-facing context for one configured signal binding.

  The context carries only binding identity and lightweight helper access. It
  does not expose database handles, so adapters must enter ingress through the
  explicit emit functions below.
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
  Emits a provider entry as actor-visible input for this binding.
  """
  @spec emit_entry(t(), map(), keyword()) :: SignalsGateway.ingress_result()
  def emit_entry(%__MODULE__{} = context, input, options \\ []) do
    SignalsGateway.emit_entry(context.agent_uid, context.binding_name, input, options)
  end

  @doc """
  Emits a provider-entry removal for this binding.

  Provider-specific delete or recall names collapse to the same Ankole lifecycle:
  remove pending work when possible, or append one removed notice if the actor
  already consumed the original entry.
  """
  @spec emit_entry_removed(t(), map(), keyword()) :: SignalsGateway.ingress_result()
  def emit_entry_removed(%__MODULE__{} = context, input, options \\ []) do
    SignalsGateway.emit_entry_removed(context.agent_uid, context.binding_name, input, options)
  end

  @doc """
  Emits a provider reaction event for this binding.
  """
  @spec emit_reaction(t(), map(), keyword()) :: SignalsGateway.ingress_result()
  def emit_reaction(%__MODULE__{} = context, input, options \\ []) do
    SignalsGateway.emit_reaction(context.agent_uid, context.binding_name, input, options)
  end

  @doc """
  Emits a provider action event for this binding.

  Actions represent explicit UI or command callbacks that should enter the same
  ordered actor-input journal as messages.
  """
  @spec emit_action(t(), map(), keyword()) :: SignalsGateway.ingress_result()
  def emit_action(%__MODULE__{} = context, input, options \\ []) do
    SignalsGateway.emit_action(context.agent_uid, context.binding_name, input, options)
  end

  @doc """
  Returns the logger module available to adapters.

  The prefix argument is accepted for adapter ergonomics but currently does not
  create a separate logger namespace.
  """
  @spec get_logger(t(), String.t() | nil) :: module()
  def get_logger(%__MODULE__{}, _prefix \\ nil), do: Logger

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
