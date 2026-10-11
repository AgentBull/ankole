defmodule Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Providers.Configuration do
  @moduledoc "Validates provider YAML and separates immutable and instance settings."

  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Providers.YAML
  alias ExJsonSchema.Validator
  alias ExJsonSchema.Validator.Error

  @spec parse(map(), String.t()) ::
          {:ok, map()} | {:error, {:invalid_worker_provider_config, [map()]}}
  def parse(schema, text) do
    with {:ok, data, locations} <- YAML.parse(text) do
      settings = defaults(schema, data)

      case Validator.validate(schema, settings, error_formatter: false) do
        :ok -> {:ok, settings}
        {:error, errors} -> {:error, {:invalid_worker_provider_config, errors(errors, locations)}}
      end
    else
      {:error, errors} -> {:error, {:invalid_worker_provider_config, errors}}
    end
  end

  @spec unchanged_location(map(), map(), map()) :: :ok | {:error, term()}
  def unchanged_location(schema, before, after_settings) do
    changed =
      schema["properties"]
      |> Enum.filter(fn {key, definition} ->
        definition["x-category"] == "location" and before[key] != after_settings[key]
      end)
      |> Enum.map(fn {key, _} ->
        %{path: key, line: nil, message: "cannot change after creation"}
      end)

    if changed == [], do: :ok, else: {:error, {:invalid_worker_provider_config, changed}}
  end

  @spec digest(map(), map()) :: String.t()
  def digest(schema, settings) do
    schema
    |> instance_settings(settings)
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "The instance settings selected for one generation, without credentials."
  def instance_settings(schema, settings), do: Map.take(settings, instance_keys(schema))

  @doc "Uses the saved instance settings with the current lifecycle settings."
  def with_instance_settings(schema, settings, saved) do
    settings |> Map.drop(instance_keys(schema)) |> Map.merge(saved)
  end

  @spec duration_ms(String.t()) :: pos_integer() | :never
  def duration_ms("never"), do: :never

  def duration_ms(value) do
    [_, amount, unit] = Regex.run(~r/\A([1-9][0-9]*)(s|m|h|d)\z/, value)

    String.to_integer(amount) *
      Map.fetch!(%{"s" => 1000, "m" => 60_000, "h" => 3_600_000, "d" => 86_400_000}, unit)
  end

  @spec object(map(), [String.t()]) :: map()
  def object(properties, required \\ []) do
    schema = %{"type" => "object", "properties" => properties, "additionalProperties" => false}
    if required == [], do: schema, else: Map.put(schema, "required", required)
  end

  @spec field(map(), :location | :instance | :lifecycle) :: map()
  def field(schema, category), do: Map.put(schema, "x-category", to_string(category))

  @spec common(String.t(), pos_integer()) :: map()
  def common(idle, stop_grace \\ 60) do
    %{
      "endpoints" =>
        field(
          object(%{
            "runtimeFabricUrl" => %{"type" => "string", "pattern" => "^wss?://[^/]+"},
            "relayOrigin" => %{"type" => "string", "pattern" => "^https?://[^/]+"},
            "aiGatewayUrl" => %{"type" => "string", "pattern" => "^https?://[^/]+"}
          }),
          :instance
        ),
      "stopGraceSeconds" =>
        field(%{"type" => "integer", "minimum" => 1, "default" => stop_grace}, :lifecycle),
      "idleReleaseAfter" =>
        field(
          %{"type" => "string", "pattern" => "^(never|[1-9][0-9]*(s|m|h|d))$", "default" => idle},
          :lifecycle
        )
    }
  end

  @spec environment() :: map()
  def environment do
    %{
      "type" => "object",
      "default" => %{},
      "additionalProperties" => %{"type" => "string"},
      "propertyNames" => %{
        "pattern" => "^[A-Za-z_][A-Za-z0-9_]*$",
        "not" => %{
          "enum" => Ankole.SignalsGateway.ActorRuntime.WorkerBootstrap.contract_env_names()
        }
      }
    }
  end

  @doc false
  def defaults(%{"properties" => properties}, data) when is_map(data) do
    Enum.reduce(properties, data, fn {key, schema}, acc ->
      cond do
        Map.has_key?(acc, key) -> Map.update!(acc, key, &defaults(schema, &1))
        Map.has_key?(schema, "default") -> Map.put(acc, key, schema["default"])
        true -> acc
      end
    end)
  end

  def defaults(_schema, data), do: data

  defp instance_keys(schema),
    do: for({key, %{"x-category" => "instance"}} <- schema["properties"], do: key)

  # ExJsonSchema 0.11 validates a then or else branch from "#". `base` is the
  # path of the data that the branch validates.
  defp errors(errors, locations, base \\ "#") do
    Enum.flat_map(errors, fn %Error{error: error, path: path} ->
      path = absolute(base, path)

      case error do
        %Error.AllOf{invalid: invalid} ->
          errors(Enum.flat_map(invalid, & &1.errors), locations, base)

        %Error.PropertyNames{invalid: invalid} ->
          errors(invalid |> Map.values() |> List.flatten(), locations, base)

        %Error.IfThenElse{errors: branch} ->
          errors(branch, locations, path)

        %Error.AnyOf{invalid: branches} ->
          alternatives(branches, path, locations, base)

        %Error.OneOf{invalid: [_ | _] = branches} ->
          alternatives(branches, path, locations, base)

        %Error.Required{missing: keys} ->
          Enum.map(keys, &YAML.error(locations, segments(path) ++ [&1], "is required"))

        error ->
          [YAML.error(locations, segments(path), to_string(error))]
      end
    end)
  end

  # A branch whose type or enum fails at the path of the alternatives has a
  # different form than the value, so its errors do not apply. When each
  # remaining branch misses only one key, one error names all of those keys.
  defp alternatives(branches, path, locations, base) do
    branch_errors = Enum.map(branches, & &1.errors)

    candidates =
      case Enum.reject(branch_errors, &other_form?(&1, path, base)) do
        [] -> branch_errors
        candidates -> candidates
      end

    case candidates do
      [branch] ->
        errors(branch, locations, base)

      _several ->
        keys = Enum.map(candidates, &missing_key(&1, path, base))

        if Enum.all?(keys, &is_binary/1) do
          [YAML.error(locations, segments(path), "requires one of: " <> Enum.join(keys, ", "))]
        else
          errors(Enum.concat(candidates), locations, base)
        end
    end
  end

  defp other_form?(errors, path, base) do
    Enum.any?(errors, fn %Error{error: error, path: at} ->
      (match?(%Error.Type{}, error) or match?(%Error.Enum{}, error)) and
        absolute(base, at) == path
    end)
  end

  # The path of the one missing key, relative to the alternatives.
  defp missing_key([%Error{error: %Error.Required{missing: [key]}, path: at}], path, base) do
    base
    |> absolute(at)
    |> segments()
    |> Enum.drop(length(segments(path)))
    |> Enum.concat([key])
    |> Enum.join(".")
  end

  defp missing_key(_errors, _path, _base), do: nil

  defp absolute(base, path), do: base <> String.trim_leading(path, "#")

  defp segments(path),
    do:
      path
      |> String.trim_leading("#")
      |> String.split("/", trim: true)
      |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))
end
