# QA 테스트케이스: OpenShift AI + llm-d 관측성

**모듈:** 모니터링/평가 > 중앙 집중식 플랫폼 관측성
**관련 컴포넌트:** OpenShift AI Operator, COO, RHBO(OpenTelemetry Operator), Tempo Operator, Prometheus 스택 / OCP 4.19.9+

---

## TC-01. 관측성 스택 활성화 검증

| 항목 | 내용 |
|---|---|
| 사전조건 | OpenShift AI Operator 설치 완료, DSCI CR 접근 권한 확보 |
| 절차 | 1) `manifests/dsci-observability-patch.yaml` 기준으로 DSCI CR의 monitoring 필드를 `Managed`로 설정<br>2) CR 적용 후 관련 Operand(Prometheus, Alertmanager, Tempo) 배포 확인 |
| 기대결과 | prometheus-*, alertmanager-*, tempo-* Pod가 Running 상태이며 DSCI status의 관련 condition이 `True`/`Ready` |
| 우선순위 | High |

## TC-02. llm-d 메트릭 수집 검증

| 항목 | 내용 |
|---|---|
| 사전조건 | TC-01 완료, llm-d(EPP, vLLM pod, prefix cache) 배포 완료 |
| 절차 | 1) `manifests/servicemonitor-llmd.yaml` 적용<br>2) Prometheus Targets UI에서 `up{job=~"vllm.*\|epp.*"}` 값 확인<br>3) PromQL로 핵심 메트릭 조회 (`vllm:time_to_first_token_seconds_bucket`, `vllm:request_success_total`, `vllm:request_failure_total`) |
| 기대결과 | 모든 llm-d 타겟이 `up=1`, 메트릭 값이 0이 아닌 실측치로 수집됨 |
| 우선순위 | High |

## TC-03. Grafana 대시보드 연결 검증

| 항목 | 내용 |
|---|---|
| 사전조건 | TC-02 완료 |
| 절차 | 1) Grafana에 Prometheus/Tempo 데이터소스 등록<br>2) `grafana/llmd-dashboard.json` import |
| 기대결과 | TTFT, 처리량, 에러율 패널에 실데이터 표시, 패널 갱신 주기(15~30초) 내 정상 갱신 |
| 우선순위 | Medium |

## TC-04. 실시간 모니터링 검증 (TTFT·처리량·에러율)

| 항목 | 내용 |
|---|---|
| 사전조건 | TC-03 완료, 부하 생성 도구(k6/locust 등) 준비 |
| 절차 | 1) 정상 부하로 추론 요청 발생<br>2) 부하를 단계적으로 증가시키며 대시보드 관찰<br>3) 의도적으로 실패 요청(잘못된 payload 등) 주입 |
| 기대결과 | 부하 증가에 따라 TTFT·처리량 지표가 지연 없이 반영, 실패 요청 발생 시 에러율 지표 상승 확인 |
| 우선순위 | High |

## TC-05. 임계값 초과 알림 검증 (TTFT + 에러율)

| 항목 | 내용 |
|---|---|
| 사전조건 | TC-04 완료, Alertmanager 알림 채널(Slack/이메일 등) 연동 |
| 알림 규칙 | `manifests/prometheusrule-llmd-alerts.yaml` 참고<br>- **TTFT**: p95 > 2초가 5분 이상 지속<br>- **에러율**: 실패율 > 5%가 5분 이상 지속 |
| 절차 | 1) PrometheusRule 적용<br>2) 부하 과다 또는 pod 강제 재시작으로 임계값 초과 상황 유발<br>3) 알림 발생 확인<br>4) 정상화 후 resolved 알림 확인 |
| 기대결과 | 임계값 초과 시 alert firing, 정상화 시 알림 자동 resolved. 알림 채널에 정상 전달 |
| 우선순위 | High |

---

## 참고: 임계값 (가정치)

실제 서비스 SLO가 확정되지 않아 아래는 초기 가정치입니다. 확정되는 대로 본 문서와
`manifests/prometheusrule-llmd-alerts.yaml`을 함께 갱신해야 합니다.

| 지표 | 임계값 | 지속시간 |
|---|---|---|
| TTFT (p95) | > 2초 | 5분 |
| 에러율 | > 5% | 5분 |

## 향후 확장 후보 (TC-06+)

- 처리량(throughput) 단독 임계값 알림
- GPU 사용률/메모리 지표 (vLLM 큐 길이, GPU 메모리)
- Tempo 분산 트레이싱과 메트릭 간 상관관계(trace-to-metrics) 검증
- 3rd party 관측 도구(Grafana Cloud, Datadog) remote_write 연동
