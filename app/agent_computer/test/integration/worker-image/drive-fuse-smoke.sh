#!/usr/bin/env bash
set -euo pipefail
# A cold platform must not lose Drive capability while the real client starts.
probe_bin=$(mktemp -d)
printf '#!/bin/sh\nsleep 6\nexec /usr/local/bin/ankole-rclone "$@"\n' > "$probe_bin/ankole-rclone"
chmod +x "$probe_bin/ankole-rclone"
PATH="$probe_bin:$PATH" /usr/local/libexec/ankole-drive-probe
rm -rf "$probe_bin"
mkdir -p /mnt/drive /cache /recovery
ankole-rclone mount2 test: /mnt/drive --config /test-config/rclone.conf --cache-dir /cache \
  --vfs-cache-mode full --vfs-write-back 1s --links --rc --rc-addr 127.0.0.1:5572 --rc-no-auth \
  --transfers 4 --low-level-retries 1 --log-file /tmp/rclone.log &
pid=$!
cleanup() {
  status=$?
  cat /tmp/rclone.log
  umount /mnt/drive || true
  kill "$pid" 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT
for attempt in $(seq 1 100); do
  if mountpoint -q /mnt/drive; then break; fi
  kill -0 "$pid"
  sleep .1
done
curl -sf http://127.0.0.1:5572/ankole/configure -H 'Content-Type: application/json' -d '{"fs":"test","recovery":"/recovery"}'
python3 - <<'PY'
import configparser, errno, hashlib, http.client, json, mmap, os, pathlib, sqlite3, stat, subprocess, urllib.parse, urllib.request
drive = pathlib.Path('/mnt/drive')
script = drive/'Skills/fuse-check/scripts/run.sh'
assert stat.S_IMODE(script.stat().st_mode) == 0o555
assert subprocess.check_output([str(script)]) == b'meta-capability'
for path in [script, drive/'Skills/fuse-check/SKILL.md', drive/'AGENTS.md', drive/'DESIGN.md']:
    assert stat.S_IMODE(path.stat().st_mode) in [0o444, 0o555]
    try:
        path.open('r+b')
        raise AssertionError(f'{path} accepted a local write')
    except OSError as error:
        assert error.errno in [errno.EACCES, errno.EROFS, errno.EPERM], error
assert stat.S_IMODE((drive/'Brain').stat().st_mode) == 0o555
root = pathlib.Path('/mnt/drive/AgentDrive/fuse')
root.mkdir()
since_seq=0
def flush(allow_failure=False):
    req=urllib.request.Request('http://127.0.0.1:5572/ankole/flush',data=json.dumps({'fs':'test','since_seq':since_seq}).encode(),headers={'Content-Type':'application/json'})
    result=json.load(urllib.request.urlopen(req,timeout=60))
    if not allow_failure: assert not any(f['Failure'] for f in result.get('files',[])), result
    return result
# Exercise real streaming PUT and cold server-side COPY without hydrating the source.
config=configparser.ConfigParser(interpolation=None)
config.read('/test-config/rclone.conf')
endpoint=urllib.parse.urlsplit(config['test']['url'])
def dav(method, name, data=b'', headers=None):
    headers=dict(headers or {}, Authorization='Bearer '+config['test']['bearer_token'])
    connection=http.client.HTTPConnection(endpoint.hostname,endpoint.port,timeout=120)
    connection.request(method,endpoint.path+'/AgentDrive/fuse/'+name,body=data,headers=headers)
    response=connection.getresponse()
    body=response.read()
    assert response.status < 300,(method,name,response.status,body)
    result=(body,dict(response.getheaders()))
    connection.close()
    return result
# A long-lived sandbox bind-mount holds the original FUSE inode across edits.
if os.environ.get('ANKOLE_FUSE_CONTRACT_TEST') == '1':
    import time
    def contract(text):
        request=urllib.request.Request(f'http://{endpoint.netloc}/test-contract', data=text.encode(), method='PUT')
        return urllib.request.urlopen(request, timeout=30).read()
    assert contract('') == b''
    bound=pathlib.Path('/mnt/bound-AGENTS.md')
    bound.touch()
    subprocess.run(['mount','--bind',str(drive/'AGENTS.md'),str(bound)], check=True)
    try:
        assert bound.read_bytes() == b''
        for text in ['A growing instruction ' * 1000, 'Short instruction', 'Other instruction', '']:
            expected=contract(text)
            time.sleep(1.2)
            assert bound.stat().st_size == len(expected), (bound.stat().st_size, len(expected))
            actual=bound.read_bytes()
            assert actual == expected, (text[:24], len(actual), len(expected), actual[:80], expected[:80])
    finally:
        subprocess.run(['umount',str(bound)],check=True)
chunk=bytes(range(256))*4096
connection=http.client.HTTPConnection(endpoint.hostname,endpoint.port,timeout=120)
connection.putrequest('PUT',endpoint.path+'/AgentDrive/fuse/large.bin')
connection.putheader('Authorization','Bearer '+config['test']['bearer_token'])
connection.putheader('Content-Length',str(300*len(chunk)))
connection.endheaders()
for _ in range(300): connection.send(chunk)
response=connection.getresponse()
assert response.status == 201,(response.status,response.read())
response.read()
connection.close()
dav('PUT','unchanged.bin',b'no change')
# Seed remote files before the first local lookup fills the directory cache.
# A source enlarged after the local size check must not exceed copy_file_range's count.
dav('PUT','growing-source.bin',b'old')
with (root/'growing-source.bin').open('rb') as source, (root/'bounded-copy.bin').open('wb') as target:
    assert os.fstat(source.fileno()).st_size == 3
    dav('PUT','growing-source.bin',b'longer version')
    try:
        copied=os.copy_file_range(source.fileno(),target.fileno(),3)
    except OSError as error:
        assert error.errno == errno.ESTALE,error
    else:
        raise AssertionError(f'COPY accepted a different source version: requested 3 bytes, returned {copied}')
flush()
with (root/'large.bin').open('rb') as source, (root/'large-copy.bin').open('wb') as target:
    copied=os.copy_file_range(source.fileno(),target.fileno(),300*len(chunk))
    assert copied == 300*len(chunk),copied
    assert os.fstat(target.fileno()).st_size == copied
assert (root/'large-copy.bin').stat().st_size == 300*len(chunk)
with (root/'large-copy.bin').open('rb') as copied:
    assert copied.read(64) == chunk[:64]
    assert os.pread(copied.fileno(),64,299*len(chunk)+123) == chunk[123:187]
flush()
assert dav('HEAD','large-copy.bin')[1]['content-length'] == str(300*len(chunk))
# A source still open for writing must commit its new bytes before COPY.
with (root/'dirty-source.bin').open('w+b') as source, (root/'dirty-copy.bin').open('wb') as target:
    source.write(b'fresh local source')
    source.flush()
    assert os.copy_file_range(source.fileno(),target.fileno(),18,0,0) == 18
assert (root/'dirty-copy.bin').read_bytes() == b'fresh local source'
flush()
assert dav('GET','dirty-copy.bin')[0] == b'fresh local source'
unchanged=root/'unchanged.bin'
content=unchanged.read_bytes()
unchanged.write_bytes(content)
flush()
# The cache has only a small downloaded range when this edit begins.
with (root/'large-copy.bin').open('r+b') as copied:
    os.pwrite(copied.fileno(),b'EDIT',10)
flush()
assert dav('GET','large-copy.bin',headers={'Range':'bytes=8-15'})[0] == chunk[8:10]+b'EDIT'+chunk[14:16]
assert dav('GET','large-copy.bin',headers={'Range':'bytes=314572700-314572799'})[0] == chunk[-100:]
# Refreshing the limit uses the same RC operation as token renewal.
def configure(limit):
    req=urllib.request.Request('http://127.0.0.1:5572/ankole/configure',data=json.dumps({'fs':'test','upload_limit':limit}).encode(),headers={'Content-Type':'application/json'})
    json.load(urllib.request.urlopen(req))
limit=int(dav('OPTIONS','')[1]['x-ankole-upload-limit'])
configure(50*1024*1024)
try:
    with (root/'limited.bin').open('wb') as limited:
        limited.truncate(51*1024*1024)
    raise AssertionError('expected local EFBIG')
except OSError as error:
    assert error.errno == errno.EFBIG,error
configure(limit)
flush()
(root/'random.bin').write_bytes(b'0123456789')
flush()
(root/'folder-source').mkdir()
(root/'folder-source'/'keep.txt').write_text('preserved subtree')
(root/'folder-target').mkdir()
flush()
os.rename(root/'folder-source',root/'folder-target')
assert (root/'folder-target'/'keep.txt').read_text() == 'preserved subtree'
folder=root/'before'
folder.mkdir()
with (folder/'held.txt').open('w') as held:
    held.write('before')
    held.flush()
    folder.rename(root/'after')
    held.write('-after')
assert (root/'after/held.txt').read_text()=='before-after'
flush()
for noise in ['.DS_Store','.note.swp','.note.swo','.~lock.report#','cache.sqlite-shm']:
    (root/noise).write_text('local only')
(root/'sed-business').write_text('must upload')
flush()
with (root/'random.bin').open('r+b') as f:
    os.pwrite(f.fileno(),b'XYZ',2)
    os.fsync(f.fileno())
assert (root/'random.bin').read_bytes()==b'01XYZ56789'
flush()
with (root/'random.bin').open('r+b') as f:
    mapping=mmap.mmap(f.fileno(),0)
    assert mapping[:]==b'01XYZ56789'
    mapping.close()
db=sqlite3.connect(root/'sqlite.db')
db.execute('create table items (value text)')
db.execute("insert into items values ('rollback')")
db.commit()
assert db.execute('select value from items').fetchone()==('rollback',)
db.execute('pragma journal_mode=wal')
db.execute("insert into items values ('wal')")
db.commit()
assert db.execute('select count(*) from items').fetchone()==(2,)
db.close()
flush()
(root/'guide._adoc.md').write_text('# Guide\n\noriginal\n')
flush()
text=(root/'guide._adoc.md').read_text()
(root/'temporary').write_text(text.replace('original','edited'))
os.replace(root/'temporary',root/'guide._adoc.md')
flush()
assert 'edited' in (root/'guide._adoc.md').read_text()
(root/'guide'/'script.py').write_text('print(42)\n')
(root/'link').symlink_to('random.bin')
assert (root/'link').read_bytes()==b'01XYZ56789'
pathlib.Path('/tmp/document-link').symlink_to(root/'guide._adoc.md')
assert 'edited' in pathlib.Path('/tmp/document-link').read_text()
flush()
base=pathlib.Path('/mnt/drive/AgentDrive/FuseBase._abase/Table 1')
try:
    (base/'link').symlink_to('/tmp/target')
    raise AssertionError('Base virtual paths must reject symlinks')
except OSError as error:
    assert error.errno == errno.EPERM, error
sink=base/'.import/append.jsonl'
sink.write_text('{"Name":"first"}\n')
# Opening the same sink immediately must wait for the prior upload and reset.
with sink.open('a') as f: f.write('{"Name":"second"}\n')
flush()
assert sink.read_bytes()==b''
export=base/'.export/json'
assert json.loads(export.read_text())==[{'Name':'first'},{'Name':'second'}]
assert export.stat().st_size==len(export.read_bytes())
record=next(base.glob('rec_*.json'))
before=json.loads(record.read_text())
changed=dict(before,Name='edited')
record.write_text(json.dumps(changed))
flush()
after=json.loads(record.read_text())
assert after['Name']=='edited',after
assert after['_versions']['Name']==before['_versions']['Name']+1,after
# A rejected slow atomic save preserves the draft and reports it at flush.
conflict=root/'conflict._adoc.md'
conflict.write_text('Initial paragraph.\n')
flush()
baseline=conflict.read_bytes()
dav('PUT','conflict._adoc.md',b'Browser paragraph.\n')
draft=root/'conflicting-save.tmp'
draft.write_bytes(baseline.replace(b'Initial',b'Worker'))
flush()
try:
    os.replace(draft,conflict)
    raise AssertionError('conflicting atomic save must fail')
except OSError:
    pass
rejected=flush(True)
failure=next(f for f in rejected['files'] if f['Path'].endswith('conflict._adoc.md'))
assert '412' in failure['Failure'],rejected
assert b'Worker paragraph.' in (pathlib.Path('/recovery')/pathlib.Path(failure['Recovery']).name).read_bytes()
assert b'Browser paragraph.' in dav('GET','conflict._adoc.md')[0]
# A new command window must not replay the earlier failure.
since_seq=max(f['Seq'] for f in rejected['files'])
# The temporary file can still be edited and saved after the rejected rename.
draft.write_bytes(dav('GET','conflict._adoc.md')[0])
flush()
req=urllib.request.Request('http://127.0.0.1:5572/ankole/invalidate',data=b'{"fs":"test","paths":["AgentDrive/fuse/conflict._adoc.md"]}',headers={'Content-Type':'application/json'})
json.load(urllib.request.urlopen(req))
conflict.read_bytes()
os.replace(draft,conflict)
flush()
bad=root/'invalid._adoc.md'
bad.write_text('---\nbroken: [\n---\n')
rejected=flush(True)
failure=next(f for f in rejected['files'] if f['Path'].endswith('invalid._adoc.md'))
assert '422' in failure['Failure'],rejected
assert (pathlib.Path('/recovery')/pathlib.Path(failure['Recovery']).name).read_text()=='---\nbroken: [\n---\n'
bad.write_text('# Corrected\n\nvalid\n')
flush()
assert 'Corrected' in bad.read_text()
print('FUSE POSIX files, SQLite, atomic save, open-handle directory rename, symlinks, Base import reset, export, field PATCH and rejected-draft retry passed')
PY
# An execution namespace keeps only its own view's Drive mounts. A copy of
# another view's mount would keep that FUSE connection open after the Worker
# unmounts it.
drives=/run/ankole-drives
mkdir -p "$drives/scope_own" "$drives/library_own" "$drives/scope_other" /drive /drive-recovery
for key in scope_own library_own scope_other; do mount -t tmpfs tmpfs "$drives/$key"; done
mkdir -p "$drives/scope_own/Public" "$drives/library_own/Skills"
touch "$drives/library_own/AGENTS.md" "$drives/library_own/DESIGN.md"
view_mounts=$(unshare --mount --pid --fork --mount-proc --propagation private \
  /usr/local/libexec/ankole-drive-view "$drives/scope_own" - /recovery "$drives/library_own" cat /proc/self/mountinfo)
grep -q " $drives/scope_own " <<<"$view_mounts"
grep -q " $drives/library_own " <<<"$view_mounts"
grep -q ' /drive/Public ' <<<"$view_mounts"
if grep -q " $drives/scope_other " <<<"$view_mounts"; then
  echo 'the execution namespace kept another view of Drive mounted' >&2
  exit 1
fi
grep -q " $drives/scope_other " /proc/self/mountinfo
for key in scope_other library_own scope_own; do umount "$drives/$key"; done
echo 'Drive execution view keeps only its own mounts'
