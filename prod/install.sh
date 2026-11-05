#!/usr/bin/env bash
# prod 클러스터 설치: otel-collector(DaemonSet) + otel-cluster(Deployment). 로그·메트릭·트레이스를 mgmt로 push한다.
# 실행: EXPECT_CONTEXT=<prod kube context> build/prod/install.sh   ← 저장소 루트에서 ./configure.sh 로 만든 build/ 안에서 돈다
# Istio 트레이싱 overlay(02-istio/)는 기존 IstioOperator 파일이 필요해서 이 스크립트가 하지 않는다 — 끝에 출력되는 명령을 따른다.
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
if grep -rnE '^[^#]*REPLACE_ME' --include='*.yaml' .; then
  echo "위 REPLACE_ME 값이 남아 있음 — 저장소 루트에서 ./configure.sh 를 실행하고 build/prod/install.sh 를 쓸 것" >&2
  exit 1
fi
# 토큰이 비어 있으면 중단 (빈 토큰은 설치 후 401로만 드러난다)
if grep -nE "^[[:space:]]*(LOKI|MIMIR|TEMPO)_PUSH_TOKEN:[[:space:]]*[\"']?[[:space:]]*[\"']?[[:space:]]*\$" 01-otel/secret.yaml; then
  echo "위 토큰이 비어 있음 — secrets.env 확인 후 ./configure.sh 재실행" >&2
  exit 1
fi
# 모든 이미지는 digest(@sha256)로 고정돼 있어야 한다
if grep -rnE '^\s*image:' --include='*.yaml' . | grep -vE '@sha256:[0-9a-f]{64}\s*$'; then
  echo "위 이미지가 digest로 고정되지 않음" >&2
  exit 1
fi

echo "== 0. namespace + mgmt CA + push 토큰 Secret =="
kubectl apply -f 00-namespace/namespace.yaml
# 떠 있는 파드는 Secret·ConfigMap이 바뀌어도 다시 읽지 않는다 → 바뀐 경우(configured) 마지막에 재시작한다
out=$(kubectl apply -f 00-namespace/mgmt-ca.yaml -f 01-otel/secret.yaml); printf '%s\n' "$out"
RESTART=0; printf '%s\n' "$out" | grep -q ' configured$' && RESTART=1

echo "== 1. otel-collector (DaemonSet — 앱 로그·Istio 메트릭·kubelet 사용량·트레이스) =="
kubectl apply -f 01-otel/sa.yaml -f 01-otel/rbac.yaml -f 01-otel/cm.yaml -f 01-otel/svc.yaml -f 01-otel/daemonset.yaml
kubectl rollout status daemonset/otel-collector -n monitoring --timeout=180s

echo "== 2. otel-cluster (Deployment 1개 — 파드 상태·재시작·쿠버네티스 이벤트) =="
kubectl apply -f 01-otel/cluster.yaml
kubectl rollout status deployment/otel-cluster -n monitoring --timeout=180s

if [ "$RESTART" = 1 ]; then
  echo "== 3. CA 또는 토큰이 바뀌어 otel 재시작 =="
  kubectl -n monitoring rollout restart daemonset/otel-collector deployment/otel-cluster
  kubectl rollout status daemonset/otel-collector -n monitoring --timeout=180s
  kubectl rollout status deployment/otel-cluster -n monitoring --timeout=180s
fi

echo
echo "== 완료: prod otel =="
echo "다음(Istio 트레이싱 overlay — 반드시 기존 IstioOperator 파일 뒤에 붙여서. 단독 실행하면 기존 설정이 기본값으로 덮인다):"
echo "  istioctl install -f <기존 IstioOperator.yaml> -f $(pwd)/02-istio/operator.yaml -y"
echo "  kubectl apply -f $(pwd)/02-istio/telemetry-sampling.yaml"
echo "  kubectl -n <앱 네임스페이스> rollout restart deploy      # 사이드카가 새 설정을 받도록"
echo "검증: README '검증' 표. 전송 실패 카운터는 이 폴더 README의 루프로 확인"
