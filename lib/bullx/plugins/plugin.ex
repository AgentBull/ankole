defmodule BullX.Plugins.Plugin do
  @moduledoc """
  Behaviour for trusted BullX plugin entry modules.

  Plugin modules are declarative. They describe metadata, config modules,
  extension declarations, and optional children. The host performs registration
  and supervision.

  Metadata always includes `:id` and `:api_version`. Plugins may also declare
  UI-facing `:display_name` and `:description` values as plain strings or
  locale-keyed string maps.
  """

  @type localized_text :: String.t() | %{String.t() => String.t()}
  @type metadata :: %{
          required(:id) => String.t(),
          required(:api_version) => pos_integer(),
          optional(:display_name) => localized_text(),
          optional(:description) => localized_text()
        }

  @callback __bullx_plugin__() :: metadata() | keyword()
  @callback extensions() :: list(map() | keyword() | BullX.Plugins.Extension.t())
  @callback config_modules() :: [module()]
  @callback children(map()) :: [Supervisor.child_spec() | module() | {module(), term()}]

  @optional_callbacks extensions: 0, config_modules: 0, children: 1

  defmacro __using__(opts \\ []) do
    app = plugin_app(opts, __CALLER__)
    id = opts |> Keyword.get(:id, Atom.to_string(app)) |> validate_id!()
    api_version = Keyword.get(opts, :api_version, 1)

    metadata =
      opts
      |> Keyword.drop([:app])
      |> Map.new(fn {key, value} -> {key, expand_metadata_value!(value, __CALLER__)} end)
      |> Map.merge(%{id: id, api_version: api_version})

    escaped_metadata = Macro.escape(metadata)

    quote do
      @behaviour BullX.Plugins.Plugin

      @impl BullX.Plugins.Plugin
      def __bullx_plugin__, do: unquote(escaped_metadata)

      @impl BullX.Plugins.Plugin
      def extensions, do: []

      @impl BullX.Plugins.Plugin
      def config_modules, do: []

      @impl BullX.Plugins.Plugin
      def children(_context), do: []

      defoverridable __bullx_plugin__: 0, extensions: 0, config_modules: 0, children: 1
    end
  end

  defp plugin_app(opts, caller) do
    case Keyword.fetch(opts, :app) do
      {:ok, app} when is_atom(app) -> app
      {:ok, app} -> raise ArgumentError, "plugin :app must be an atom, got: #{inspect(app)}"
      :error -> plugin_app_from_file(caller.file) || mix_project_app()
    end
  end

  defp plugin_app_from_file(file) when is_binary(file) do
    file
    |> Path.expand()
    |> Path.split()
    |> plugin_app_from_path()
  end

  defp plugin_app_from_path(parts) do
    case Enum.drop_while(parts, &(&1 != "plugins")) do
      ["plugins", plugin | _rest] -> String.to_atom(plugin)
      _other -> nil
    end
  end

  defp mix_project_app do
    case Code.ensure_loaded?(Mix.Project) do
      true -> Mix.Project.config() |> Keyword.fetch!(:app)
      false -> raise ArgumentError, "plugin :app is required when Mix.Project is unavailable"
    end
  end

  defp validate_id!(id) when is_binary(id), do: id

  defp validate_id!(id),
    do: raise(ArgumentError, "plugin :id must be a string, got: #{inspect(id)}")

  defp expand_metadata_value!(value, caller) when is_tuple(value) or is_list(value) do
    {expanded, _binding} = Code.eval_quoted(value, [], caller)
    expanded
  end

  defp expand_metadata_value!(value, _caller), do: value
end
