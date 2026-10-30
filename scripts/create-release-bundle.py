#!/usr/bin/env python3
"""Package the exact source chart/scripts with the digest returned after docker push."""
import hashlib,json,os,pathlib,re,shutil,sys
inspection=json.load(open(sys.argv[1]));repository=sys.argv[2];out=pathlib.Path(sys.argv[3])
digests=[s.split('@',1)[1] for s in inspection[0].get('RepoDigests',[]) if s.startswith(repository+'@')]
if len(set(digests))!=1 or not re.fullmatch(r'sha256:[a-f0-9]{64}',digests[0]): raise SystemExit('Cannot resolve one pushed image digest')
if out.exists(): shutil.rmtree(out)
out.mkdir()
shutil.copytree('helm/order-service',out/'chart')
shutil.copytree('scripts',out/'scripts',ignore=shutil.ignore_patterns('__pycache__','tests'))
metadata={'repository':os.environ['GITHUB_REPOSITORY'],'source_sha':os.environ['GITHUB_SHA'],'source_ref':os.environ['GITHUB_REF'],'run_id':os.environ['GITHUB_RUN_ID'],'run_attempt':os.environ['GITHUB_RUN_ATTEMPT'],'image_repository':repository,'image_digest':digests[0]}
(out/'release.json').write_text(json.dumps(metadata,indent=2)+'\n')
lines=[hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.relative_to(out).as_posix() for p in sorted(out.rglob('*')) if p.is_file()]
(out/'SHA256SUMS').write_text('\n'.join(lines)+'\n')
print('Prepared deployment bundle for source '+metadata['source_sha'])
