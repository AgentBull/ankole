defmodule Ankole.Formal.ProtocolLawsTest do
  use ExUnit.Case, async: true

  @moduletag :laws

  for name <-
        ~w(AccessGraph HumanAccess AttemptAuthority AppletLifecycle BaseRecovery RuntimeSupport) do
    @name name
    test "#{name} protocol laws" do
      path = Path.expand("../../lean/#{@name}.lean", __DIR__)

      source = %{
        "file" => path,
        "span" => [1, 1],
        "indentation" => 0,
        "source" => File.read!(path)
      }

      file = %{
        "file" => path,
        "module" => "Ankole.Protocol.#{@name}",
        "contents" => [],
        "imports" => [],
        "preludes" => [source]
      }

      export = Path.join(System.get_env("LYNX_EXPORT", "tmp/export"), "protocols/#{@name}.ndjson")

      reports =
        Lynx.Commands.verify!(Path.expand("../../deps/lynx/Lean", __DIR__), [file],
          export: export,
          options: [maxRecDepth: 10_000, maxHeartbeats: 800_000]
        )

      assert Enum.all?(reports, &(&1.status == :ok)),
             inspect(reports, pretty: true, limit: :infinity)
    end
  end
end
