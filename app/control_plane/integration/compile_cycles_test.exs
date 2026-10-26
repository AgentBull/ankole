defmodule Ankole.CompileCyclesTest do
  use ExUnit.Case, async: false

  @task Path.expand("../lib/mix/tasks/ankole.compile_cycles.ex", __DIR__)
  @moduletag timeout: 60_000

  setup do
    root = Path.join(System.tmp_dir!(), "ankole-xref-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    root = File.cd!(root, &File.cwd!/0)
    host = Path.join(root, "app/control_plane")
    on_exit(fn -> File.rm_rf!(root) end)

    write!(root, "app/control_plane/mix.exs", """
    defmodule FixtureHost.MixProject do
      use Mix.Project
      def project do
        external_paths = Path.wildcard("../../plugins/*/lib") ++
          ["../../internals/control_plane/lib"] ++
          Path.wildcard("../../internals/plugins/*/lib")

        [
          app: :fixture_host,
          version: "0.1.0",
          elixirc_paths: ["lib"] ++ Enum.map(external_paths, &Path.expand/1),
          deps: [{:fixture_protocol, path: "../../libs/protocol"}]
        ]
      end
    end
    """)

    write!(root, "app/control_plane/lib/mix/tasks/ankole.compile_cycles.ex", File.read!(@task))

    write!(
      root,
      "app/control_plane/lib/domain.ex",
      "defmodule FixtureDomain, do: def(value, do: 1)"
    )

    write!(root, "plugins/alpha/lib/alpha.ex", """
    defmodule FixtureAlpha do
      defstruct []
      def value, do: FixtureDomain.value()
      defmacro compile_value, do: quote(do: 1)
    end
    """)

    write!(root, "plugins/beta/lib/beta.ex", "defmodule FixtureBeta, do: def(value, do: 2)")

    write!(
      root,
      "internals/plugins/private/lib/private.ex",
      "defmodule FixturePrivate, do: def(value, do: 3)"
    )

    write!(
      root,
      "internals/control_plane/lib/private_domain.ex",
      "defmodule FixturePrivateDomain, do: def(value, do: 4)"
    )

    write!(root, "libs/protocol/mix.exs", """
    defmodule FixtureProtocol.MixProject do
      use Mix.Project
      def project, do: [app: :fixture_protocol, version: "0.1.0"]
    end
    """)

    write!(
      root,
      "libs/protocol/lib/protocol.ex",
      "defmodule FixtureProtocol, do: def(value, do: 5)"
    )

    {:ok, root: root, host: host}
  end

  test "accepts domain callbacks, same-Plugin calls, and configured module selection", context do
    write!(context.root, "plugins/alpha/lib/consumer.ex", """
    defmodule FixtureAlphaConsumer do
      def run, do: FixtureAlpha.value()
    end
    """)

    write!(context.root, "app/control_plane/config/config.exs", """
    import Config
    config :fixture_host, :plugins, [FixtureAlpha, FixtureBeta, FixturePrivate]
    """)

    {output, status} = check(context.host)
    assert status == 0, output
    assert output =~ "Plugin dependency directions: OK"
    assert output =~ "fixture_protocol: compile-connected cycles"
  end

  for {label, code} <- [
        {"runtime", "def value, do: FixtureAlpha.value()"},
        {"export", "def value, do: %FixtureAlpha{}"},
        {"compile", "require FixtureAlpha\ndef value, do: FixtureAlpha.compile_value()"}
      ] do
    test "rejects a domain #{label} dependency on a concrete Plugin", context do
      write!(context.root, "app/control_plane/lib/consumer.ex", """
      defmodule FixtureConsumer do
        #{unquote(code)}
      end
      """)

      {output, status} = check(context.host)
      assert status != 0

      assert output =~
               "app/control_plane/lib/consumer.ex -> plugins/alpha/lib/alpha.ex (#{unquote(label)})"
    end
  end

  test "rejects private-domain and cross-Plugin references by source path", context do
    write!(context.root, "internals/control_plane/lib/private_domain.ex", """
    defmodule FixturePrivateDomain do
      def value, do: FixtureAlpha.value()
    end
    """)

    write!(context.root, "plugins/beta/lib/beta.ex", """
    defmodule FixtureBeta do
      def value, do: FixturePrivate.value()
    end
    """)

    write!(context.root, "internals/plugins/private/lib/consumer.ex", """
    defmodule FixturePrivateConsumer do
      def value, do: FixtureAlpha.value()
    end
    """)

    {output, status} = check(context.host)
    assert status != 0

    assert output =~
             "internals/control_plane/lib/private_domain.ex -> plugins/alpha/lib/alpha.ex (runtime)"

    assert output =~
             "plugins/beta/lib/beta.ex -> internals/plugins/private/lib/private.ex (runtime)"

    assert output =~
             "internals/plugins/private/lib/consumer.ex -> plugins/alpha/lib/alpha.ex (runtime)"
  end

  test "allows only the two concrete configuration targets of the temporary upgrade", context do
    for {plugin, module} <- [
          {"slack_adapter", FixtureSlackConfig},
          {"microsoft365_adapter", FixtureMicrosoftConfig}
        ] do
      write!(
        context.root,
        "plugins/#{plugin}/lib/ankole/plugins/#{plugin}/config.ex",
        "defmodule #{inspect(module)}, do: def(value, do: 1)"
      )
    end

    write!(context.root, "app/control_plane/lib/ankole/upgrade_202610.ex", """
    defmodule FixtureUpgrade do
      def modules, do: [FixtureSlackConfig, FixtureMicrosoftConfig]
    end
    """)

    {output, status} = check(context.host)
    assert status == 0, output

    write!(context.root, "app/control_plane/lib/ankole/upgrade_202610.ex", """
    defmodule FixtureUpgrade do
      def modules, do: [FixtureSlackConfig, FixtureMicrosoftConfig, FixtureAlpha]
    end
    """)

    write!(context.root, "app/control_plane/lib/ankole/other_upgrade.ex", """
    defmodule FixtureOtherUpgrade do
      def module, do: FixtureSlackConfig
    end
    """)

    {output, status} = check(context.host)
    assert status != 0

    assert output =~
             "app/control_plane/lib/ankole/upgrade_202610.ex -> plugins/alpha/lib/alpha.ex (runtime)"

    assert output =~
             "app/control_plane/lib/ankole/other_upgrade.ex -> plugins/slack_adapter/lib/ankole/plugins/slack_adapter/config.ex (runtime)"
  end

  test "checks compile-connected cycles in a local library", context do
    write!(context.root, "libs/protocol/lib/first.ex", """
    defmodule FixtureProtocolFirst do
      @value FixtureProtocolSecond.value()
      def value, do: @value
    end
    """)

    write!(context.root, "libs/protocol/lib/second.ex", """
    defmodule FixtureProtocolSecond do
      def value, do: 1
      def first, do: FixtureProtocolFirst.value()
    end
    """)

    {output, status} = check(context.host)
    assert status != 0
    assert output =~ "fixture_protocol: compile-connected cycles"
    assert output =~ "Too many cycles"
  end

  defp check(host) do
    System.cmd("mix", ["ankole.compile_cycles"],
      cd: host,
      env: [
        {"MIX_ENV", "test"},
        {"MIX_BUILD_PATH", nil},
        {"MIX_DEPS_PATH", nil},
        {"MIX_LOCKFILE", nil}
      ],
      stderr_to_stdout: true
    )
  end

  defp write!(root, path, content) do
    target = Path.join(root, path)
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, content)
  end
end
