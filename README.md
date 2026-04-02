# Kubernetes LGTM Stack (Loki, Grafana, Tempo, Mimir)

이 프로젝트는 Kubernetes 환경에서 현대적인 관측성(Observability) 스택인 **LGTM** 스택을 구축하기 위한 매니페스트 모음입니다. 데이터 수집은 **OpenTelemetry (OTel) Collector**를 통해 통합 관리됩니다.

## 🏗️ Architecture

- **Loki**: 로그 데이터 저장 및 질의 (Logs)
- **Grafana**: 통합 시각화 대시보드 (Visualization)
- **Tempo**: 분산 트레이싱 데이터 저장 (Traces)
- **Mimir**: 장기 보관 시스템 메트릭 저장 (Metrics)
- **OTel Collector**: 노드/팟 데이터 통합 수집 및 전송 (Collector)
- **Storage**: NFS CSI 드라이버를 기반으로 한 안정적인 퍼시스턴트 스토리지

## 📂 Directory Structure

```text
/home/rocky/kubernetes_lgtm/
├── namespace.yaml      # observability 네임스페이스 생성
├── grafana/           # 시각화 도구 및 대시보드 설정
├── loki/              # 로그 관리 시스템
├── mimir/             # 메트릭 관리 시스템
├── tempo/             # 트레이싱 관리 시스템
└── otel/              # 데이터 통합 에이전트 (DaemonSet)
```

## 🚀 Quick Start

> [!IMPORTANT]
> **설치 전 필수 확인 사항 (NAS & Storage)**
> 1. **NAS 서버 구성**: 먼저 NFS 서버(NAS)가 설치되어 있어야 하며, `/mnt/nfs/lgtm` 경로가 마운트 가능하도록 익스포트되어 있어야 합니다.
> 2. **StorageClass 설정**: 각 구성 요소(`loki`, `mimir`, `tempo`, `grafana`) 폴더 내의 `sc.yaml` 파일을 열어 `server: [IP_ADDRESS]` 부분을 실제 NAS 서버의 IP 주소로 수정해야 합니다.

### 설치 순서
아래 순서대로 적용하는 것을 권장합니다.

```bash
# 네임스페이스 생성
kubectl apply -f namespace.yaml

# 개별 구성 요소 설치 (StorageClass, Service, Deployment/StatefulSet)
kubectl apply -f loki/
kubectl apply -f mimir/
kubectl apply -f tempo/
kubectl apply -f grafana/

# OTel Collector 설치 (Ingestion)
kubectl apply -f otel/
```

### 3. 접속 정보
- **Grafana 접속**: [http://grafana.sample.nip.io](http://grafana.sample.nip.io) (Ingress 설정 필요)
- **기본 계정**: `admin` / `admin`
<img width="1917" height="918" alt="스크린샷 2026-04-02 143211" src="https://github.com/user-attachments/assets/4732b624-b02a-417b-9da9-b5fa2a054dc6" />
<img width="1917" height="918" alt="스크린샷 2026-04-02 143246" src="https://github.com/user-attachments/assets/c48bf2d3-57c7-4757-b0d3-75c3b9693b58" />
<img width="1919" height="920" alt="스크린샷 2026-04-02 143303" src="https://github.com/user-attachments/assets/367c9cdb-12aa-4f47-b96c-b5d68a97356b" />

## 📊 Monitoring Features
- **Node Metrics**: CPU, Memory, Disk, Network 상태 모니터링
- **Pod Metrics**: Kubeletstats 기반 실시간 리소스 사용량 추적
- **Integrated Logs**: Loki를 통한 실시간 로그 조회 및 에러 필터링
- **Distributed Traces**: Tempo와 연동된 지연 시간(Latency) 분석용 트레이싱 데이터 지원 (OTLP 기반)

## 🛠️ Verification
배포 후 수집 상태를 확인하려면 다음 명령어를 사용하세요.

```bash
# 전체 파드 상태 확인
kubectl -n observability get pods

# OTel 컬렉터 로그 확인
kubectl -n observability logs -l app.kubernetes.io/name=otel-collector -f
```
