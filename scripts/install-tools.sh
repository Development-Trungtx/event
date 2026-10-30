#!/usr/bin/env bash
# Linux x86_64 only. Downloads are version-locked and SHA256-verified before execution.
set -Eeuo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
prefix=${1:?Usage: install-tools.sh PREFIX [helm trivy actionlint shellcheck]}
shift
if (( $# == 0 )); then set -- helm trivy actionlint shellcheck; fi
python3 - "$script_dir/../.github/tools.lock.json" "$prefix" "$@" <<'PYTHON'
import hashlib,json,os,pathlib,platform,sys,tarfile,tempfile,urllib.request
if platform.system()!='Linux' or platform.machine() not in ('x86_64','amd64'):
    raise SystemExit('Installer supports Linux x86_64 only; install equivalent pinned tools manually.')
lock=json.load(open(sys.argv[1]));dest=pathlib.Path(sys.argv[2]).resolve()/'bin';dest.mkdir(parents=True,exist_ok=True)
for name in sys.argv[3:]:
    item=lock[name]
    with tempfile.TemporaryDirectory() as td:
        archive=pathlib.Path(td)/'tool.tar.gz'
        request=urllib.request.Request(item['url'],headers={'User-Agent':'single-service-cicd'})
        with urllib.request.urlopen(request,timeout=120) as src,archive.open('wb') as out:
            while chunk:=src.read(1024*1024): out.write(chunk)
        if hashlib.sha256(archive.read_bytes()).hexdigest()!=item['sha256']:
            raise SystemExit(f'Checksum mismatch for {name}')
        with tarfile.open(archive) as tf:
            member=tf.getmember(item['member'])
            if not member.isfile(): raise SystemExit('Expected a regular executable')
            (dest/name).write_bytes(tf.extractfile(member).read())
        (dest/name).chmod(0o755)
        print(f'{name} {item["version"]} installed')
PYTHON
