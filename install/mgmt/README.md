# mgmt — 중앙 Loki · Mimir · Tempo · Grafana

dev / stg / prod의 otel이 push하는 로그·메트릭·트레이스를 받아 저장하고, Grafana에서 조회한다.
전체 순서는 `../../README.md`. 이 폴더는 **템플릿**이라 `REPLACE_ME_*`가 남아 있고, 루트의 `configure.sh`가 `build/mgmt/`에 채운 사본을 만든다.

## 구성

| 폴더 | 내용 |
|---|---|
| `00-namespace/` | `monitoring` 네임스페이스 |
| `01-loki/` | Loki 3.5 단일 바이너리(Deployment, PVC 100Gi, 보존 15일) + HTTPRoute `/otlp` + BasicAuth Middleware |
| `02-mimir/` | Mimir 2.11 모놀리식(StatefulSet, PVC 100Gi, 보존 15일) + HTTPRoute `/api/v1/push` + BasicAuth |
| `04-tempo/` | Tempo 2.6 단일 바이너리(StatefulSet, PVC 100Gi, 보존 15일) + HTTPRoute `/v1/traces` + BasicAuth |
| `03-grafana/` | Grafana 11.5(Deployment, PVC 30Gi), 데이터소스 3개(Loki·Mimir·Tempo, readOnly)와 대시보드 2개 프로비저닝, HTTPRoute `/` |
| `install.sh` | 위 순서대로 apply. `REPLACE_ME`·빈 비밀값·digest 미고정이 있으면 아무것도 적용하지 않는다 |

Loki·Mimir는 단일 테넌트(`auth_enabled: false`, `multitenancy_enabled: false`)다. 클러스터 구분은 otel이 붙이는 `cluster` 라벨로 한다.
Mimir는 시리즈당 라벨 30개 제한이 있어서 otel 쪽에서 Istio 라벨 6개를 떼고 보낸다.

## BasicAuth — 토큰과 해시

| 파일 | `users` 내용 |
|---|---|
| `01-loki/basicauth-middleware.yaml` | `dev:<해시>` `stg:<해시>` `prod:<해시>` — 각 클러스터 `LOKI_PUSH_TOKEN`의 해시 |
| `02-mimir/basicauth-middleware.yaml` | 같은 구조, `MIMIR_PUSH_TOKEN` |
| `04-tempo/basicauth-middleware.yaml` | 같은 구조, `TEMPO_PUSH_TOKEN` |

사용자명은 각 클러스터 otel의 `CLUSTER_NAME`과 같아야 한다. 해시는 bcrypt(`$2y$`, htpasswd)나 apr1(`$apr1$`, openssl)이고
`configure.sh`가 `secrets.env`의 토큰에서 만든다. 평문 토큰이나 따옴표가 든 줄이 들어가면 Traefik이 그 Middleware를 만들지 못해
Route 자체가 사라지고 otel에는 404로 보인다 — 손으로 넣지 말 것.

## Grafana

- admin 비밀번호: `secrets.env`의 `GRAFANA_ADMIN_PASSWORD` (`03-grafana/secret.yaml`로 들어간다). 잃어버렸으면 그 줄을 지우고
  `configure.sh` → `install.sh` → `kubectl -n monitoring rollout restart deploy/grafana`.
- 대시보드는 `03-grafana/dashboards/*.json`을 `install.sh`가 ConfigMap `grafana-dashboards`로 만들어 마운트한다. UI에서 저장은 막혀 있다
  (`allowUiUpdates: false`). 고치려면 JSON을 바꾸고 `install.sh`를 다시 돌린 뒤 Grafana를 재시작한다.
- 홈 대시보드는 "서비스 메시 개요"(uid `mesh-service-graph`). Mimir 데이터소스에 `timeInterval: 1m`를 줬다(스크레이프 간격과 맞춤).
- OAuth 블록(`datasource-provisioning-cm.yaml`의 grafana.ini)은 기본 꺼져 있다. 쓰려면 `enabled = true`로 바꾸고 `REPLACE_ME_OAUTH_*`를 채운다.

## 확인

```bash
kubectl -n monitoring get pods
kubectl -n monitoring get httproute      # 4개 모두 Accepted/ResolvedRefs True
kubectl exec -n monitoring deploy/grafana -- wget -qO- "http://mimir.monitoring.svc.cluster.local:9009/prometheus/api/v1/query?query=up"
kubectl exec -n monitoring deploy/grafana -- wget -qO- "http://loki.monitoring.svc.cluster.local:3100/ready"
```

push 경로를 토큰으로 점검하는 `chk` 블록은 `../../README.md` 설치 2단계에 있다.

## 운영 메모

- 전부 단일 replica + PVC다. mgmt가 멈춘 동안 조회는 안 되지만, otel이 버퍼링하므로 1시간 이내 장애는 유실이 없다.
  노드가 죽으면 RWO PVC 때문에 파드가 자동으로 옮겨가지 않는다. 노드가 정말 죽었는지 확인한 뒤
  `kubectl taint nodes <노드> node.kubernetes.io/out-of-service=nodeshutdown:NoExecute`로 정리한다.
- PVC 크기는 StatefulSet의 `volumeClaimTemplates`라 바꿔서 다시 apply하면 거부된다. 키우려면 PVC를 직접 수정하고(확장 지원 StorageClass)
  StatefulSet은 `--cascade=orphan`으로 지웠다가 다시 만든다.
- 보존 기간은 각 `cm.yaml`(Loki compactor retention, Mimir `compactor_blocks_retention_period`, Tempo `block_retention`)에 있다.
