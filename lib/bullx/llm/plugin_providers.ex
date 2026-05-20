defmodule BullX.LLM.PluginProviders do
  @moduledoc """
  Registers BullX-owned and plugin-owned `req_llm` providers.

  The `req_llm` provider registry is process-local runtime state. BullX applies
  its own provider overrides first, then enabled plugin declarations, so the
  registry can be rebuilt on application restart.
  """

  alias BullX.Plugins.Extension

  @extension_point :"bullx.llm.req_llm_provider"

  @builtin_extensions [
    %Extension{
      plugin_id: "bullx",
      point: @extension_point,
      id: "amazon_bedrock",
      module: BullX.LLM.Providers.AmazonBedrock,
      opts: [override: true]
    },
    %Extension{
      plugin_id: "bullx",
      point: @extension_point,
      id: "anthropic",
      module: BullX.LLM.Providers.Anthropic,
      opts: [override: true]
    },
    %Extension{
      plugin_id: "bullx",
      point: @extension_point,
      id: "azure",
      module: BullX.LLM.Providers.Azure,
      opts: [override: true]
    },
    %Extension{
      plugin_id: "bullx",
      point: @extension_point,
      id: "deepseek",
      module: BullX.LLM.Providers.Deepseek,
      opts: [override: true]
    },
    %Extension{
      plugin_id: "bullx",
      point: @extension_point,
      id: "google",
      module: BullX.LLM.Providers.Google,
      opts: [override: true]
    },
    %Extension{
      plugin_id: "bullx",
      point: @extension_point,
      id: "google_vertex",
      module: BullX.LLM.Providers.GoogleVertex,
      opts: [override: true]
    },
    %Extension{
      plugin_id: "bullx",
      point: @extension_point,
      id: "mistral",
      module: BullX.LLM.Providers.Mistral,
      opts: [override: true]
    },
    %Extension{
      plugin_id: "bullx",
      point: @extension_point,
      id: "openai",
      module: BullX.LLM.Providers.OpenAI,
      opts: [override: true]
    },
    %Extension{
      plugin_id: "bullx",
      point: @extension_point,
      id: "openrouter",
      module: BullX.LLM.Providers.OpenRouter,
      opts: [override: true]
    },
    %Extension{
      plugin_id: "bullx",
      point: @extension_point,
      id: "vllm",
      module: BullX.LLM.Providers.VLLM,
      opts: [override: true]
    },
    %Extension{
      plugin_id: "bullx",
      point: @extension_point,
      id: "xai",
      module: BullX.LLM.Providers.XAI,
      opts: [override: true]
    },
    %Extension{
      plugin_id: "bullx",
      point: @extension_point,
      id: "zai",
      module: BullX.LLM.Providers.Zai,
      opts: [override: true]
    }
  ]

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  def start_link(_opts) do
    case sync() do
      :ok -> :ignore
      {:error, reason} -> {:error, reason}
    end
  end

  @spec sync() :: :ok | {:error, term()}
  def sync do
    with :ok <- sync_builtin_extensions() do
      @extension_point
      |> BullX.Plugins.Registry.enabled_extensions_for()
      |> sync_extensions()
    end
  end

  @spec sync_builtin_extensions() :: :ok | {:error, term()}
  def sync_builtin_extensions, do: sync_extensions(@builtin_extensions)

  @spec available_extensions(GenServer.server()) :: [BullX.Plugins.Extension.t()]
  def available_extensions(server \\ BullX.Plugins.Registry) do
    @builtin_extensions ++ enabled_provider_extensions(server)
  end

  @spec available_provider_ids(GenServer.server()) :: [String.t()]
  def available_provider_ids(server \\ BullX.Plugins.Registry) do
    server
    |> available_extensions()
    |> Enum.map(&extension_id_string/1)
    |> Enum.uniq()
  end

  @spec sync_extensions([BullX.Plugins.Extension.t()]) :: :ok | {:error, term()}
  def sync_extensions(extensions) when is_list(extensions) do
    Enum.reduce_while(extensions, :ok, fn extension, :ok ->
      case register_extension(extension) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp register_extension(extension) do
    with {:ok, expected_id} <- extension_id(extension.id),
         {:ok, provider_id} <- provider_id(extension.module),
         :ok <- validate_matching_id(expected_id, provider_id),
         :ok <- validate_override(provider_id, extension.opts),
         {:ok, ^provider_id} <- ReqLLM.Providers.register(extension.module) do
      :ok
    else
      {:ok, other_provider_id} ->
        {:error, {:req_llm_provider_id_mismatch, extension.id, other_provider_id}}

      {:error, %_{} = error} ->
        {:error, {:req_llm_provider_registration_failed, extension.id, error}}

      {:error, _reason} = error ->
        error
    end
  end

  defp extension_id(id) when is_binary(id), do: {:ok, id}
  defp extension_id(id) when is_atom(id), do: {:ok, Atom.to_string(id)}
  defp extension_id(id), do: {:error, {:invalid_req_llm_provider_extension_id, id}}

  defp provider_id(module) when is_atom(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- implements_provider?(module),
         true <- function_exported?(module, :provider_id, 0),
         provider_id when is_atom(provider_id) <- module.provider_id() do
      {:ok, provider_id}
    else
      false -> {:error, {:invalid_req_llm_provider_module, module}}
      _other -> {:error, {:invalid_req_llm_provider_module, module}}
    end
  end

  defp validate_matching_id(expected_id, provider_id) do
    actual_id = Atom.to_string(provider_id)

    case actual_id == expected_id do
      true -> :ok
      false -> {:error, {:req_llm_provider_id_mismatch, expected_id, actual_id}}
    end
  end

  defp validate_override(provider_id, opts) do
    case {provider_id in ReqLLM.Providers.list(), override?(opts)} do
      {true, true} ->
        :ok

      {true, false} ->
        {:error, {:req_llm_provider_already_registered, Atom.to_string(provider_id)}}

      {false, _override?} ->
        :ok
    end
  end

  defp override?(opts) when is_list(opts), do: Keyword.get(opts, :override) == true
  defp override?(%{override: true}), do: true
  defp override?(%{"override" => true}), do: true
  defp override?(_opts), do: false

  defp enabled_provider_extensions(server) do
    BullX.Plugins.Registry.enabled_extensions_for(@extension_point, server)
  catch
    :exit, _reason -> []
  end

  defp extension_id_string(%Extension{id: id}) when is_binary(id), do: id
  defp extension_id_string(%Extension{id: id}) when is_atom(id), do: Atom.to_string(id)

  defp implements_provider?(module) do
    behaviours = module.__info__(:attributes)[:behaviour] || []
    ReqLLM.Provider in behaviours
  end
end
