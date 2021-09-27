/******************************************************************************
 * Copyright (c) 2011-2021, NVIDIA CORPORATION.  All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *     * Neither the name of the NVIDIA CORPORATION nor the
 *       names of its contributors may be used to endorse or promote products
 *       derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 *AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 *IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL NVIDIA CORPORATION BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 ******************************************************************************/

#pragma once

#include "../config.cuh"
#include "../thread/thread_search.cuh"
#include "../util_ptx.cuh"
#include "../util_type.cuh"
#include "block_scan.cuh"
#include <limits>
#include <type_traits>

/// CUB namespace
CUB_NAMESPACE_BEGIN

/**
 * @brief The BlockRunLengthDecode class supports decoding a run-length encoded array of items. That is, given
 * the two arrays run_value[N] and run_lengths[N], run_value[i] is repeated run_lengths[i] many times in the output
 * array.
 * Due to the nature of the run-length decoding algorithm ("decompression"), the output size of the run-length decoded
 * array is runtime-dependent and potentially without any upper bound. To address this, BlockRunLengthDecode allows
 * retrieving a "window" from the run-length decoded array. The window's offset can be specified and BLOCK_THREADS *
 * DECODED_ITEMS_PER_THREAD (i.e., referred to as window_size) decoded items from the specified window will be returned.
 *
 * @note: Trailing runs of length 0 are supported (i.e., they may only appear at the end of the run_lengths array).
 * A run of length zero may not be followed by a run length that is not zero.
 *
 * @tparam ItemT The data type of the items being run-length decoded
 * @tparam BLOCK_DIM_X The thread block length in threads along the X dimension
 * @tparam RUNS_PER_THREAD The number of consecutive runs that each thread contributes
 * @tparam DECODED_ITEMS_PER_THREAD The maximum number of decoded items that each thread holds
 * @tparam DecodedOffsetT Type used to index into the block's decoded items (large enough to hold the sum over all the
 * runs' lengths)
 * @tparam BLOCK_DIM_Y The thread block length in threads along the Y dimension
 * @tparam BLOCK_DIM_Z The thread block length in threads along the Z dimension
 */
template <typename ItemT,
          int BLOCK_DIM_X,
          int RUNS_PER_THREAD,
          int DECODED_ITEMS_PER_THREAD,
          typename DecodedOffsetT = uint32_t,
          int BLOCK_DIM_Y         = 1,
          int BLOCK_DIM_Z         = 1>
class BlockRunLengthDecode
{
  //---------------------------------------------------------------------
  // CONFIGS & TYPE ALIASES
  //---------------------------------------------------------------------
private:
  /// The thread block size in threads
  static constexpr int BLOCK_THREADS = BLOCK_DIM_X * BLOCK_DIM_Y * BLOCK_DIM_Z;

  /// The number of runs that the block decodes (out-of-bounds items may be padded with run lengths of '0')
  static constexpr int BLOCK_RUNS = BLOCK_THREADS * RUNS_PER_THREAD;

  /// The number of decoded items. If the actual run-length decoded items exceed BLOCK_DECODED_ITEMS, one can
  /// retrieve the full run-length decoded data through multiple invocations.
  static constexpr int BLOCK_DECODED_ITEMS = BLOCK_THREADS * DECODED_ITEMS_PER_THREAD;

  /// BlockScan used to determine the beginning of each run (i.e., prefix sum over the runs' length)
  using RunOffsetScanT = BlockScan<DecodedOffsetT, BLOCK_DIM_X, BLOCK_SCAN_RAKING_MEMOIZE, BLOCK_DIM_Y, BLOCK_DIM_Z>;

  /// Type used to index into the block's runs
  using RunOffsetT = uint32_t;

  /// Shared memory type required by this thread block
  union _TempStorage
  {
    typename RunOffsetScanT::TempStorage offset_scan;
    struct
    {
      ItemT run_values[BLOCK_RUNS];
      DecodedOffsetT run_offsets[BLOCK_RUNS];
    } runs;
  }; // union TempStorage

  /// Internal storage allocator (used when the user does not provide pre-allocated shared memory)
  __device__ __forceinline__ _TempStorage &PrivateStorage()
  {
    __shared__ _TempStorage private_storage;
    return private_storage;
  }

  /// Shared storage reference
  _TempStorage &temp_storage;

  /// Linear thread-id
  uint32_t linear_tid;

public:
  struct TempStorage : Uninitialized<_TempStorage>
  {};

  //---------------------------------------------------------------------
  // CONSTRUCTOR
  //---------------------------------------------------------------------

  /**
   * @brief Constructor specialised for user-provided temporary storage, initializing using the runs' lengths.
   */
  template <typename RunLengthT, typename TotalDecodedSizeT>
  __device__ __forceinline__ BlockRunLengthDecode(TempStorage &temp_storage,
                                                  ItemT (&run_values)[RUNS_PER_THREAD],
                                                  RunLengthT (&run_lengths)[RUNS_PER_THREAD],
                                                  TotalDecodedSizeT &total_decoded_size)
      : temp_storage(temp_storage.Alias())
      , linear_tid(RowMajorTid(BLOCK_DIM_X, BLOCK_DIM_Y, BLOCK_DIM_Z))
  {
    InitWithRunLengths(run_values, run_lengths, total_decoded_size);
  }

  /**
   * @brief Constructor specialised for user-provided temporary storage, initializing using the runs' offsets.
   */
  template <typename UserRunOffsetT>
  __device__ __forceinline__ BlockRunLengthDecode(TempStorage &temp_storage,
                                                  ItemT (&run_values)[RUNS_PER_THREAD],
                                                  UserRunOffsetT (&run_offsets)[RUNS_PER_THREAD])
      : temp_storage(temp_storage.Alias())
      , linear_tid(RowMajorTid(BLOCK_DIM_X, BLOCK_DIM_Y, BLOCK_DIM_Z))
  {
    InitWithRunOffsets(run_values, run_offsets);
  }

  /**
   * @brief Constructor specialised for static temporary storage, initializing using the runs' lengths.
   */
  template <typename RunLengthT, typename TotalDecodedSizeT>
  __device__ __forceinline__ BlockRunLengthDecode(ItemT (&run_values)[RUNS_PER_THREAD],
                                                  RunLengthT (&run_lengths)[RUNS_PER_THREAD],
                                                  TotalDecodedSizeT &total_decoded_size)
      : temp_storage(PrivateStorage())
      , linear_tid(RowMajorTid(BLOCK_DIM_X, BLOCK_DIM_Y, BLOCK_DIM_Z))
  {
    InitWithRunLengths(run_values, run_lengths, total_decoded_size);
  }

  /**
   * @brief Constructor specialised for static temporary storage, initializing using the runs' offsets.
   */
  template <typename UserRunOffsetT>
  __device__ __forceinline__ BlockRunLengthDecode(ItemT (&run_values)[RUNS_PER_THREAD],
                                                  UserRunOffsetT (&run_offsets)[RUNS_PER_THREAD])
      : temp_storage(PrivateStorage())
      , linear_tid(RowMajorTid(BLOCK_DIM_X, BLOCK_DIM_Y, BLOCK_DIM_Z))
  {
    InitWithRunOffsets(run_values, run_offsets);
  }

private:
  /**
   * \brief Returns the offset of the first value within \p input which compares greater than \p val. This version takes
   * \p MAX_NUM_ITEMS, an upper bound of the array size, which will be used to determine the number of binary search
   * iterations at compile time.
   */
  template <int MAX_NUM_ITEMS,
            typename InputIteratorT,
            typename OffsetT,
            typename T>
  __device__ __forceinline__ uint32_t StaticUpperBound(InputIteratorT input, ///< [in] Input sequence
                                                       OffsetT num_items,    ///< [in] Input sequence length
                                                       T val)                ///< [in] Search key
  {
    OffsetT lower_bound = 0;
    OffsetT upper_bound = num_items;
#pragma unroll
    for (int i = 0; i <= Log2<MAX_NUM_ITEMS>::VALUE; i++)
    {
      OffsetT mid = lower_bound + (upper_bound - lower_bound) / 2;
      mid         = min(mid, num_items - 1);

      if (val < input[mid])
      {
        upper_bound = mid;
      }
      else
      {
        lower_bound = mid + 1;
      }
    }

    return lower_bound;
  }

  template <typename RunOffsetT>
  __device__ __forceinline__ void InitWithRunOffsets(ItemT (&run_values)[RUNS_PER_THREAD],
                                                     RunOffsetT (&run_offsets)[RUNS_PER_THREAD])
  {
    // Keep the runs' items and the offsets of each run's beginning in the temporary storage
    RunOffsetT thread_dst_offset = linear_tid * RUNS_PER_THREAD;
#pragma unroll
    for (int i = 0; i < RUNS_PER_THREAD; i++)
    {
      temp_storage.runs.run_values[thread_dst_offset]  = run_values[i];
      temp_storage.runs.run_offsets[thread_dst_offset] = run_offsets[i];
      thread_dst_offset++;
    }

    // Ensure run offsets and run values have been writen to shared memory
    CTA_SYNC();
  }

  template <typename RunLengthT, typename TotalDecodedSizeT>
  __device__ __forceinline__ void InitWithRunLengths(ItemT (&run_values)[RUNS_PER_THREAD],
                                                     RunLengthT (&run_lengths)[RUNS_PER_THREAD],
                                                     TotalDecodedSizeT &total_decoded_size)
  {
    // Compute the offset for the beginning of each run
    DecodedOffsetT run_offsets[RUNS_PER_THREAD];
#pragma unroll
    for (int i = 0; i < RUNS_PER_THREAD; i++)
    {
      run_offsets[i] = run_lengths[i];
    }
    DecodedOffsetT decoded_size_aggregate;
    RunOffsetScanT(this->temp_storage.offset_scan).ExclusiveSum(run_offsets, run_offsets, decoded_size_aggregate);
    total_decoded_size = decoded_size_aggregate;

    // Ensure the prefix scan's temporary storage can be reused (may be superfluous, but depends on scan implementaiton)
    CTA_SYNC();

    InitWithRunOffsets(run_values, run_offsets);
  }

public:
  /**
   * @brief Run-length decodes the runs previously passed via a call to Init(...) and returns the run-length decoded
   * items in a blocked arrangement to \p decoded_items. If the number of run-length decoded items exceeds the
   * run-length decode buffer (i.e., <b>DECODED_ITEMS_PER_THREAD * BLOCK_THREADS</b>), only the items that fit within
   * the buffer are returned. Subsequent calls to <b>RunLengthDecode</b> adjusting \p from_decoded_offset can be
   * used to retrieve the remaining run-length decoded items.
   *
   * @param from_decoded_offset If invoked with from_decoded_offset that is larger than total_decoded_size results in
   * undefined behavior.
   */
  template <typename RelativeOffsetT>
  __device__ __forceinline__ void RunLengthDecode(ItemT (&decoded_items)[DECODED_ITEMS_PER_THREAD],
                                                  RelativeOffsetT (&item_offsets)[DECODED_ITEMS_PER_THREAD],
                                                  DecodedOffsetT from_decoded_offset = 0)
  {
    // The (global) offset of the first item decoded by this thread
    DecodedOffsetT thread_decoded_offset = from_decoded_offset + linear_tid * DECODED_ITEMS_PER_THREAD;

    // The run that the first decoded item of this thread belongs to
    // If this thread's <thread_decoded_offset> is already beyond the total decoded size, it will be assigned to the
    // last run
    RunOffsetT assigned_run =
      StaticUpperBound<BLOCK_RUNS>(temp_storage.runs.run_offsets, BLOCK_RUNS, thread_decoded_offset) -
      static_cast<RunOffsetT>(1U);

    DecodedOffsetT assigned_run_begin = temp_storage.runs.run_offsets[assigned_run];

    // If this thread is getting assigned the last run, we make sure it will not fetch any other run after this
    DecodedOffsetT assigned_run_end = (assigned_run == BLOCK_RUNS - 1)
                                        ? thread_decoded_offset + DECODED_ITEMS_PER_THREAD
                                        : temp_storage.runs.run_offsets[assigned_run + 1];

    ItemT val = temp_storage.runs.run_values[assigned_run];

#pragma unroll
    for (DecodedOffsetT i = 0; i < DECODED_ITEMS_PER_THREAD; i++)
    {
      decoded_items[i] = val;
      item_offsets[i]  = thread_decoded_offset - assigned_run_begin;
      if (thread_decoded_offset == assigned_run_end - 1)
      {
        // We make sure that a thread is not re-entering this conditional when being assigned to the last run already by
        // extending the last run's length to all the thread's item
        assigned_run++;
        assigned_run_begin = temp_storage.runs.run_offsets[assigned_run];

        // If this thread is getting assigned the last run, we make sure it will not fetch any other run after this
        assigned_run_end = (assigned_run == BLOCK_RUNS - 1) ? thread_decoded_offset + DECODED_ITEMS_PER_THREAD
                                                            : temp_storage.runs.run_offsets[assigned_run + 1];
        val              = temp_storage.runs.run_values[assigned_run];
      }
      thread_decoded_offset++;
    }
  }

  __device__ __forceinline__ void RunLengthDecode(ItemT (&decoded_items)[DECODED_ITEMS_PER_THREAD],
                                                  DecodedOffsetT from_decoded_offset = 0)
  {
    DecodedOffsetT item_offsets[DECODED_ITEMS_PER_THREAD];
    RunLengthDecode(decoded_items, item_offsets, from_decoded_offset);
  }
};

CUB_NAMESPACE_END