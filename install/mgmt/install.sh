#!/usr/bin/env bash
# mgmt 클러스터 설치: 중앙 Loki + Mimir + Tempo + Grafana, Traefik HTTPRoute + BasicAuth.
# 실행: EXPECT_CONTEXT=<mgmt kube context> build/mgmt/install.sh   ← 저장소 루트에서 ./configure.sh 로 만든 build/ 안에서 돈다
set -euo pipefail
cd "$(dirname "$0")"

# 대상 클러스터 확인 — 엉뚱한 클러스터에 설치하지 않도록 EXPECT_CONTEXT를 반드시 지정
: "${EXPECT_CONTEXT:?EXPECT_CONTEXT=<대상 kube context> install.sh 형태로 실행할 것}"
CTX=$(kubectl config current-context)
if [ "$CTX" != "$EXPECT_CONTEXT" ]; then
  echo "현재 context($CTX)가 EXPECT_CONTEXT($EXPECT_CONTEXT)와 다름 — 중단" >&2
  exit 1
fi
echo "대상 context: $CTX"

# 자리표시자가 남아 있으면(템플릿 폴더에서 직접 실행했거나 configure.sh를 안 거침) 아무것도 적용하지 않는다
# (Grafana OAuth 블록은 선택 기능이라 제외)
if grep -rnE '^[^#]*REPLACE_ME' --include='*.yaml' . | grep -vE 'REPLACE_ME_OAUTH|client_(id|secret) = "REPLACE_ME"'; then
  echo "위 REPLACE_ME 값이 남아 있음 — 저장소 루트에서 ./configure.sh 를 실행하고 build/mgmt/install.sh 를 쓸 것" >&2
  exit 1
fi
# 비밀값이 비어 있으면 중단
if grep -nE "^[[:space:]]*admin-password:[[:space:]]*[\"']?[[:space:]]*[\"']?[[:space:]]*\$" 03-grafana/secret.yaml \
   || grep -nE '^[[:space:]]*(dev|stg|prod):[[:space:]]*$' 01-loki/basicauth-middleware.yaml 02-mimir/basicauth-middleware.yaml 04-tempo/basicauth-middleware.yaml; then
  echo "위 비밀값(Grafana 비밀번호·BasicAuth 해시)이 비어 있음 — secrets.env 확인 후 ./configure.sh 재실행" >&2
  exit 1
fi
# 모든 이미지는 digest(@sha256)로 고정돼 있어야 한다 — 태그만 쓰면 레지스트리 태그가 바뀌었을 때 다른 이미지가 배포된다
if grep -rnE '^\s*image:' --include='*.yaml' . | grep -vE '@sha256:[0-9a-f]{64}\s*$'; then
  echo "위 이미지가 digest로 고정되지 않음" >&2
  exit 1
fi

echo "== 0. namespace =="
kubectl apply -f 00-namespace/namespace.yaml

echo "== 1. loki (중앙 로그 저장소 — dev/stg/prod가 push) =="
kubectl apply -f 01-loki/cm.yaml -f 01-loki/pvc.yaml -f 01-loki/svc.yaml -f 01-loki/deploy.yaml
kubectl rollout status deploy/loki -n monitoring --timeout=180s
kubectl apply -f 01-loki/basicauth-middleware.yaml -f 01-loki/route.yaml

echo "== 2. mimir (중앙 메트릭 저장소) =="
kubectl apply -f 02-mimir/cm.yaml -f 02-mimir/svc.yaml -f 02-mimir/sts.yaml
kubectl rollout status statefulset/mimir -n monitoring --timeout=180s
kubectl apply -f 02-mimir/basicauth-middleware.yaml -f 02-mimir/route.yaml

echo "== 3. tempo (중앙 트레이스 저장소) =="
kubectl apply -f 04-tempo/cm.yaml -f 04-tempo/svc.yaml -f 04-tempo/sts.yaml
kubectl rollout status statefulset/tempo -n monitoring --timeout=180s
kubectl apply -f 04-tempo/basicauth-middleware.yaml -f 04-tempo/route.yaml

echo "== 4. grafana =="
kubectl apply -f 03-grafana/sa.yaml -f 03-grafana/role.yaml -f 03-grafana/rolebinding.yaml
kubectl apply -f 03-grafana/pvc.yaml -f 03-grafana/secret.yaml -f 03-grafana/datasource-provisioning-cm.yaml
kubectl apply -f 03-grafana/svc.yaml -f 03-grafana/route.yaml
# deploy.yaml이 ConfigMap grafana-dashboards를 필수로 마운트하므로 Deployment보다 먼저 만든다.
# --server-side: 대시보드 JSON이 커서 client-side apply의 last-applied 어노테이션(256KiB 한도)에 안 들어갈 수 있다
echo "== 4-0. grafana 대시보드 ConfigMap (03-grafana/dashboards/*.json 전부) =="
kubectl -n monitoring create configmap grafana-dashboards --from-file=03-grafana/dashboards/ --dry-run=client -o yaml \
  | kubectl apply --server-side --force-conflicts -f -
kubectl apply -f 03-grafana/deploy.yaml
kubectl rollout status deploy/grafana -n monitoring --timeout=180s

echo
echo "== 완료: mgmt =="
echo "Route 4개가 Gateway에 붙었는지 (ACCEPTED, REFS 모두 True여야 한다. 방금 설치했다면 몇 초 뒤 다시):"
kubectl -n monitoring get httproute loki-push-route mimir-push-route tempo-push-route grafana-route \
  -o custom-columns='NAME:.metadata.name,HOSTS:.spec.hostnames[*],ACCEPTED:.status.parents[0].conditions[?(@.type=="Accepted")].status,REFS:.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status' || true
echo "다음: README '설치' 2단계의 push 경로 점검 → build/dev/install.sh"
