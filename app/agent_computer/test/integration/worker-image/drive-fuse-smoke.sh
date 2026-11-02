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
import configparser, errno, hashlib, http.client, json, mmap, os, pathlib, sqlite3, urllib.parse, urllib.request
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
original=b'First block.\n\nMiddle block.\n\nLast block.\n'
dav('PUT','merge._awiki.md',original)
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
# A worker editing the last block and a browser editing the first should see both.
knowledge=root/'merge._awiki.md'
baseline=knowledge.read_bytes()
dav('PUT','merge._awiki.md',baseline.replace(b'First block.',b'Browser block, longer.'))
knowledge.write_bytes(baseline.replace(b'Last block.',b'Worker block, longer.'))
flush()
merged=knowledge.read_bytes()
assert b'Browser block, longer.' in merged and b'Worker block, longer.' in merged,merged
assert knowledge.stat().st_size == len(merged)
# Slow editor saves take MOVE after the temporary file has already uploaded.
baseline=knowledge.read_bytes()
dav('PUT','merge._awiki.md',baseline.replace(b'Browser block, longer.',b'Browser changed again.'))
slow=root/'slow-save.tmp'
slow.write_bytes(baseline.replace(b'Worker block, longer.',b'Worker changed again.'))
flush()
os.replace(slow,knowledge)
flush()
merged=knowledge.read_bytes()
assert b'Browser changed again.' in merged and b'Worker changed again.' in merged,merged
assert knowledge.stat().st_size == len(merged)
req=urllib.request.Request('http://127.0.0.1:5572/ankole/flush-paths',data=b'{"fs":"test","paths":["AgentDrive/fuse/merge._awiki.md"]}',headers={'Content-Type':'application/json'})
receipt=json.load(urllib.request.urlopen(req))
assert not receipt['files'],receipt
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
(root/'guide._awiki.md').write_text('# Guide\n\noriginal\n')
flush()
text=(root/'guide._awiki.md').read_text()
(root/'temporary').write_text(text.replace('original','edited'))
os.replace(root/'temporary',root/'guide._awiki.md')
flush()
assert 'edited' in (root/'guide._awiki.md').read_text()
(root/'guide._asub'/'script.py').write_text('print(42)\n')
(root/'link').symlink_to('random.bin')
assert (root/'link').read_bytes()==b'01XYZ56789'
pathlib.Path('/tmp/knowledge-link').symlink_to(root/'guide._awiki.md')
assert 'edited' in pathlib.Path('/tmp/knowledge-link').read_text()
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
conflict=root/'conflict._awiki.md'
conflict.write_text('Initial paragraph.\n')
flush()
baseline=conflict.read_bytes()
dav('PUT','conflict._awiki.md',b'Browser paragraph.\n')
draft=root/'conflicting-save.tmp'
draft.write_bytes(baseline.replace(b'Initial',b'Worker'))
flush()
try:
    os.replace(draft,conflict)
    raise AssertionError('conflicting atomic save must fail')
except OSError:
    pass
rejected=flush(True)
failure=next(f for f in rejected['files'] if f['Path'].endswith('conflict._awiki.md'))
assert '412' in failure['Failure'],rejected
assert b'Worker paragraph.' in (pathlib.Path('/recovery')/pathlib.Path(failure['Recovery']).name).read_bytes()
assert b'Browser paragraph.' in dav('GET','conflict._awiki.md')[0]
# A new command window must not replay the earlier failure.
since_seq=max(f['Seq'] for f in rejected['files'])
# The temporary file can still be edited and saved after the rejected rename.
draft.write_bytes(dav('GET','conflict._awiki.md')[0])
flush()
req=urllib.request.Request('http://127.0.0.1:5572/ankole/invalidate',data=b'{"fs":"test","paths":["AgentDrive/fuse/conflict._awiki.md"]}',headers={'Content-Type':'application/json'})
json.load(urllib.request.urlopen(req))
conflict.read_bytes()
os.replace(draft,conflict)
flush()
bad=root/'invalid._awiki.md'
bad.write_text('---\nbroken: [\n---\n')
rejected=flush(True)
failure=next(f for f in rejected['files'] if f['Path'].endswith('invalid._awiki.md'))
assert '422' in failure['Failure'],rejected
assert (pathlib.Path('/recovery')/pathlib.Path(failure['Recovery']).name).read_text()=='---\nbroken: [\n---\n'
bad.write_text('# Corrected\n\nvalid\n')
flush()
assert 'Corrected' in bad.read_text()
print('FUSE POSIX files, SQLite, atomic save, open-handle directory rename, symlinks, Base import reset, export, field PATCH and rejected-draft retry passed')
PY
