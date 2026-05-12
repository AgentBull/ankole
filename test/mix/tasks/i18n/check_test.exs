defmodule Mix.Tasks.I18n.CheckTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @tag :tmp_dir
  test "fails when a translation drops variables used in MF2 function options", %{
    tmp_dir: tmp_dir
  } do
    File.write!(
      Path.join(tmp_dir, "en-US.toml"),
      """
      [checkout]
      summary = "Checkout {$total :currency currency=$currency}"
      """
    )

    File.write!(
      Path.join(tmp_dir, "zh-Hans-CN.toml"),
      """
      [checkout]
      summary = "结算 {$total :currency currency=USD}"
      """
    )

    Mix.Task.reenable("i18n.check")

    output =
      capture_io(:stderr, fn ->
        assert {:shutdown, 1} =
                 catch_exit(Mix.Tasks.I18n.Check.run(["--dir", tmp_dir]))
      end)

    assert output =~ ~s(key "checkout.summary" — missing variables: currency)
  end

  @tag :tmp_dir
  test "fails when a client catalog has invalid MF2 syntax", %{tmp_dir: tmp_dir} do
    server_dir = Path.join(tmp_dir, "server")
    client_dir = Path.join(tmp_dir, "client")
    File.mkdir_p!(server_dir)
    File.mkdir_p!(client_dir)

    write_source_catalog(server_dir)

    File.write!(
      Path.join(client_dir, "en-US.toml"),
      """
      [web.setup]
      title = "Hello {$"
      """
    )

    Mix.Task.reenable("i18n.check")

    output =
      capture_io(:stderr, fn ->
        assert {:shutdown, 1} =
                 catch_exit(
                   Mix.Tasks.I18n.Check.run(["--dir", server_dir, "--client-dir", client_dir])
                 )
      end)

    assert output =~ "client catalog"
    assert output =~ "i18n normalization failed"
  end

  @tag :tmp_dir
  test "fails when a non-source client catalog adds a key outside the source set", %{
    tmp_dir: tmp_dir
  } do
    server_dir = Path.join(tmp_dir, "server")
    client_dir = Path.join(tmp_dir, "client")
    File.mkdir_p!(server_dir)
    File.mkdir_p!(client_dir)

    write_source_catalog(server_dir)

    File.write!(
      Path.join(client_dir, "en-US.toml"),
      """
      [web.setup]
      title = "Setup"
      """
    )

    File.write!(
      Path.join(client_dir, "zh-Hans-CN.toml"),
      """
      [web.setup]
      title = "设置"
      extra = "多余"
      """
    )

    Mix.Task.reenable("i18n.check")

    output =
      capture_io(:stderr, fn ->
        assert {:shutdown, 1} =
                 catch_exit(
                   Mix.Tasks.I18n.Check.run(["--dir", server_dir, "--client-dir", client_dir])
                 )
      end)

    assert output =~ ~s(client: zh-Hans-CN: key "web.setup.extra")
  end

  defp write_source_catalog(dir) do
    File.write!(
      Path.join(dir, "en-US.toml"),
      """
      [app]
      close = "Close"
      """
    )
  end
end
