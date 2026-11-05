# dev — otel-collector + Istio 트레이싱 overlay

저장소(Loki·Mimir·Tempo·Grafana)는 전부 mgmt에 있다. 이 클러스터는 수집만 한다.
전체 순서는 `../../README.md`. 이 폴더는 **템플릿**이라 `REPLACE_ME_*`가 남아 있고, 루트의 `configure.sh`가 `build/dev/`에 채운 사본을 만든다.
dev / stg / prod 폴더는 `CLUSTER_NAME`(`dev`)만 다르다.

## 하는 일

| 구성 요소 | 역할 |
|---|---|
| `01-otel/daemonset.yaml` otel-collector (노드마다) | (1) `/var/log/pods` 앱 로그 tail → mgmt Loki (2) `prometheus.io/scrape` 파드(Istio 사이드카 포함) 스크레이프 → mgmt Mimir (3) 자기 노드 kubelet의 노드·파드·컨테이너 사용량(`kubeletstats`) → Mimir (4) Envoy zipkin(:9411)·OTLP 스팬 수신 → mgmt Tempo |
| `01-otel/cluster.yaml` otel-cluster (1개) | 파드 phase·재시작·대기 사유·노드 condition·request/limit(`k8s_cluster`) → Mimir, 쿠버네티스 이벤트(`k8s_objects`) → Loki `{cluster="dev", app="k8s-events"}` |
| `02-istio/operator.yaml` | 기존 IstioOperator 위에 덧씌우는 overlay — zipkin provider를 `otel-collector.monitoring.svc.cluster.local:9411`로 |
| `02-istio/telemetry-sampling.yaml` | Istio 표준 메트릭 켬(`metrics: prometheus`) + 트레이스 샘플링 비율(기본 100%) |
| `00-namespace/mgmt-ca.yaml` | mgmt 서버 인증서를 검증할 CA (configure.sh가 `env`의 `MGMT_CA_PEM`으로 채움) |
| `01-otel/secret.yaml` | push 토큰 3개 **평문** (configure.sh가 `secrets.env`에서 채움. mgmt `users`에 넣는 해시가 아니다) |

로그 수집 범위: 앱 로그만. `kube-system`·`monitoring`·`istio-system`과 사이드카(`istio-proxy`, `istio-init`) 로그는 제외한다
(`01-otel/cm.yaml`의 `file_log.exclude`).

## 사전 조건

- mgmt가 먼저 설치돼 있고 `../../README.md` 2단계의 `chk` 점검에서 이 클러스터 토큰이 통과함
- Istio 컨트롤플레인 설치됨 + 설치에 쓴 IstioOperator 파일 + 같은 버전 `istioctl`
- 앱 네임스페이스에 `istio-injection: enabled`, 앱 파드에 `app` 라벨
- otel은 GID 0(UID 65534)으로 뜬다. `/var/log/pods`가 750으로 잠긴 노드가 많아서다

## 설치

`../../README.md` 설치 3단계 블록을 `C=dev` 값으로 실행한다. 블록이 `build/dev/install.sh` → Istio overlay → 샘플링 설정 → 앱 파드 재시작까지 한다.
`install.sh`만 따로 돌릴 때:

```bash
EXPECT_CONTEXT=<dev kube context> build/dev/install.sh
```

`install.sh`는 CA ConfigMap이나 토큰 Secret이 바뀌었으면(`configured`) 마지막에 otel을 재시작한다. 떠 있는 파드는 바뀐 Secret을 다시 읽지 않기 때문이다.

## 검증

전송 실패 카운터가 0인지 — 파드마다 확인한다. mgmt 인증·TLS·도메인 문제는 여기서 바로 보인다.

```bash
pods=$(kubectl -n monitoring get pod -l 'app.kubernetes.io/name in (otel-collector,otel-cluster)' -o name) && [ -n "$pods" ] \
  || echo "!! otel 파드 목록을 못 받음 — context·네임스페이스 확인"
for p in $pods; do
  kubectl -n monitoring port-forward "$p" 18888:8888 >/dev/null 2>&1 & pf=$!; sleep 2
  echo "$p"; curl -sf localhost:18888/metrics | grep -E '^otelcol_exporter_(sent|send_failed|queue_size)' || echo "  !! $p 메트릭을 못 읽음"
  kill $pf 2>/dev/null; wait $pf 2>/dev/null
done
```

- 1분 뒤 한 번 더 실행해 `sent_*`가 늘었는지 본다. otel-cluster의 `sent_log_records`는 쿠버네티스 이벤트라 조용한 클러스터에서는 안 늘 수 있다(정상).
- `kubectl -n monitoring get pods` — otel-collector는 노드 수만큼, otel-cluster는 1개 Running
- mgmt Grafana → Explore → Loki `{cluster="dev"}`, Mimir `istio_requests_total{cluster="dev"}`, Tempo `{ resource.cluster = "dev" }`

## 조정

- **샘플링:** `02-istio/telemetry-sampling.yaml`의 `randomSamplingPercentage`. 트래픽 대비 Tempo 저장량이 과하면 낮춘다.
  트레이스 건수와 저장량만 줄고, 메트릭 기반 패널(서비스 그래프·RED)은 모든 요청을 센다. 바꾸면 apply만 하면 된다(재시작 불필요).
- **리소스:** otel-collector는 CPU 25m 요청 / 메모리 limit 512Mi(memory_limiter 80%). 로그량이 많은 노드는 `01-otel/daemonset.yaml`에서 올린다.
- **토큰 교체:** `../../README.md` 운영 절. 이 클러스터 `install.sh`가 Secret 변경을 감지해 재시작까지 한다.
