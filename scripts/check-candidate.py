#!/usr/bin/env python3
"""Validate provenance and skip obsolete branch candidates without exposing credentials."""
import json,os,pathlib,re,sys,urllib.parse,urllib.request
bundle=pathlib.Path(os.environ['BUNDLE_DIR'])
meta=json.loads((bundle/'release.json').read_text())
sha=os.environ['EXPECTED_SOURCE_SHA'];repo=os.environ['GITHUB_REPOSITORY'];ref=os.environ['GITHUB_REF']
if not re.fullmatch(r'[0-9a-f]{40}',sha): raise SystemExit('Invalid source SHA')
if meta['source_sha']!=sha or meta['repository']!=repo or meta['source_ref']!=ref:
    raise SystemExit('Release metadata does not match the trusted source run')
if not re.fullmatch(r'sha256:[0-9a-f]{64}',meta['image_digest']) or meta['image_digest']=='sha256:'+'0'*64:
    raise SystemExit('Invalid release image digest')
if meta['image_repository']!='ghcr.io/'+repo.lower(): raise SystemExit('Unexpected image repository')
expected={'refs/heads/dev':'dev','refs/heads/master':'production'}
if expected.get(ref)!=os.environ['TARGET_ENVIRONMENT']: raise SystemExit('Source branch/environment mismatch')
api=os.environ.get('GITHUB_API_URL','https://api.github.com').rstrip('/')
branch=urllib.parse.quote(ref.removeprefix('refs/heads/'),safe='')
request=urllib.request.Request(f'{api}/repos/{repo}/git/ref/heads/{branch}',headers={'Authorization':'Bearer '+os.environ['GH_TOKEN'],'Accept':'application/vnd.github+json','User-Agent':'single-service-cicd'})
with urllib.request.urlopen(request,timeout=30) as response: head=json.load(response)['object']['sha']
fresh=head==sha
if output:=os.environ.get('GITHUB_OUTPUT'):
    with open(output,'a') as f: f.write('deploy='+str(fresh).lower()+'\n')
if not fresh: print('Skipped obsolete candidate: branch moved before CD started.')
else: print('Candidate metadata and branch HEAD verified.')
