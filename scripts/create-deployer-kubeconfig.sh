#!/usr/bin/env bash
# Run as a cluster administrator on your machine. Output contains a short-lived token.
set -Eeuo pipefail
namespace=${1:?Usage: create-deployer-kubeconfig.sh NAMESPACE OUTPUT_FILE [DURATION]}
output=${2:?Provide a NEW private kubeconfig path outside the repository}
duration=${3:-24h}
[[ "$namespace" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || exit 1
[[ ! -e "$output" ]] || { echo 'Refusing to overwrite an existing credential file.' >&2; exit 1; }
umask 077
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
kubectl config view --raw --minify --flatten -o json > "$work/admin.json"
kubectl -n "$namespace" create token github-deployer --duration="$duration" > "$work/token"
python3 - "$work/admin.json" "$work/token" "$namespace" "$output" <<'PYTHON'
import base64,datetime,json,os,pathlib,sys
admin=json.load(open(sys.argv[1]));cluster=admin['clusters'][0]['cluster'];ns=sys.argv[3]
if cluster.get('insecure-skip-tls-verify'): raise SystemExit('Refusing an insecure Kubernetes API connection')
if not cluster.get('certificate-authority-data'): raise SystemExit('Expected an embedded cluster CA certificate')
name='github-deployer-'+ns
config={'apiVersion':'v1','kind':'Config','clusters':[{'name':'target','cluster':{'server':cluster['server'],'certificate-authority-data':cluster['certificate-authority-data']}}],'users':[{'name':name,'user':{'token':pathlib.Path(sys.argv[2]).read_text().strip()}}],'contexts':[{'name':name,'context':{'cluster':'target','user':name,'namespace':ns}}],'current-context':name}
fd=os.open(sys.argv[4],os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'w') as f: json.dump(config,f,indent=2)
print('Created private namespace-scoped kubeconfig. Context: '+name)
try:
    payload=config['users'][0]['user']['token'].split('.')[1]
    claims=json.loads(base64.urlsafe_b64decode(payload+'='*(-len(payload)%4)))
    print('Token expires at '+datetime.datetime.fromtimestamp(claims['exp'],datetime.timezone.utc).isoformat())
except (ValueError,KeyError,IndexError):
    print('Check actual token expiration with your cluster administrator.')
print('Rotate before actual expiry. No administrator credential was copied.')
PYTHON
