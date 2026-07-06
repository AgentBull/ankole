defmodule Ankole.SignalsGateway.GroupMessageModesTest do
  use ExUnit.Case, async: true

  alias Ankole.SignalsGateway.GroupMessageModes

  test "maps public IM group-message modes to durable binding policies" do
    assert GroupMessageModes.default_mode() == "addressed_only"
    assert GroupMessageModes.policy("addressed_only") == {:ok, :ignore}
    assert GroupMessageModes.policy("observe_all") == {:ok, :record_only}
    assert GroupMessageModes.policy("may_intervene") == {:ok, :may_intervene}

    assert GroupMessageModes.policy("made_up") ==
             {:error, {:unknown_group_message_mode, "made_up"}}
  end

  test "builds localized field metadata for an adapter-supported subset" do
    field = GroupMessageModes.field(["observe_all", "may_intervene"])

    assert field.path == "group_message_mode"
    assert field.default == "observe_all"
    assert field.advanced == false
    assert field.label["zh-Hans-CN"] == "群聊消息模式"
    assert Enum.map(field.options, & &1.value) == ["observe_all", "may_intervene"]
    assert hd(field.options).description["default"] =~ "Mirror unaddressed group messages"
  end
end
