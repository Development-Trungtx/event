#!/usr/bin/env bash
set -Eeuo pipefail
[[ -f ./mvnw && -f ./pom.xml ]] || { echo 'Run from the Maven project root containing mvnw and pom.xml.' >&2; exit 1; }
# verify runs integration tests only when the project configures the Failsafe plugin.
bash ./mvnw -B -ntp clean verify
mkdir -p .ci-output
python3 - <<'PYTHON'
import os,pathlib,shutil,zipfile
explicit=os.environ.get('APP_JAR_PATH','').strip()
candidates=[pathlib.Path(explicit)] if explicit else [p for p in pathlib.Path('target').glob('*.jar') if not p.name.endswith(('-sources.jar','-javadoc.jar','-tests.jar'))]
boot=[]
for path in candidates:
    if not path.is_file(): continue
    with zipfile.ZipFile(path) as jar:
        if any(n.startswith('BOOT-INF/classes/') for n in jar.namelist()): boot.append(path)
if len(boot)!=1:
    raise SystemExit(f'Expected one executable Spring Boot JAR; found {len(boot)}. Configure spring-boot:repackage and/or APP_JAR_PATH.')
shutil.copy2(boot[0],'.ci-output/app.jar')
print('Prepared one tested Spring Boot JAR.')
PYTHON
