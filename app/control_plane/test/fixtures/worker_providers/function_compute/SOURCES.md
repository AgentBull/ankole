# Function Compute protocol fixtures

These fixtures describe the wire protocol. IDs, regions, dates, paths, and
credentials use test values. `sandbox_created`, `sandbox`, and `oss_mount`
retain the shapes observed in real `ap-southeast-1` requests on 2026-10-08.
The create response has no state or metadata; a later GET supplies them.
The other fixtures come from the official contracts below, not cloud captures.

- [Sandbox Python SDK, 2026-08-20](https://github.com/aliyun/alibabacloud-python-sdk/tree/master/sandbox-20260820):
  `CreateTemplate`, `ListTemplates`, `CreateVolume`, `ListVolumes`, and
  `DeleteVolume` use `/pop/2026-08-20`. The generated `PublicTemplate` and
  response models define the JSON keys in this file.
- [NAS Python SDK, 2017-06-26](https://github.com/aliyun/alibabacloud-python-sdk/tree/master/nas-20170626):
  AgenticSpace and AccessPoint operations are RPC requests. Nested quota and
  tag fields become indexed query parameters. `DescribeAgenticSpaces` returns
  `AgenticSpaces.AgenticSpace`; `DescribeAccessPoints` returns `AccessPoints`.
- [CreateAgenticSpace](https://help.aliyun.com/zh/nas/developer-reference/api-nas-2017-06-26-createagenticspace):
  a root directory, byte quota, file count quota, and duplicate path errors.
- [AgenticFS volumes](https://help.aliyun.com/zh/agent-sandbox/user-guide/create-an-agenticfs-volume):
  `serverAddr` includes `:/`. The Volume is metadata; the AgenticSpace owns data.
- [E2B Python SDK 2.31.0](https://pypi.org/project/e2b/2.31.0/):
  `api/client/models`, `api/client/api/sandboxes`, and `filesystem/filesystem.py`
  define the sandbox and envd protocols. `Sandbox.create` converts the public
  `volume_mounts` dictionary to a JSON list of `{name, path}` objects. List
  pagination uses `x-next-token`. Pause sends `memory: true`. The file upload
  uses multipart field `file`, the full path as filename, and `username=root`.
- [Aliyun E2B compatibility](https://help.aliyun.com/zh/agent-sandbox/developer-reference/e2b-sdk-compatible-api-list)
  declares support for these operations.
- [Dynamic OSS mounts](https://help.aliyun.com/en/agent-sandbox/user-guide/mount-oss-dynamically-1):
  `bucketPath` is an absolute path. A real request without its leading slash
  returned HTTP 500 twice. The same production client succeeded after that
  slash was restored. Real envd root uploads and uid 1000 file operations
  succeeded. The OSS mount was root-owned and writable; `chown` returned EIO.
- [ACS3 signature](https://help.aliyun.com/zh/sdk/product-overview/v3-request-structure-and-signature):
  the signature test uses the fixed-parameter example, including its expected
  signature. All present `content-type`, `host`, and `x-acs-*` headers are signed.

Real base sandboxes retained OSS files across deletion and recreation. Removing
one mounted prefix left another prefix intact. This did not use the Worker
image, coordinator, or deletion helper. AgenticSpace, template capture, memory
pause, and the 24-hour limit still need cloud checks. These unit fixtures do
not prove those behaviors.
