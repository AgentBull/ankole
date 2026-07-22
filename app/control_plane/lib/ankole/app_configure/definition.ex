defmodule Ankole.AppConfigure.Definition do
  @moduledoc """
  Declares one exact AppConfigure key.
  """

  alias Ankole.AppConfigure.Schema

  @enforce_keys [:key, :schema, :encrypted]
  defstruct [
    :key,
    :schema,
    :default_value,
    :description,
    :generator,
    :scope,
    :encrypted,
    :worker_env_name,
    console_writable: true,
    default?: false
  ]

  @type t :: %__MODULE__{
          key: String.t(),
          schema: Schema.t() | Schema.validator(),
          encrypted: boolean(),
          default?: boolean(),
          default_value: term(),
          description: String.t() | nil,
          generator: (-> term()) | nil,
          scope: :scoped | :global,
          console_writable: boolean(),
          worker_env_name: String.t() | nil
        }

  @worker_env_name_format ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @doc """
  Builds an exact key definition without registering it.

  The default value, when present, is validated immediately. Defaults participate
  in runtime resolution, so an invalid default would be a boot-time contract bug.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = attrs_map(attrs)

    with {:ok, key} <- fetch_string(attrs, :key),
         {:ok, schema} <- fetch_schema(attrs),
         {:ok, encrypted} <- fetch_boolean(attrs, :encrypted),
         {:ok, default?, default_value} <- fetch_default(attrs, schema),
         {:ok, description} <- fetch_optional_string(attrs, :description),
         {:ok, generator} <- fetch_optional_generator(attrs),
         {:ok, scope} <- fetch_scope(attrs),
         {:ok, console_writable} <- fetch_console_writable(attrs),
         {:ok, worker_env_name} <- fetch_optional_worker_env_name(attrs) do
      {:ok,
       %__MODULE__{
         key: key,
         schema: schema,
         encrypted: encrypted,
         default?: default?,
         default_value: default_value,
         description: description,
         generator: generator,
         scope: scope,
         console_writable: console_writable,
         worker_env_name: worker_env_name
       }}
    end
  end

  @doc """
  Builds an exact key definition and raises when the declaration is invalid.
  """
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, definition} ->
        definition

      {:error, reason} ->
        raise ArgumentError, "invalid app configure definition: #{inspect(reason)}"
    end
  end

  @doc """
  Validates and normalizes one value according to the definition schema.

  The extra JSON check keeps AppConfigure aligned with its `jsonb` storage and
  encrypted JSON serialization boundary.
  """
  @spec validate(t(), term()) :: {:ok, term()} | {:error, term()}
  def validate(%__MODULE__{schema: schema}, value) do
    with {:ok, parsed} <- Schema.validate(schema, value),
         {:ok, _value} <- Schema.ensure_json_value(parsed) do
      {:ok, parsed}
    end
  end

  @doc """
  Produces a generated value and validates it without persisting it.
  """
  @spec generate(t()) :: {:ok, term()} | {:error, term()}
  def generate(%__MODULE__{generator: nil}), do: {:error, :no_generator}

  def generate(%__MODULE__{generator: generator} = definition) do
    validate(definition, generator.())
  end

  defp attrs_map(attrs) when is_list(attrs), do: Map.new(attrs)
  defp attrs_map(attrs) when is_map(attrs), do: attrs

  defp fetch_string(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_string, key}}
      :error -> {:error, {:missing, key}}
    end
  end

  defp fetch_schema(attrs) do
    case Map.fetch(attrs, :schema) do
      {:ok, %Schema{} = schema} -> {:ok, schema}
      {:ok, schema} when is_function(schema, 1) -> {:ok, schema}
      {:ok, _schema} -> {:error, :invalid_schema}
      :error -> {:error, {:missing, :schema}}
    end
  end

  defp fetch_boolean(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_boolean, key}}
      :error -> {:error, {:missing, key}}
    end
  end

  # Defaults are effective runtime values, not rows to backfill. Validating them
  # here lets resolution trust the definition instead of rechecking every read.
  defp fetch_default(attrs, schema) do
    case Map.fetch(attrs, :default_value) do
      {:ok, value} ->
        with {:ok, parsed} <- Schema.validate(schema, value),
             {:ok, _value} <- Schema.ensure_json_value(parsed) do
          {:ok, true, parsed}
        end

      :error ->
        {:ok, false, nil}
    end
  end

  defp fetch_optional_string(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, nil} -> {:ok, nil}
      {:ok, _value} -> {:error, {:invalid_string, key}}
      :error -> {:ok, nil}
    end
  end

  defp fetch_optional_generator(attrs) do
    case Map.fetch(attrs, :generator) do
      {:ok, generator} when is_function(generator, 0) -> {:ok, generator}
      {:ok, nil} -> {:ok, nil}
      {:ok, _generator} -> {:error, :invalid_generator}
      :error -> {:ok, nil}
    end
  end

  defp fetch_scope(attrs) do
    case Map.fetch(attrs, :scope) do
      {:ok, :global} -> {:ok, :global}
      {:ok, :scoped} -> {:ok, :scoped}
      {:ok, nil} -> {:ok, :scoped}
      {:ok, _scope} -> {:error, :invalid_scope}
      :error -> {:ok, :scoped}
    end
  end

  defp fetch_console_writable(attrs) do
    case Map.fetch(attrs, :console_writable) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_boolean, :console_writable}}
      :error -> {:ok, true}
    end
  end

  # Marks the key's resolved value for export into Agent Computer shells. Only
  # the POSIX name syntax is checked here; worker-side naming policy (reserved
  # names, merge order) is owned by the WorkerEnv subsystem.
  defp fetch_optional_worker_env_name(attrs) do
    case Map.fetch(attrs, :worker_env_name) do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, name} when is_binary(name) ->
        if Regex.match?(@worker_env_name_format, name) do
          {:ok, name}
        else
          {:error, {:invalid_worker_env_name, name}}
        end

      {:ok, name} ->
        {:error, {:invalid_worker_env_name, name}}
    end
  end
end
