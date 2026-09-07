# monitoring-llmd-rhoai

OpenShift AI(RHOAI) + llm-d 관측성(Observability) 검증을 위한 QA 테스트케이스 및 실행 리소스 모음.

## 배경

OpenShift AI는 Prometheus·Tempo·Alertmanager 기반의 사전 구성 관측 스택을 제공하며,
llm-d 컴포넌트(EPP, vLLM pod, prefix cache)의 메트릭을 PromQL로 조회할 수 있습니다.
이 저장소는 해당 스택을 활성화하고 llm-d 메트릭을 수집·시각화·알림하는 과정을
QA 테스트케이스로 문서화하고, 바로 적용 가능한 매니페스트로 재현합니다.

## 시나리오

```
관측성 스택 활성화 → llm-d 메트릭 수집 → Grafana 대시보드 연결
→ TTFT·처리량·에러율 실시간 모니터링 → 임계값 초과 알림
```

## 사전 조건

- OCP 4.19.9+
- OpenShift AI Operator
- Cluster Observability Operator(COO)
- Red Hat Build of OpenTelemetry Operator
- Tempo Operator
- llm-d 스택 배포 완료 (EPP, vLLM pod, prefix cache)

## 디렉터리 구조

```
docs/
  test-cases.md          QA 테스트케이스 (TC-01 ~ TC-05)
manifests/
  dsci-observability-patch.yaml   관측성 스택 활성화용 DSCI CR 패치 예시
  servicemonitor-llmd.yaml        llm-d 컴포넌트 메트릭 스크랩 설정
  prometheusrule-llmd-alerts.yaml TTFT/에러율 임계값 알림 규칙
grafana/
  llmd-dashboard.json     TTFT·처리량·에러율 대시보드
```

## 임계값 (가정치, SLO 확정 전)

| 지표 | 임계값 | 지속시간 |
|---|---|---|
| TTFT (p95) | > 2초 | 5분 |
| 에러율 | > 5% | 5분 |

> 실제 서비스 SLO가 확정되면 `manifests/prometheusrule-llmd-alerts.yaml`의 값을 갱신하세요.
