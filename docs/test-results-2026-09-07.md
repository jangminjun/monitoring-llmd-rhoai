# 실행 결과: 2026-09-07 (myocp 클러스터)

TC-01~05를 `LLMInferenceService qwen25-coder-7b` (ns `qwen25-coder-7b`) 대상으로 실제 클러스터에서
실행한 결과. 절차/기대결과 원문은 [test-cases.md](test-cases.md) 참고.

## TC-01. 관측성 스택 활성화 검증 — **통과**

`oc get dsci default-dsci -o yaml` 결과 `spec.monitoring.managementState: Managed`,
`namespace: redhat-ods-monitoring`. `openshift-user-workload-monitoring`(prometheus-user-workload-0/1,
thanos-ruler-user-workload-0/1)와 `openshift-monitoring`(alertmanager-main-0/1) 모두 Running.

## TC-02. llm-d 메트릭 수집 검증 — **통과 (vLLM 엔진 범위 한정)**

`oc get servicemonitor,podmonitor -n qwen25-coder-7b`로 컨트롤러 자동 생성 확인:
`kserve-llm-isvc-scheduler(-default)` ServiceMonitor, `kserve-llm-isvc-vllm-engine(-default)` PodMonitor.

Thanos-querier `up{namespace="qwen25-coder-7b"}` 조회 결과 두 PodMonitor job 모두 `up=1`.

메트릭 값 실측(부하 발생 후):
- `kserve_vllm:time_to_first_token_seconds_bucket` 기반 TTFT p95 = **0.387s** (임계값 2s 대비 정상)
- `kserve_vllm:request_success_total{finished_reason="stop"}` 증가 확인

**스코프 노트:** `llm-d.ai/role=both`(비분리 배포)라 라우터/스케줄러(EPP) pod가 없어
`kserve-llm-isvc-scheduler` ServiceMonitor는 매칭 타겟이 없음 — 결함 아님, prefill/decode 분리 배포 시에만
채워짐.

## TC-03. Grafana 대시보드 연결 검증 — **부분 통과 (쿼리 레벨)**

`grafana/llmd-dashboard.json`을 Grafana API(`POST /api/dashboards/db`)로 import 성공
(`uid=llmd-observability`, 데이터소스는 기존 등록된 `thanos-querier` 사용).

Grafana의 데이터소스 프록시(`/api/datasources/proxy/uid/<uid>/api/v1/query`)로 대시보드가 쓰는
쿼리를 직접 실행해 실데이터 반환 확인:
- TTFT p95 쿼리 → `0.3875`
- Throughput 쿼리 → `0.006 req/s` (테스트 트래픽 기준)

**한계:** 패널이 브라우저에서 실제로 정상 렌더링되는지(레이아웃, 갱신 주기 등)는 CLI로 검증할 수 없음 —
`https://gpu-grafana-route-gpu-monitoring.apps.myocp.sandbox623.opentlc.com/d/llmd-observability/`에서
사용자 육안 확인 필요.

## TC-04. 실시간 모니터링 검증 (TTFT·처리량·에러율) — **통과, 단 에러율 지표 재정의**

1. 정상 요청 8회 전송 (직접 `qwen25-coder-7b-kserve-workload-svc:8000`로, `oc port-forward` 경유) →
   전부 HTTP 200, TTFT/처리량 지표에 반영됨 (`finished_reason="stop"` 카운트 증가, TTFT p95 0.387s).
2. 오류 유발 시도 — **원래 가정이 틀렸음을 실측으로 확인**:
   - 존재하지 않는 모델명 → HTTP 404 (게이트웨이/라우팅 레벨에서 거부, vLLM 엔진 메트릭에 안 잡힘)
   - 컨텍스트 초과(16385 > max_model_len 16384) → HTTP 400
   - 잘못된 sampling 파라미터(`n:-1`) → HTTP 400
   - 위 요청들은 `kserve_vllm:request_success_total{finished_reason="error"}`를 **증가시키지 않음**
     (엔진 생성 루프에 진입하지 못하고 요청 검증 단계에서 거부됨). 대신
     `kserve_http_requests_total{status="4xx"}`로 정확히 카운트됨 (실측: 5xx 요청 시도 후 `status="4xx"` 5건 증가).
3. 결론: 에러율 알림/대시보드는 `finished_reason="error"`가 아니라 **`kserve_http_requests_total`의
   `status` 라벨**을 기준으로 계산해야 한다 — `manifests/prometheusrule-llmd-alerts.yaml`,
   `grafana/llmd-dashboard.json`을 이 기준으로 수정 완료.

## TC-05. 임계값 초과 알림 검증 (TTFT + 에러율) — 아래 참고

`manifests/prometheusrule-llmd-alerts.yaml`(수정본)을 `qwen25-coder-7b` ns에 적용 완료
(`oc apply -f manifests/prometheusrule-llmd-alerts.yaml`).

**통과.** 오류(4xx, `n:-1`) 요청 40건을 버스트로 발생시켜 `kserve_http_requests_total{status=~"4xx|5xx"}`
기준 에러율을 순간 **93.1%**까지 올린 뒤(정상 5% 임계값 대비 압도적 초과), 30초 간격으로
`ALERTS{alertname="LLMDHighErrorRate", namespace="qwen25-coder-7b"}`를 관찰함. 첫 시도(별도 포트포워딩
세션)는 터널이 조용히 안 붙어 모든 요청이 `HTTP 000`으로 실패해 에러율이 0%로 나왔음 — 재시도로 연결을
`Forwarding from` 로그 + 사전 curl 검증까지 확인한 뒤 버스트를 재실행해 아래 결과를 얻음
(자세한 원인/교훈은 [lessonlearn.md](../lessonlearn.md) 참고).

| 시각(KST) | `alertstate` |
|---|---|
| 16:25:51 ~ 16:28:56 | `pending` (조건은 true, `for: 5m` 대기 중) |
| **16:29:27** | **`firing`** — 조건이 5분 이상 지속돼 알림 발생 확인 |
| 16:29:58 이후 | 결과 없음 (`resolved`) — 버스트 종료 후 5분 rate window가 정상 트래픽으로 희석되며 자동 해제 |

임계값 초과 → firing → 정상화 후 자동 resolved까지 전체 알림 생명주기를 실측으로 확인함.

**범위 제한:** 이 클러스터엔 `qwen25-coder-7b` ns용 `AlertmanagerConfig`(Slack/이메일 라우팅)가 없어
Alertmanager 자체의 firing 여부까지만 검증했고, 실제 채널 전달은 검증 범위 밖(후속 과제).

## 종합

- TC-01, TC-02(vLLM 엔진 범위), TC-04, TC-05 모두 실측으로 **통과** 확인.
- TC-03은 쿼리 레벨 통과, 브라우저 렌더링은 사용자 확인 필요.
- 가장 중요한 발견: 원래 문서가 가정한 `vllm:*` 메트릭명과 별도 실패 카운터는 이 클러스터의 실제
  llm-d(KServe LLMInferenceService) 배포와 맞지 않았고, 실제로는 `kserve_vllm:*` 접두사 +
  `kserve_http_requests_total{status=...}` 기반 에러율 계산이 정확하다는 것을 실측으로 확인함.
- 전체 알림 생명주기(정상 → 임계값 초과 → pending → firing → 정상화 → resolved)를 실제 클러스터에서
  end-to-end로 재현·검증함.
