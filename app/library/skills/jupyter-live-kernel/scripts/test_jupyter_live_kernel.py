import json
import unittest
from unittest.mock import MagicMock, patch

import jupyter_live_kernel as kernel


class ExecutionOrderTest(unittest.TestCase):
    def test_reply_and_idle_can_arrive_in_either_order(self):
        for order in [("execute_reply", "status"), ("status", "execute_reply")]:
            with self.subTest(order=order):
                ws = MagicMock()

                def messages():
                    request = json.loads(ws.send.call_args.args[0])
                    parent = {"msg_id": request["header"]["msg_id"]}
                    yield json.dumps({"header": {"msg_type": "status"},
                                      "parent_header": {"msg_id": "another-request"},
                                      "content": {"execution_state": "idle"}})
                    for kind in order:
                        content = {"status": "ok", "execution_count": 1} if kind == "execute_reply" else {"execution_state": "idle"}
                        yield json.dumps({"header": {"msg_type": kind}, "parent_header": parent,
                                          "channel": "shell" if kind == "execute_reply" else "iopub", "content": content})
                    raise AssertionError("Execution read past its reply and idle boundary")

                ws.recv.side_effect = messages()
                with patch.object(kernel, "_ensure_kernel_idle"), patch.object(kernel.socket, "socket"), \
                        patch.object(kernel.ServerClient, "websocket_headers", return_value=[]), \
                        patch.object(kernel.websocket, "create_connection", return_value=ws):
                    result = kernel._execute_via_websocket(
                        kernel.ServerInfo("/unused.sock", "/", "/tmp", "fixture"),
                        kernel_id="kernel", session_id="session", path=None,
                        request=kernel.ExecuteRequest("1 + 1"), timeout=1,
                    )
                self.assertEqual(result.reply, {"status": "ok", "execution_count": 1})
                self.assertEqual(ws.recv.call_count, 3)
                ws.send.assert_called_once()
                ws.close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
