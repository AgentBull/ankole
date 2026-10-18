defmodule Ankole.DevCodeReload do
  @moduledoc false
  # Configuration loads this module before dependency paths are available.
  @compile {:no_warn_undefined, Phoenix.CodeReloader}

  # Mix unloads changed modules before compilation. This handler must stay outside
  # its compile paths so a reconciler can wait for Phoenix to load the new code.
  def undefined_function(module, function, args) do
    sync(module)
    :error_handler.undefined_function(module, function, args)
  end

  def undefined_lambda(module, function, args) do
    sync(module)
    :error_handler.undefined_lambda(module, function, args)
  end

  defdelegate breakpoint(module, function, args), to: :error_handler

  defp sync(module) do
    if :code.ensure_loaded(module) == {:error, :nofile} and
         module in (Application.spec(:ankole, :modules) || []) do
      Phoenix.CodeReloader.sync()
    end
  end
end
