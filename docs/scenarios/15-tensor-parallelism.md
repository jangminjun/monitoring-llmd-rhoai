# 시나리오 15: 텐서 병렬화 (Tensor Parallelism) — 계획 (미구현)

**모듈:** 분산 환경 활용 > 병렬화 전략
**상태:** 문서만 존재, 하네스 스크립트 없음 — 아래 사전 조건이 충족되면 구현

## 목적

모델 레이어(가중치)를 GPU 여러 장에 쪼개서(`--tensor-parallel-size N`) 서빙했을 때의 지연/처리량을
단일 GPU 대비 비교한다. TP는 GPU간 NCCL 통신이 필요해서 **데이터 병렬화(시나리오 11)와 달리 여러
노드에 자유롭게 흩어놓을 수 없다** — 보통 같은 노드 내 여러 GPU, 또는 고속 인터커넥트(NVLink/RDMA)로
묶인 노드가 필요하다.

## 왜 지금 못 하나

우리 클러스터(`openshift-aws-harness` 기본 구성)는 GPU가 **노드당 1장**(g5.2xlarge, g6.2xlarge)이다.
TP를 검증하려면 다음 중 하나가 필요:

1. 멀티GPU 인스턴스 1대 (예: `g5.12xlarge` = A10G 4장, 같은 호스트) — 가장 간단, RDMA 불필요
2. RDMA/EFA 지원 인스턴스로 멀티노드 TP (예: `p4d.24xlarge` 계열) — 진짜 분산 TP지만 훨씬 비쌈

## 사전 조건 (구현 시)

```sh
# 멀티GPU 노드 추가 (harness에 이미 있는 gpu-machineset 재사용)
GPU_INSTANCE_TYPE=g5.12xlarge GPU_REPLICAS=1 ./harness.sh gpu-machineset
```

- `LLMInferenceService`의 `spec.template.containers[].resources.limits."nvidia.com/gpu"`를 4로,
  `VLLM_ADDITIONAL_ARGS`에 `--tensor-parallel-size=4` 추가
- 모델은 4-way TP로 나눌만한 크기(예: Qwen3.6-27B급)가 적합 — 너무 작은 모델은 TP 오버헤드만 커짐

## 예상 검증 항목

- TP=1 vs TP=4일 때 같은 모델(가능하면) 또는 TP 없이는 못 올라가던 큰 모델의 TTFT/처리량 비교
- GPU간 NCCL 통신이 지연에 기여하는 비율 (연구 자료상 all-to-all 통신이 병목이 될 수 있음 — MoE만큼
  크진 않지만 TP도 all-reduce 오버헤드가 있음)

## 실측 결과

_(미착수 — 멀티GPU 노드 배포 결정 후 진행)_
