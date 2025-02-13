/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "velox/experimental/wave/exec/ExprKernel.h"

#include <gflags/gflags.h>
#include "velox/experimental/wave/common/Block.cuh"
#include "velox/experimental/wave/common/CudaUtil.cuh"
#include "velox/experimental/wave/exec/Aggregate.cuh"
#include "velox/experimental/wave/exec/ExprKernelStream.h"
#include "velox/experimental/wave/exec/WaveCore.cuh"

DEFINE_bool(kernel_gdb, false, "Run kernels sequentially for debugging");

namespace facebook::velox::wave {

#define BINARY_TYPES(opCode, TP, OP)                         \
  case opCode:                                               \
    binaryOpKernel<TP>(                                      \
        [](auto left, auto right) { return left OP right; }, \
        instruction->_.binary,                               \
        operands,                                            \
        blockBase,                                           \
        &shared->data,                                       \
        laneStatus);                                         \
    break;

__global__ void oneAggregate(KernelParams params, int32_t pc, int32_t base) {
  PROGRAM_PREAMBLE(base);
  aggregateKernel(instruction[pc]._.aggregate, shared, laneStatus);
  PROGRAM_EPILOGUE();
}

__global__ void oneReadAggregate(KernelParams params, int32_t pc, int32_t base);

__global__ void onePlusBigint(KernelParams params, int32_t pc, int32_t base);
template <typename T>
__global__ void oneLt(KernelParams params, int32_t pc, int32_t base) {
  PROGRAM_PREAMBLE(base);
  binaryOpKernel<T>(
      [](auto left, auto right) { return left < right; },
      instruction[pc]._.binary,
      operands,
      blockBase,
      &shared->data,
      laneStatus);
  PROGRAM_EPILOGUE();
}

__global__ void oneFilter(KernelParams params, int32_t pc, int32_t base);

__global__ void waveBaseKernel(KernelParams params) {
  PROGRAM_PREAMBLE(0);
  for (;;) {
    switch (instruction->opCode) {
      case OpCode::kReturn:
        PROGRAM_EPILOGUE();
        return;

      case OpCode::kFilter:
        filterKernel(
            instruction->_.filter, operands, blockBase, shared, laneStatus);
        break;

      case OpCode::kWrap:
        wrapKernel(
            instruction->_.wrap,
            operands,
            blockBase,
            shared->numRows,
            &shared->data);
        break;
      case OpCode::kAggregate:
        aggregateKernel(instruction->_.aggregate, shared, laneStatus);
        break;
      case OpCode::kReadAggregate:
        readAggregateKernel(&instruction->_.aggregate, shared);
        break;
        BINARY_TYPES(OpCode::kPlus_BIGINT, int64_t, +);
        BINARY_TYPES(OpCode::kLT_BIGINT, int64_t, <);
    }
    ++instruction;
  }
}

int32_t instructionSharedMemory(const Instruction& instruction) {
  switch (instruction.opCode) {
    case OpCode::kFilter:
      return sizeof(WaveShared) +
          (2 + (kBlockSize / kWarpThreads)) * sizeof(int32_t);
    default:
      return sizeof(WaveShared);
  }
}

#define CALL_ONE(k, params, pc, base)                          \
  {                                                            \
    k<<<blocksPerExe,                                          \
        kBlockSize,                                            \
        sharedSize,                                            \
        alias ? alias->stream()->stream : stream()->stream>>>( \
        params, pc, base);                                     \
    CUDA_CHECK(cudaGetLastError());                            \
  };

void WaveKernelStream::callOne(
    Stream* alias,
    int32_t numBlocks,
    int32_t sharedSize,
    KernelParams& params) {
  int32_t blocksPerExe = 0;
  auto first = params.programIdx[0];
  for (; blocksPerExe < numBlocks; ++blocksPerExe) {
    if (params.programIdx[blocksPerExe] != first) {
      break;
    }
  }
  std::vector<std::vector<OpCode>> programs;
  for (auto i = 0; i < numBlocks; i += blocksPerExe) {
    auto programIdx = programs.size();
    programs.emplace_back();
    auto* instructions = params.programs[programIdx]->instructions;
    for (auto pc = 0; instructions[pc].opCode != OpCode::kReturn; ++pc) {
      programs.back().push_back(instructions[pc].opCode);
    }
  }
  auto initialStartPC = params.startPC;
  for (auto programIdx = 0; programIdx < programs.size(); ++programIdx) {
    auto& program = programs[programIdx];
    int32_t base = programIdx * blocksPerExe;
    params.startPC = initialStartPC;
    int32_t start = 0;
    if (params.startPC) {
      start = params.startPC[programIdx];
    }
    if (start == ~0) {
      // No continu in this program.
      continue;
    }

    for (auto pc = start; pc < program.size(); ++pc) {
      assert(params.programs[0]->instructions != nullptr);
      switch (program[pc]) {
        case OpCode::kFilter:
          CALL_ONE(oneFilter, params, pc, base);
          ++pc;
          break;
        case OpCode::kAggregate:
          CALL_ONE(oneAggregate, params, pc, base);
          break;
        case OpCode::kReadAggregate:
          CALL_ONE(oneReadAggregate, params, pc, base);
          break;
        case OpCode::kPlus_BIGINT:
          CALL_ONE(onePlusBigint, params, pc, base);
          break;
        case OpCode::kLT_BIGINT:
          CALL_ONE(oneLt<int64_t>, params, pc, base);
          break;
        default:
          assert(false);
      }
    }
    params.startPC = nullptr;
  }
}

void WaveKernelStream::call(
    Stream* alias,
    int32_t numBlocks,
    int32_t sharedSize,
    KernelParams& params) {
  if (FLAGS_kernel_gdb) {
    callOne(alias, numBlocks, sharedSize, params);
    (alias ? alias : this)->wait();
    return;
  }

  waveBaseKernel<<<
      numBlocks,
      kBlockSize,
      sharedSize,
      alias ? alias->stream()->stream : stream()->stream>>>(params);
  CUDA_CHECK(cudaGetLastError());
}

REGISTER_KERNEL("expr", waveBaseKernel);

void __global__ setupAggregationKernel(AggregationControl op) {
  if (op.oldBuckets) {
    auto table = op.head->table;
    reinterpret_cast<GpuHashTable*>(table)->rehash<SumGroupRow>(
        reinterpret_cast<GpuBucket*>(op.oldBuckets),
        op.numOldBuckets,
        SumGroupByOps(nullptr, nullptr));
    return;
  }
  auto* data = new (op.head) DeviceAggregation();
  data->rowSize = op.rowSize;
  data->singleRow = reinterpret_cast<char*>(data + 1);
  memset(data->singleRow, 0, op.rowSize);
}

void WaveKernelStream::setupAggregation(
    AggregationControl& op,
    int32_t entryPoint,
    CompiledKernel* kernel) {
  int32_t numBlocks = 1;
  int32_t numThreads = 1;
  if (op.oldBuckets) {
    // One thread per bucket. Enough TBs for full device.
    numThreads = kBlockSize;
    numBlocks = std::min<int64_t>(
        roundUp(op.numOldBuckets, kBlockSize) / kBlockSize, 640);
  }
  if (kernel) {
    void* args = &op;
    kernel->launch(entryPoint, numBlocks, numThreads, 0, this, &args);
  } else {
    setupAggregationKernel<<<numBlocks, numThreads, 0, stream_->stream>>>(op);
  }
  wait();
}

} // namespace facebook::velox::wave
