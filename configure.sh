#!/usr/bin/env bash
# env(환경값) + secrets.env(토큰·해시·Grafana 비밀번호, 없으면 생성) → build/{mgmt,dev,stg,prod} 렌더링.
# 몇 번 실행해도 된다. 비밀값은 secrets.env에 없는 것만 새로 만들므로, 특정 토큰만 바꾸려면
# secrets.env에서 그 줄(예: DEV_LOKI_TOKEN·DEV_LOKI_HASH)을 지우고 다시 실행한다.
set -euo pipefail
cd "$(dirname "$0")"
CLUSTERS="dev stg prod"

# 값은 env·secrets.env 파일에서만 읽는다 — 셸에 남아 있는 같은 이름의 변수가 끼어들지 않도록 먼저 비운다
for v in LOKI_DOMAIN MIMIR_DOMAIN TEMPO_DOMAIN GRAFANA_DOMAIN STORAGE_CLASS GATEWAY_NAME GATEWAY_NAMESPACE MGMT_CA_PEM REGISTRY GRAFANA_ADMIN_PASSWORD; do unset "$v"; done
for c in $CLUSTERS; do for k in LOKI MIMIR TEMPO; do unset "${c^^}_${k}_TOKEN" "${c^^}_${k}_HASH"; done; done

[ -f env ] || { echo "!! env 파일이 없음 — cp env.example env 후 값을 채울 것" >&2; exit 1; }
set -a; . ./env; set +a
for v in LOKI_DOMAIN MIMIR_DOMAIN TEMPO_DOMAIN GRAFANA_DOMAIN STORAGE_CLASS GATEWAY_NAME GATEWAY_NAMESPACE MGMT_CA_PEM; do
  [ -n "${!v:-}" ] || { echo "!! env의 $v 가 비어 있음" >&2; exit 1; }
done
# CA: PEM 형식, 만료 전, CA:TRUE 인증서만 받는다 (파일에 개인키가 섞여 있어도 인증서 블록만 쓴다)
if ! { openssl x509 -inform PEM -in "$MGMT_CA_PEM" -noout -checkend 0 >/dev/null 2>&1 \
       && openssl x509 -inform PEM -in "$MGMT_CA_PEM" -noout -ext basicConstraints 2>/dev/null | grep -q 'CA:TRUE'; }; then
  echo "!! $MGMT_CA_PEM 가 유효한 PEM CA 인증서가 아님(DER·만료·CA:FALSE·경로 오류)" >&2; exit 1
fi

# 1. 비밀값 — secrets.env에 없는 항목만 생성. 해시는 htpasswd(bcrypt)가 있으면 그것, 없으면 openssl apr1 (Traefik은 둘 다 지원)
hp() { local h; if command -v htpasswd >/dev/null; then htpasswd -nbB "$1" "$2"; else h=$(openssl passwd -apr1 "$2") && echo "$1:$h"; fi; }
umask 077
touch secrets.env && chmod 600 secrets.env
set -a; . ./secrets.env; set +a
NEW_PW=0
for c in $CLUSTERS; do
  C=${c^^}
  for k in LOKI MIMIR TEMPO; do
    tv="${C}_${k}_TOKEN"; hv="${C}_${k}_HASH"
    if [ -z "${!tv:-}" ]; then
      t=$(openssl rand -base64 32) && [ -n "$t" ] || { echo "!! 난수 생성 실패"; exit 1; }
      printf '%s=%s\n' "$tv" "$t" >> secrets.env; declare "$tv=$t"
      unset "$hv"; sed -i "/^${hv}=/d" secrets.env          # 토큰이 새로 생겼으면 해시도 새로
    fi
    if [ -z "${!hv:-}" ]; then
      h=$(hp "$c" "${!tv}") && [ -n "$h" ] || { echo "!! 해시 생성 실패(htpasswd/openssl 확인)"; exit 1; }
      printf "%s='%s'\n" "$hv" "$h" >> secrets.env; declare "$hv=$h"
    fi
  done
done
if [ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]; then
  GRAFANA_ADMIN_PASSWORD=$(openssl rand -base64 18) && [ -n "$GRAFANA_ADMIN_PASSWORD" ] || { echo "!! 난수 생성 실패"; exit 1; }
  printf 'GRAFANA_ADMIN_PASSWORD=%s\n' "$GRAFANA_ADMIN_PASSWORD" >> secrets.env; NEW_PW=1
fi

# 2. 렌더링 — 템플릿은 건드리지 않고 build/ 에 복사한 뒤 자리표시자를 채운다
rm -rf build && mkdir build
for d in mgmt $CLUSTERS; do cp -r "$d" build/; done
files=$(find build -type f -name '*.yaml')
# GATEWAY_NAMESPACE를 GATEWAY_NAME보다 먼저 (REPLACE_ME_GATEWAY_NAME이 REPLACE_ME_GATEWAY_NAMESPACE의 앞부분이라서)
sed -i \
  -e "s#REPLACE_ME_LOKI_DOMAIN#${LOKI_DOMAIN}#g"   -e "s#REPLACE_ME_MIMIR_DOMAIN#${MIMIR_DOMAIN}#g" \
  -e "s#REPLACE_ME_TEMPO_DOMAIN#${TEMPO_DOMAIN}#g" -e "s#REPLACE_ME_GRAFANA_DOMAIN#${GRAFANA_DOMAIN}#g" \
  -e "s#REPLACE_ME_STORAGE_CLASS#${STORAGE_CLASS}#g" \
  -e "s#REPLACE_ME_GATEWAY_NAMESPACE#${GATEWAY_NAMESPACE}#g" -e "s#REPLACE_ME_GATEWAY_NAME#${GATEWAY_NAME}#g" \
  $files
if [ -n "${REGISTRY:-}" ]; then   # 사설 미러: 이미지 경로의 docker.io/ 만 바꾼다 (digest는 그대로 — 미러에 digest 보존 복사 필요)
  sed -i -E "s#(image: )docker\.io/#\1${REGISTRY%/}/#g" $files
fi
sed -i "s|admin-password: \"REPLACE_ME\"|admin-password: \"${GRAFANA_ADMIN_PASSWORD}\"|" build/mgmt/03-grafana/secret.yaml
ca=$( { printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: mgmt-ca\n  namespace: monitoring\ndata:\n  ca.crt: |\n'
        sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' "$MGMT_CA_PEM" | sed 's/^/    /'; } )
for c in $CLUSTERS; do
  C=${c^^}
  for k in LOKI MIMIR TEMPO; do
    tv="${C}_${k}_TOKEN"
    sed -i "s|${k}_PUSH_TOKEN: \"REPLACE_ME\"|${k}_PUSH_TOKEN: \"${!tv}\"|" "build/$c/01-otel/secret.yaml"
  done
  for p in 01-loki:LOKI 02-mimir:MIMIR 04-tempo:TEMPO; do
    d=${p%%:*}; k=${p##*:}; hv="${C}_${k}_HASH"
    sed -i "s|^    REPLACE_ME_HTPASSWD_${C}\$|    ${!hv}|" "build/mgmt/$d/basicauth-middleware.yaml"
  done
  printf '%s\n' "$ca" > "build/$c/00-namespace/mgmt-ca.yaml"
done

# 3. 확인 — 남은 자리표시자(Grafana OAuth 선택 블록 제외)와 CA 파싱
left=$(grep -rnE '^[^#]*REPLACE_ME' --include='*.yaml' build | grep -vE 'REPLACE_ME_OAUTH|client_(id|secret) = "REPLACE_ME"' || true)
[ -z "$left" ] || { printf '%s\n' "$left"; echo "!! 위 자리표시자가 남아 있음 — env/secrets.env 확인" >&2; exit 1; }
for c in $CLUSTERS; do
  sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/s/^    //p' "build/$c/00-namespace/mgmt-ca.yaml" | openssl x509 -noout -subject >/dev/null \
    || { echo "!! CA ConfigMap 생성 실패: build/$c" >&2; exit 1; }
done
echo "렌더링 OK → build/mgmt build/dev build/stg build/prod  (CA: $(openssl x509 -in "$MGMT_CA_PEM" -noout -subject | sed 's/^subject=//'))"
if [ "$NEW_PW" = 1 ]; then
  echo "Grafana admin 비밀번호: $GRAFANA_ADMIN_PASSWORD   ← 비밀번호 관리 도구에 기록 (secrets.env에도 있음, 커밋 금지)"
fi
echo "다음: EXPECT_CONTEXT=<mgmt kube context> build/mgmt/install.sh"
