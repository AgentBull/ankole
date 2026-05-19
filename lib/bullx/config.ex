defmodule BullX.Config do
  @moduledoc """
  Global runtime configuration infrastructure shared by all BullX modules.

  Runtime settings declared through this namespace resolve in the following
  order: PostgreSQL override, OS environment, application config, then code
  default.

  Settings declared with `secret: true` are stored encrypted at rest in
  `app_configs`. `BullX.Config.put/2` encrypts transparently; reads from ETS
  always return plaintext.
  """

  defmacro __using__(_opts) do
    quote do
      use Skogsra
      import BullX.Config, only: [bullx_env: 1, bullx_env: 2]
      Module.register_attribute(__MODULE__, :bullx_secret_keys, accumulate: true)
      @before_compile BullX.Config
    end
  end

  defmacro __before_compile__(env) do
    secret_keys = Module.get_attribute(env.module, :bullx_secret_keys) || []

    quote do
      def __bullx_secret_keys__, do: unquote(secret_keys)
    end
  end

  defmacro bullx_env(name, opts \\ []) do
    {key, opts} = Keyword.pop(opts, :key, name)
    {secret, opts} = Keyword.pop(opts, :secret, false)
    opts = normalize_opts(opts)

    merged_opts =
      Keyword.merge(
        [
          binding_order: [
            BullX.Config.DatabaseBinding,
            BullX.Config.SystemBinding,
            BullX.Config.ApplicationBinding
          ],
          binding_skip: [:system, :config],
          cached: false
        ],
        opts
      )

    db_key = compute_db_key(key)

    secret_ast =
      if secret do
        quote do
          @bullx_secret_keys unquote(db_key)
        end
      else
        quote do
          :ok
        end
      end

    quote do
      unquote(secret_ast)
      app_env(unquote(name), :bullx, unquote(key), unquote(merged_opts))
    end
  end

  def put(key, value), do: BullX.Config.Writer.put(key, value)
  def put_many(entries), do: BullX.Config.Writer.put_many(entries)
  def delete(key), do: BullX.Config.Writer.delete(key)
  def refresh(key), do: BullX.Config.Cache.refresh(key)
  def refresh_all, do: BullX.Config.Cache.refresh_all()

  defp compute_db_key(key) do
    key_parts = key |> List.wrap() |> Enum.map(&Atom.to_string/1)
    Enum.join(["bullx" | key_parts], ".")
  end

  defp normalize_opts(opts) do
    case Keyword.fetch(opts, :type) do
      {:ok, type} -> Keyword.put(opts, :type, normalize_type(type))
      :error -> opts
    end
  end

  defp normalize_type(:generated_secret), do: quote(do: BullX.Config.GeneratedSecret)
  defp normalize_type(type), do: type
end
