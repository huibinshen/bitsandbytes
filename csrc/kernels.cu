// Copyright (c) Facebook, Inc. and its affiliates.
//
// This source code is licensed under the MIT license found in the
// LICENSE file in the root directory of this source tree.

#include <kernels.cuh>
#include <cub/block/block_radix_sort.cuh>
#include <cub/warp/warp_reduce.cuh>
#include <cub/block/block_load.cuh>
#include <cub/block/block_discontinuity.cuh>
#include <cub/block/block_store.cuh>
#include <cub/block/block_reduce.cuh>
#include <cub/cub.cuh>
#include <math_constants.h>

#define HLF_MAX 65504
#define TH 1024
#define NUM 4
#define NUM_BLOCK 4096

// source: https://stackoverflow.com/questions/17399119/how-do-i-use-atomicmax-on-floating-point-values-in-cuda
__device__ float atomicMax(float* address, float val) {
  int* address_as_i = reinterpret_cast<int*>(address);
  int old = *address_as_i, assumed;
  do {
    assumed = old;
    old = atomicCAS(
        reinterpret_cast<int*>(address), assumed,
        __float_as_int(fmaxf(val, __int_as_float(assumed))));
  } while (assumed != old);
  return __int_as_float(old);
}

__device__ float atomicMin(float* address, float val) {
  int* address_as_i = reinterpret_cast<int*>(address);
  int old = *address_as_i, assumed;
  do {
    assumed = old;
    old = atomicCAS(
        reinterpret_cast<int*>(address), assumed,
        __float_as_int(fminf(val, __int_as_float(assumed))));
  } while (assumed != old);
  return __int_as_float(old);
}

template <int STOCHASTIC>
__device__ unsigned char dQuantize(float* smem_code, const float rand, float x)
{
    int pivot = 127;
    int upper_pivot = 255;
    int lower_pivot = 0;

    float lower = -1.0f;
    float upper = 1.0f;

    float val = smem_code[pivot];
    // i>>=1 = {32, 16, 8, 4, 2, 1}
    for(int i = 64; i > 0; i>>=1)
    {
        if(x > val)
        {
            lower_pivot = pivot;
            lower = val;
            pivot+=i;
        }
        else
        {
            upper_pivot = pivot;
            upper = val;
            pivot-=i;
        }
        val = smem_code[pivot];
    }

    if(upper_pivot == 255)
        upper = smem_code[upper_pivot];
    if(lower_pivot == 0)
        lower = smem_code[lower_pivot];

    if(!STOCHASTIC)
    {
      if(x > val)
      {
        float midpoint = (upper+val)*0.5f;
        if(x > midpoint)
        {
          return upper_pivot;
        }
        else
          return pivot;
      }
      else
      {
        float midpoint = (lower+val)*0.5f;
        if(x < midpoint)
          return lower_pivot;
        else
          return pivot;
      }
    }
    else
    {
      if(x > val)
      {
        float dist_to_upper = fabsf(upper-x);
        float dist_full = upper-val;
        if(rand >= dist_to_upper/dist_full) return upper_pivot;
        else return pivot;
      }
      else
      {
        float dist_to_lower = fabsf(lower-x);
        float dist_full = val-lower;
        if(rand >= dist_to_lower/dist_full) return lower_pivot;
        else return pivot;
      }
    }
}

template <int SIGNED>
__device__ __forceinline__ unsigned char quantize_2D(float *__restrict__ quadrants, float *__restrict__ const smem_code, float x)
{
    int pivot = 127;
    int upper_pivot = 255;
    int lower_pivot = 0;

    float lower = SIGNED ? -1.0f : 0.0f;
    float upper = 1.0f;
    float midpoint;
    float val = quadrants[1];
    int local_pivot = 1;
    int offset = 1;

    // i>>=1 = {32, 16, 8, 4, 2, 1}
    for(int i = 64; i > 0; i>>=1)
    {
        if(x > val)
        {
            lower_pivot = pivot;
            lower = val;
            pivot+=i;
            //val = i == 64 ? quadrants[2] : smem_code[pivot];
            local_pivot += offset;
        }
        else
        {
            upper_pivot = pivot;
            upper = val;
            pivot-=i;
            //val = i == 64 ? quadrants[0] : smem_code[pivot];
            local_pivot -= offset;
        }
        val = i >= 64 ? quadrants[local_pivot] : smem_code[pivot];
        offset -= 1;
    }

    if(x > val)
    {
      midpoint = (upper+val)*0.5f;
      if(x > midpoint)
        return upper_pivot;
      else
        return pivot;
    }
    else
    {
      midpoint = (lower+val)*0.5f;
      if(x < midpoint)
        return lower_pivot;
      else
        return pivot;
    }
}

template <int SIGNED>
__device__ __forceinline__ unsigned char quantize_quadrant(int QUADRANT, float *__restrict__ const smem_code, float x, float lower, float midpoint, float upper)
{
    int lower_pivot = QUADRANT*16-1 - 0;
    int pivot = QUADRANT*16-1 + 16;
    int upper_pivot = QUADRANT*16-1 + 31;

    float val = midpoint;

    // i>>=1 = {32, 16, 8, 4, 2, 1}
    for(int i = 16; i > 0; i>>=1)
    {
        if(x > val)
        {
            lower_pivot = pivot;
            lower = val;
            pivot+=i;
        }
        else
        {
            upper_pivot = pivot;
            upper = val;
            pivot-=i;
        }
        val = smem_code[pivot];
    }

    if(x > val)
    {
      midpoint = (upper+val)*0.5f;
      if(x > midpoint)
        return upper_pivot;
      else
        return pivot;
    }
    else
    {
      midpoint = (lower+val)*0.5f;
      if(x < midpoint)
        return lower_pivot;
      else
        return pivot;
    }
}

__global__ void kHistogramScatterAdd2D(float* histogram, int *index1, int *index2, float *src, const int maxidx1, const int n)
{
  const int tid = threadIdx.x + (blockDim.x*blockIdx.x);
  const int numThreads = blockDim.x*gridDim.x;

  for(int i = tid; i < n; i+=numThreads)
  {
      int idx = (index1[i]*maxidx1) + index2[i];
      atomicAdd(&histogram[idx], src[i]);
  }
}

template<typename T, int BLOCK_SIZE, int NUM_MAX>
__global__ void kCompressMax(T * __restrict__ const A, T* out, unsigned char* out_idx, const int n)
{
  typedef cub::WarpReduce<T> WarpReduce;
  __shared__ typename WarpReduce::TempStorage temp_storage;
  typedef cub::BlockLoad<T, BLOCK_SIZE/8 , 8, cub::BLOCK_LOAD_WARP_TRANSPOSE> LoadT;
  __shared__ typename LoadT::TempStorage loadt;

  const int warp_idx = threadIdx.x/32;
  const int valid_items = n - (blockIdx.x*BLOCK_SIZE) > BLOCK_SIZE ? BLOCK_SIZE : n - (blockIdx.x*BLOCK_SIZE);

  //  BLOCK_SIZE/32 == number of warps
  __shared__ int smem_max_indices[8*BLOCK_SIZE/32];
  __shared__ float smem_max_values[8*BLOCK_SIZE/32];

  T values[8];
  T max1 = -64000.0f;
  T max2 = -64000.0f;
  int max_idx1 = -1;
  int max_idx2 = -1;
  int sign1 = -1;
  int sign2 = -1;

  // 1. load 8 values per thread
  // 2. compute 2-max in registers (64 max per warp)
  // 3. do warp reduction + broadcast back
  // 4. Up-shift maxed value, write index into shared memory, replace with 2nd largest
  // 5. Repeat (3) 8 times for top 8 values in 256
  // 6. store with byte index

  LoadT(loadt).Load(&(A[(blockIdx.x*BLOCK_SIZE)]), values, valid_items, (T)0.0f);
  #pragma unroll 8
  for(int i = 0; i < 8; i++)
  {
    T absval = fabsf(values[i]);
    if(absval > max1)
    {
      max1 = values[i];
      sign1 = signbit(values[i]);
      max_idx1 = 8*threadIdx.x + i;
    }
    else if(absval > max2)
    {
      max2 = values[i];
      sign2 = signbit(values[i]);
      max_idx2 = 8*threadIdx.x + i;
    }
  }

  float warp_max;
  for(int i = 0; i < 8; i++)
  {
    // 3. do warp reduction + broadcast back
    warp_max = WarpReduce(temp_storage).Reduce(max1, cub::Max());
    warp_max = cub::ShuffleIndex<32>(warp_max, 0, 0xffffffff);

    // 4. Up-shift maxed value, write index into shared memory, replace with 2nd largest
    if(warp_max == max1)
    {
      smem_max_values[warp_idx*8 + i] = sign1 != 0 ? -max1 : max1;
      smem_max_indices[warp_idx*8 + i] = max_idx1;

      sign1 = sign2;
      max1 = max2;
      max_idx1 = max_idx2;

      max2 = -64000.0f;
    }
    __syncwarp();
  }

  if(threadIdx.x % 32 < 8)
  {
    // offset: 8 values per 256 input values
    //
    int offset = BLOCK_SIZE*blockIdx.x*BLOCK_SIZE/32*8;
  }

}

#define THREADS_ESTIMATE 512
#define NUM_ESTIMATE 8
#define BLOCK_ESTIMATE 4096

template<typename T>
__launch_bounds__(THREADS_ESTIMATE, 1)
__global__ void kEstimateQuantiles(T *__restrict__ const A, float *code, const float offset, const T max_val, const int n)
{
  const int n_full = (BLOCK_ESTIMATE*(n/BLOCK_ESTIMATE)) + (n % BLOCK_ESTIMATE == 0 ? 0 : BLOCK_ESTIMATE);
  int valid_items = (blockIdx.x+1 == gridDim.x) ? n - (blockIdx.x*BLOCK_ESTIMATE) : BLOCK_ESTIMATE;
  const int base_idx = (blockIdx.x * BLOCK_ESTIMATE);
  const float reciprocal_num_blocks = 1.0f/(n < 4096 ? 1.0f : (n/BLOCK_ESTIMATE));

  T vals[NUM_ESTIMATE];

  typedef cub::BlockRadixSort<T, THREADS_ESTIMATE, NUM_ESTIMATE, cub::NullType, 4, true, cub::BLOCK_SCAN_RAKING> BlockRadixSort;
  typedef cub::BlockLoad<T, THREADS_ESTIMATE, NUM_ESTIMATE, cub::BLOCK_LOAD_WARP_TRANSPOSE> LoadFloat;

  __shared__ union {
      typename LoadFloat::TempStorage loadf;
      typename BlockRadixSort::TempStorage sort;
      int smem_qidx[BLOCK_ESTIMATE];
  } temp_storage;

  for (unsigned int i = base_idx; i < n_full; i += gridDim.x*BLOCK_ESTIMATE)
  {
      valid_items = n - i > BLOCK_ESTIMATE ? BLOCK_ESTIMATE : n - i;

      // do not process half-blocks
      if(valid_items < BLOCK_ESTIMATE && n > BLOCK_ESTIMATE){ continue; }

      #pragma unroll 4
      for(int j = 0; j < NUM_ESTIMATE; j++)
          vals[j] = max_val;

      __syncthreads();
      LoadFloat(temp_storage.loadf).Load(&(A[i]), vals, valid_items);

      #pragma unroll 4
      for(int j = 0; j < NUM_ESTIMATE; j++)
          vals[j] = ((float)vals[j]) * reciprocal_num_blocks;


      __syncthreads();
      // sort into striped pattern to mitigate bank conflicts
      // striped pattern index for thread 0 [0, 1024, 2048, 3096]
      // striped pattern index for thread 1 [1, 1025, 2049, 3097]
      BlockRadixSort(temp_storage.sort).SortBlockedToStriped(vals);

      __syncthreads();
      for(int j = threadIdx.x; j < BLOCK_ESTIMATE; j+=blockDim.x)
          temp_storage.smem_qidx[j] = -1;

      if(threadIdx.x < 256)
      {
          float q_interval = (1.0f-(2.0f*offset))/255.0f;
          int local_idx = round(((offset+(threadIdx.x*q_interval))*(valid_items-1)));
          temp_storage.smem_qidx[local_idx] = threadIdx.x;
      }

      __syncthreads();

      for(int i = threadIdx.x; i < BLOCK_ESTIMATE; i+=blockDim.x)
      {
          if(temp_storage.smem_qidx[i] != -1)
              atomicAdd(&code[temp_storage.smem_qidx[i]], vals[i/THREADS_ESTIMATE]);
      }
  }
}


__launch_bounds__(TH, 4)
__global__ void kQuantize(float * code, float * __restrict__ const A, unsigned char *out, const int n)
{
  const int n_full = (NUM_BLOCK*(n/NUM_BLOCK)) + (n % NUM_BLOCK == 0 ? 0 : NUM_BLOCK);
  int valid_items = (blockIdx.x+1 == gridDim.x) ? n - (blockIdx.x*NUM_BLOCK) : NUM_BLOCK;
  const int base_idx = (blockIdx.x * NUM_BLOCK);

  float vals[NUM];
  unsigned char qvals[NUM];
  //const int lane_id = threadIdx.x % 2;

  typedef cub::BlockLoad<float, TH, NUM, cub::BLOCK_LOAD_WARP_TRANSPOSE> LoadFloat;
  typedef cub::BlockStore<unsigned char, TH, NUM, cub::BLOCK_STORE_WARP_TRANSPOSE> StoreChar;

  __shared__ typename LoadFloat::TempStorage loadf;
  __shared__ typename StoreChar::TempStorage storec;
  __shared__ float smem_code[256];
  //__shared__ float smem_code[2][257];

  if(threadIdx.x < 256)
  {
    smem_code[threadIdx.x] = code[threadIdx.x];
    //smem_code[0][threadIdx.x] = code[threadIdx.x];
    //smem_code[1][threadIdx.x] = smem_code[0][threadIdx.x];
  }


  for (unsigned int i = base_idx; i < n_full; i += gridDim.x*NUM_BLOCK)
  {
      // number of values already processed in blocks +
      // number of values already processed in this block +
      // rand_offset % mod value
      valid_items = n - i > NUM_BLOCK ? NUM_BLOCK : n - i;

      __syncthreads();
      LoadFloat(loadf).Load(&(A[i]), vals, valid_items);


      #pragma unroll 4
      for(int j = 0; j < NUM; j++)
          qvals[j] = dQuantize<0>(smem_code, 0.0f, vals[j]);

      __syncthreads();
      StoreChar(storec).Store(&(out[i]), qvals, valid_items);
  }
}

template<typename T, int BLOCK_SIZE, int NUM_PER_TH, int STOCHASTIC>
//__launch_bounds__(TH, 4)
__global__ void kQuantizeBlockwise(float * code, T * __restrict__ const A, float *absmax, unsigned char *out, float * __restrict__ const rand, const int rand_offset, const int n)
{
  const int n_full = gridDim.x * BLOCK_SIZE;
  int valid_items = 0;
  const int base_idx = (blockIdx.x * BLOCK_SIZE);

  T vals[NUM_PER_TH];
  float rand_vals[NUM_PER_TH];
  unsigned char qvals[NUM_PER_TH];
  //float local_abs_max = -FLT_MAX;
  float local_abs_max = 0.0f;
  int local_rand_idx = 0;

  typedef cub::BlockLoad<T, BLOCK_SIZE/NUM_PER_TH, NUM_PER_TH, cub::BLOCK_LOAD_WARP_TRANSPOSE> LoadT;
  typedef cub::BlockStore<unsigned char, BLOCK_SIZE/NUM_PER_TH, NUM_PER_TH, cub::BLOCK_STORE_WARP_TRANSPOSE> StoreChar;
  typedef cub::BlockReduce<float, BLOCK_SIZE/NUM_PER_TH> BlockReduce;
  typedef cub::BlockLoad<float, BLOCK_SIZE/NUM_PER_TH, NUM_PER_TH, cub::BLOCK_LOAD_WARP_TRANSPOSE> LoadFloat;

  __shared__ typename LoadT::TempStorage loadt;
  __shared__ typename LoadFloat::TempStorage loadf;
  __shared__ typename StoreChar::TempStorage storec;
  __shared__ typename BlockReduce::TempStorage reduce;
  __shared__ float smem_code[256];
  __shared__ float smem_absmax_value[1];

  for(int i = threadIdx.x; i < 256; i+=blockDim.x)
    smem_code[i] = code[i];

  for (unsigned int i = base_idx; i < n_full; i += gridDim.x*BLOCK_SIZE)
  {
    valid_items = n - i > BLOCK_SIZE ? BLOCK_SIZE : n - i;
    local_abs_max = -FLT_MAX;

    __syncthreads();
    LoadT(loadt).Load(&(A[i]), vals, valid_items, (T)0.0f);

    // 1. compute local max
    // 2. broadcast local max
    // 3. normalize inputs and quantize

    #pragma unroll NUM_PER_TH
    for(int j = 0; j < NUM_PER_TH; j++)
       local_abs_max = fmaxf(local_abs_max, fabsf((float)vals[j]));

    local_abs_max = BlockReduce(reduce).Reduce(local_abs_max, cub::Max(), valid_items);

    if(threadIdx.x == 0)
      smem_absmax_value[0] = local_abs_max;

    __syncthreads();

    if(threadIdx.x == 0)
      absmax[i/BLOCK_SIZE] = local_abs_max;
    else
      local_abs_max = smem_absmax_value[0];

    __syncwarp();

    local_abs_max = 1.0f/local_abs_max;

    if(STOCHASTIC)
    {
      local_rand_idx = ((blockIdx.x*NUM_BLOCK) + (threadIdx.x*NUM) + rand_offset) % (1024-4);
      LoadFloat(loadf).Load(&rand[local_rand_idx], rand_vals, BLOCK_SIZE, 0);
    }

    #pragma unroll NUM_PER_TH
    for(int j = 0; j < NUM_PER_TH; j++)
    {
      if(!STOCHASTIC)
       qvals[j] = dQuantize<0>(smem_code, 0.0f, ((float)vals[j])*local_abs_max);
      else
       qvals[j] = dQuantize<1>(smem_code, rand_vals[j], ((float)vals[j])*local_abs_max);
    }

    __syncthreads();
    StoreChar(storec).Store(&(out[i]), qvals, valid_items);
  }
}

template<typename T, int BLOCK_SIZE, int THREADS, int NUM_PER_TH>
__global__ void kDequantizeBlockwise(float *code, unsigned char * A, float * absmax, T *out, const int n)
{

  const int n_full = gridDim.x * BLOCK_SIZE;
  int valid_items = 0;
  const int base_idx = (blockIdx.x * BLOCK_SIZE);

  T vals[NUM_PER_TH];
  unsigned char qvals[NUM_PER_TH];
  float local_abs_max = -FLT_MAX;

  typedef cub::BlockLoad<unsigned char, THREADS, NUM_PER_TH, cub::BLOCK_LOAD_WARP_TRANSPOSE> LoadChar;
  typedef cub::BlockStore<T, THREADS, NUM_PER_TH, cub::BLOCK_STORE_WARP_TRANSPOSE> StoreT;

  __shared__ typename LoadChar::TempStorage loadchar;
  __shared__ typename StoreT::TempStorage storet;
  //__shared__ float smem_code[256];
  //float local_code[16];

  //if(threadIdx.x < 256)
    //smem_code[threadIdx.x] = code[threadIdx.x];

  for (unsigned int i = base_idx; i < n_full; i += gridDim.x*BLOCK_SIZE)
  {
      valid_items = n - i > BLOCK_SIZE ? BLOCK_SIZE : n - i;
      local_abs_max = absmax[i/BLOCK_SIZE];

      __syncthreads();
      LoadChar(loadchar).Load(&(A[i]), qvals, valid_items, 128);

      // load code through read-only cache via __ldg
      #pragma unroll NUM_PER_TH
      for(int j = 0; j < NUM_PER_TH; j++)
        vals[j] = __ldg(&code[qvals[j]])*local_abs_max;

      __syncthreads();
      StoreT(storet).Store(&(out[i]), vals, valid_items);
  }
}


__global__ void kDequantize(float *code, unsigned char *A, float *out, const int n)
{
	const unsigned int numThreads = blockDim.x * gridDim.x;
	const int idx = (blockIdx.x * blockDim.x) + threadIdx.x;

	__shared__ float smem_code[256];
	if(threadIdx.x < 256)
	{
		smem_code[threadIdx.x] = code[threadIdx.x];
	}

	__syncthreads();

	for (int i = idx;i < n; i += numThreads)
	{
		out[i] = smem_code[A[i]];
	}
}



template<typename T, int OPTIMIZER, int BLOCK_SIZE, int NUM_VALS>
__launch_bounds__(BLOCK_SIZE/NUM_VALS, 1)
__global__ void kPreconditionOptimizer32bit2State(T* g, T* p,
                float* state1, float* state2, float *unorm,
                const float beta1, const float beta2, const float eps, const float weight_decay,
                const int step, const float lr, const float gnorm_scale, const int n)
{

  const int n_full = (BLOCK_SIZE*(n/BLOCK_SIZE)) + (n % BLOCK_SIZE == 0 ? 0 : BLOCK_SIZE);
  const int base_idx = (blockIdx.x * blockDim.x * NUM_VALS);
  int valid_items = 0;

  T g_vals[NUM_VALS];

  float s1_vals[NUM_VALS];
  float s2_vals[NUM_VALS];

  const float correction1 = 1.0f/(1.0f - powf(beta1, step));
  const float correction2 = 1.0f/(1.0f - powf(beta2, step));

  typedef cub::BlockLoad<T, BLOCK_SIZE/NUM_VALS, NUM_VALS, cub::BLOCK_LOAD_WARP_TRANSPOSE> Load;
  typedef cub::BlockLoad<float, BLOCK_SIZE/NUM_VALS, NUM_VALS, cub::BLOCK_LOAD_WARP_TRANSPOSE> LoadFloat;
  typedef cub::BlockReduce<float, BLOCK_SIZE/NUM_VALS> BlockReduce;

  __shared__ union {
      typename Load::TempStorage load;
      typename LoadFloat::TempStorage loadf;
      typename BlockReduce::TempStorage reduce;
  } temp_storage;

  for (unsigned int i = base_idx; i < n_full; i += gridDim.x*BLOCK_SIZE)
  {
      valid_items = n - i >= (BLOCK_SIZE) ? (BLOCK_SIZE) : n - i;

      __syncthreads();
      Load(temp_storage.load).Load(&(g[i]), g_vals, valid_items, 0.0f);
      __syncthreads();
      LoadFloat(temp_storage.loadf).Load(&(state1[i]), s1_vals, valid_items, 0.0f);
      __syncthreads();
      LoadFloat(temp_storage.loadf).Load(&(state2[i]), s2_vals, valid_items, 0.0f);

      # pragma unroll NUM_VALS
      for(unsigned int j = 0; j < NUM_VALS; j++)
        g_vals[j] = gnorm_scale*((float)g_vals[j]);

      # pragma unroll NUM_VALS
      for(unsigned int j = 0; j < NUM_VALS; j++)
      {
          switch(OPTIMIZER)
          {
              case ADAM:
                  s1_vals[j] = s1_vals[j]*beta1 + ((1.0f -beta1)*((float)g_vals[j]));
                  s2_vals[j] = s2_vals[j]*beta2 + ((1.0f -beta2)*(((float)g_vals[j])*((float)g_vals[j])));
                  s1_vals[j] *= correction1;
                  s2_vals[j] *= correction2;
                  s1_vals[j] = s1_vals[j]/(sqrtf(s2_vals[j])+eps); // update
                  s1_vals[j] *= s1_vals[j]; // update l2 norm (update*update)
                  break;
          }
      }

      # pragma unroll NUM_VALS-1
      for(unsigned int j = 1; j < NUM_VALS; j++)
          s1_vals[0] += s1_vals[j];

      __syncthreads();
      s1_vals[0] = BlockReduce(temp_storage.reduce).Sum(s1_vals[0]);

      if(threadIdx.x == 0)
        atomicAdd(&unorm[0], s1_vals[0]);

      __syncwarp();
  }
}



#define NUM_PER_THREAD 4

template<typename T, int OPTIMIZER>
__launch_bounds__(TH, 1)
__global__ void kOptimizer32bit2State(T* g, T* p,
                float* state1, float* state2, float *unorm, const float max_unorm, const float param_norm,
                const float beta1, const float beta2, const float eps, const float weight_decay,
                const int step, const float lr, const float gnorm_scale, const bool skip_zeros, const int n)
{

  const int n_full = ((TH*NUM_PER_THREAD)*(n/(TH*NUM_PER_THREAD))) + (n % (TH*NUM_PER_THREAD) == 0 ? 0 : (TH*NUM_PER_THREAD));
  const int base_idx = (blockIdx.x * blockDim.x * NUM_PER_THREAD);
  int valid_items = 0;
  float update_scale = 0.0f;
  T g_vals[NUM_PER_THREAD];
  T p_vals[NUM_PER_THREAD];

  float s1_vals[NUM_PER_THREAD];
  float s2_vals[NUM_PER_THREAD];

  const float correction1 = 1.0f - powf(beta1, step);
  const float correction2 = sqrtf(1.0f - powf(beta2, step));
  const float step_size = -lr*correction2/correction1;

  if(max_unorm > 0.0f)
  {
    update_scale = max_unorm > 0.0f ? sqrtf(unorm[0]) : 1.0f;
    if(update_scale > max_unorm*param_norm){ update_scale = (max_unorm*param_norm)/update_scale; }
    else{ update_scale = 1.0f; }
  }
  else{ update_scale = 1.0f; }

  typedef cub::BlockLoad<T, TH, NUM_PER_THREAD, cub::BLOCK_LOAD_WARP_TRANSPOSE> Load;
  typedef cub::BlockStore<T, TH, NUM_PER_THREAD, cub::BLOCK_STORE_WARP_TRANSPOSE> Store;

  typedef cub::BlockLoad<float, TH, NUM_PER_THREAD, cub::BLOCK_LOAD_WARP_TRANSPOSE> LoadFloat;
  typedef cub::BlockStore<float, TH, NUM_PER_THREAD, cub::BLOCK_STORE_WARP_TRANSPOSE> StoreFloat;

  __shared__ union {
      typename Load::TempStorage load;
      typename Store::TempStorage store;
      typename LoadFloat::TempStorage loadf;
      typename StoreFloat::TempStorage storef;
  } temp_storage;

  for (unsigned int i = base_idx; i < n_full; i += gridDim.x*TH*NUM_PER_THREAD)
  {
      valid_items = n - i >= (TH*NUM_PER_THREAD) ? (TH*NUM_PER_THREAD) : n - i;

      __syncthreads();
      Load(temp_storage.load).Load(&(g[i]), g_vals, valid_items);
      __syncthreads();
      LoadFloat(temp_storage.loadf).Load(&(state1[i]), s1_vals, valid_items);
      __syncthreads();
      LoadFloat(temp_storage.loadf).Load(&(state2[i]), s2_vals, valid_items);
      __syncthreads();
      Load(temp_storage.load).Load(&(p[i]), p_vals, valid_items);

      # pragma unroll 4
      for(unsigned int j = 0; j < NUM_PER_THREAD; j++)
        g_vals[j] = gnorm_scale*((float)g_vals[j]);

      # pragma unroll 4
      for(unsigned int j = 0; j < NUM_PER_THREAD; j++)
      {
          switch(OPTIMIZER)
          {
              case ADAM:
									if(!skip_zeros || (skip_zeros && ((float)g_vals[j] != 0.0f)))
									{
										s1_vals[j] = s1_vals[j]*beta1 + ((1.0f -beta1)*((float)g_vals[j]));
										s2_vals[j] = s2_vals[j]*beta2 + ((1.0f -beta2)*(((float)g_vals[j])*((float)g_vals[j])));
										p_vals[j] = ((float)p_vals[j]) + (update_scale*step_size*(s1_vals[j]/(sqrtf(s2_vals[j])+(eps*correction2))));

                    if(weight_decay > 0.0f)
                        p_vals[j] = ((float)p_vals[j])*(1.0f-(lr*weight_decay));
									}
                  break;
          }
      }

      __syncthreads();
      Store(temp_storage.store).Store(&(p[i]), p_vals, valid_items);
      __syncthreads();
      StoreFloat(temp_storage.storef).Store(&(state1[i]), s1_vals, valid_items);
      __syncthreads();
      StoreFloat(temp_storage.storef).Store(&(state2[i]), s2_vals, valid_items);
  }
}

template<typename T, int OPTIMIZER, int BLOCK_SIZE, int NUM_VALS>
__launch_bounds__(BLOCK_SIZE/NUM_VALS, 1)
__global__ void kPreconditionOptimizer32bit1State(T* g, T* p,
                float* state1, float *unorm,
                const float beta1, const float eps, const float weight_decay,
                const int step, const float lr, const float gnorm_scale, const int n)
{

  const int n_full = (BLOCK_SIZE*(n/BLOCK_SIZE)) + (n % BLOCK_SIZE == 0 ? 0 : BLOCK_SIZE);
  const int base_idx = (blockIdx.x * blockDim.x * NUM_VALS);
  int valid_items = 0;

  T g_vals[NUM_VALS];

  float s1_vals[NUM_VALS];

  typedef cub::BlockLoad<T, BLOCK_SIZE/NUM_VALS, NUM_VALS, cub::BLOCK_LOAD_WARP_TRANSPOSE> Load;
  typedef cub::BlockLoad<float, BLOCK_SIZE/NUM_VALS, NUM_VALS, cub::BLOCK_LOAD_WARP_TRANSPOSE> LoadFloat;
  typedef cub::BlockReduce<float, BLOCK_SIZE/NUM_VALS> BlockReduce;

  __shared__ union {
      typename Load::TempStorage load;
      typename LoadFloat::TempStorage loadf;
      typename BlockReduce::TempStorage reduce;
  } temp_storage;

  for (unsigned int i = base_idx; i < n_full; i += gridDim.x*BLOCK_SIZE)
  {
      valid_items = n - i >= (BLOCK_SIZE) ? (BLOCK_SIZE) : n - i;

      __syncthreads();
      Load(temp_storage.load).Load(&(g[i]), g_vals, valid_items, 0.0f);
      __syncthreads();
      LoadFloat(temp_storage.loadf).Load(&(state1[i]), s1_vals, valid_items, 0.0f);

      # pragma unroll NUM_VALS
      for(unsigned int j = 0; j < NUM_VALS; j++)
        g_vals[j] = gnorm_scale*((float)g_vals[j]);

      # pragma unroll NUM_VALS
      for(unsigned int j = 0; j < NUM_VALS; j++)
      {
          switch(OPTIMIZER)
          {
              case MOMENTUM:
                  if(step == 1)
                    s1_vals[j] = (float)g_vals[j]; // state update
                  else
                    s1_vals[j] = s1_vals[j]*beta1 + ((float)g_vals[j]); // state update
                  s1_vals[j] = s1_vals[j]*s1_vals[j]; // update norm
                  break;
              case RMSPROP:
                  s1_vals[j] = s1_vals[j]*beta1 + ((1.0f-beta1)*((float)g_vals[j])*((float)g_vals[j])); // state update
                  s1_vals[j] = __fdividef((float)g_vals[j],sqrtf(s1_vals[j])+eps); // update value
                  s1_vals[j] = s1_vals[j]*s1_vals[j]; // update norm
                  break;
              case ADAGRAD:
                  s1_vals[j] = s1_vals[j] + ((float)g_vals[j])*((float)g_vals[j]); // state update
                  s1_vals[j] = __fdividef((float)g_vals[j],sqrtf(s1_vals[j])+eps); // update value
                  s1_vals[j] = s1_vals[j]*s1_vals[j]; // update norm
                  break;
          }
      }

      # pragma unroll
      for(unsigned int j = 1; j < NUM_VALS; j++)
        s1_vals[0] += s1_vals[j];

      __syncthreads();
      s1_vals[0] = BlockReduce(temp_storage.reduce).Sum(s1_vals[0], valid_items);

      if(threadIdx.x == 0)
        atomicAdd(&unorm[0], s1_vals[0]);

      __syncwarp();
  }
}

template<typename T, int OPTIMIZER>
__launch_bounds__(TH, 1)
__global__ void kOptimizer32bit1State(T *g, T *p,
                float *state1, float *unorm, const float max_unorm, const float param_norm,
                const float beta1, const float eps, const float weight_decay,
                const int step, const float lr, const float gnorm_scale, const bool skip_zeros, const int n)
{

  const int n_full = ((TH*NUM_PER_THREAD)*(n/(TH*NUM_PER_THREAD))) + (n % (TH*NUM_PER_THREAD) == 0 ? 0 : (TH*NUM_PER_THREAD));
  const int base_idx = (blockIdx.x * blockDim.x * NUM_PER_THREAD);
  int valid_items = 0;
  float update_scale = 0.0f;

  if(max_unorm > 0.0f)
  {
    update_scale = max_unorm > 0.0f ? sqrtf(unorm[0]) : 1.0f;
    if(update_scale > max_unorm*param_norm+eps){ update_scale = (max_unorm*param_norm+eps)/update_scale; }
    else{ update_scale = 1.0f; }
  }
  else{ update_scale = 1.0f; }

  T g_vals[NUM_PER_THREAD];
  T p_vals[NUM_PER_THREAD];

  float s1_vals[NUM_PER_THREAD];

  typedef cub::BlockLoad<T, TH, NUM_PER_THREAD, cub::BLOCK_LOAD_WARP_TRANSPOSE> Load;
  typedef cub::BlockStore<T, TH, NUM_PER_THREAD, cub::BLOCK_STORE_WARP_TRANSPOSE> Store;

  typedef cub::BlockLoad<float, TH, NUM_PER_THREAD, cub::BLOCK_LOAD_WARP_TRANSPOSE> LoadFloat;
  typedef cub::BlockStore<float, TH, NUM_PER_THREAD, cub::BLOCK_STORE_WARP_TRANSPOSE> StoreFloat;

  __shared__ union {
      typename Load::TempStorage load;
      typename Store::TempStorage store;
      typename LoadFloat::TempStorage loadf;
      typename StoreFloat::TempStorage storef;
  } temp_storage;

  for (unsigned int i = base_idx; i < n_full; i += gridDim.x*TH*NUM_PER_THREAD)
  {
      valid_items = n - i >= (TH*NUM_PER_THREAD) ? (TH*NUM_PER_THREAD) : n - i;

      __syncthreads();
      Load(temp_storage.load).Load(&(g[i]), g_vals, valid_items);
      __syncthreads();
      LoadFloat(temp_storage.loadf).Load(&(state1[i]), s1_vals, valid_items);
      __syncthreads();
      Load(temp_storage.load).Load(&(p[i]), p_vals, valid_items);

      # pragma unroll 4
      for(unsigned int j = 0; j < NUM_PER_THREAD; j++)
      {
        g_vals[j] = gnorm_scale*((float)g_vals[j]);
        if(weight_decay > 0.0f)
          g_vals[j] = (float)g_vals[j] + (((float)p_vals[j])*weight_decay);
      }

      # pragma unroll 4
      for(unsigned int j = 0; j < NUM_PER_THREAD; j++)
      {
					if(!skip_zeros || (skip_zeros && ((float)g_vals[j] != 0.0f)))
					{
						switch(OPTIMIZER)
						{
								case MOMENTUM:
										if(step == 1)
											s1_vals[j] = (float)g_vals[j];
										else
											s1_vals[j] = s1_vals[j]*beta1 + ((float)g_vals[j]);

										p_vals[j] = ((float)p_vals[j]) + update_scale*(-lr*(s1_vals[j]));
										break;
								case RMSPROP:
										s1_vals[j] = s1_vals[j]*beta1 + ((1.0f-beta1)*((float)g_vals[j])*((float)g_vals[j]));
										p_vals[j] = ((float)p_vals[j]) - update_scale*(lr*__fdividef((float)g_vals[j],sqrtf((float)s1_vals[j])+eps));
										break;
								case ADAGRAD:
										s1_vals[j] = s1_vals[j] + ((float)g_vals[j])*((float)g_vals[j]);
										p_vals[j] = ((float)p_vals[j]) - lr*__fdividef((float)g_vals[j],sqrtf((float)s1_vals[j])+eps);
										break;
						}
					}
      }

      __syncthreads();
      Store(temp_storage.store).Store(&(p[i]), p_vals, valid_items);
      __syncthreads();
      StoreFloat(temp_storage.storef).Store(&(state1[i]), s1_vals, valid_items);
  }
}


#define NUM8BIT 16
#define NUM_THREADS 256
#define NUM_PER_BLOCK 4096

template<typename T, int OPTIMIZER>
__global__ void
__launch_bounds__(NUM_THREADS, 2)
kPreconditionOptimizerStatic8bit2State(T* p, T* __restrict__ const g, unsigned char*__restrict__  const state1, unsigned char* __restrict__ const state2,
                float *unorm,
                const float beta1, const float beta2,
                const float eps, const int step,
                float* __restrict__ const quantiles1, float* __restrict__ const quantiles2,
                float* max1, float* max2, float* new_max1, float* new_max2,
                const float gnorm_scale, const int n)
{
    const int n_full = gridDim.x * NUM_PER_BLOCK;
    const int base_idx = (blockIdx.x * blockDim.x * NUM_PER_THREAD);
    int valid_items = n - (blockIdx.x*NUM_PER_BLOCK) > NUM_PER_BLOCK ? NUM_PER_BLOCK : n - (blockIdx.x*NUM_PER_BLOCK);
    float g_val = 0.0f;
    float local_max_s1 = -FLT_MAX;
    float local_max_s2 = -FLT_MAX;
    float local_unorm = 0.0f;

    float s2_vals[NUM8BIT];
    float s1_vals[NUM8BIT];
    T g_vals[NUM8BIT];
    unsigned char m_c1[NUM8BIT];
    unsigned char r_c2[NUM8BIT];

    typedef cub::BlockLoad<T, NUM_THREADS, NUM8BIT, cub::BLOCK_LOAD_WARP_TRANSPOSE> LoadT;
    typedef cub::BlockLoad<unsigned char, NUM_THREADS, NUM8BIT, cub::BLOCK_LOAD_WARP_TRANSPOSE> LoadUInt8;
    typedef cub::BlockReduce<float, NUM_THREADS> BlockReduce;


    __shared__ union {
        typename LoadT::TempStorage loadh;
        typename LoadUInt8::TempStorage loadc;
        typename BlockReduce::TempStorage reduce;
    } temp_storage;

    __shared__ float smem_quantiles1[256];
    __shared__ float smem_quantiles2[256];

    if(threadIdx.x < 256)
    {
        smem_quantiles1[threadIdx.x] = quantiles1[threadIdx.x];
        smem_quantiles2[threadIdx.x] = quantiles2[threadIdx.x];
    }

    __syncthreads();

    for (unsigned int i = base_idx; i < n_full; i += NUM_THREADS*gridDim.x*NUM8BIT)
    {
        valid_items = n - i >= (TH*NUM_PER_THREAD) ? (TH*NUM_PER_THREAD) : n - i;

        LoadT(temp_storage.loadh).Load(&(g[i]), g_vals, valid_items, (T)0.0f);
        __syncthreads();
        LoadUInt8(temp_storage.loadc).Load(&(state1[i]), m_c1, valid_items, 128);
        __syncthreads();
        LoadUInt8(temp_storage.loadc).Load(&(state2[i]), r_c2, valid_items, 128);
        __syncthreads();

        #pragma unroll 16
        for(int j = 0; j < NUM8BIT; j++)
        {
            g_val = g_vals[j];
            g_val *= gnorm_scale;
            s1_vals[j] = smem_quantiles1[m_c1[j]]*max1[0]*beta1;
            s1_vals[j] += (1.0f-beta1)*g_val;
            local_max_s1 = fmaxf(local_max_s1, fabsf(s1_vals[j]));
        }

        #pragma unroll 16
        for(int j = 0; j < NUM8BIT; j++)
        {
            g_val = g_vals[j];
            g_val *= gnorm_scale;
            s2_vals[j] = smem_quantiles2[r_c2[j]]*max2[0]*beta2;
            s2_vals[j] += (1.0f-beta2)*g_val*g_val;
            local_max_s2 = fmaxf(local_max_s2, fabsf(s2_vals[j]));
        }

        if(unorm != NULL)
        {
          #pragma unroll 16
          for(int j = 0; j < NUM8BIT; j++)
          {
            float correction1 = __fdividef(1.0f, 1.0f - powf(beta1, step));
            float correction2 = __fdividef(1.0f, 1.0f - powf(beta2, step));
            s1_vals[j] *= correction1;
            s2_vals[j] *= correction2;
            float update_val = s1_vals[j]/(sqrtf(s2_vals[j])+eps); // update
            local_unorm += update_val*update_val;
          }
        }
    }

    __syncthreads();
    local_max_s1 = BlockReduce(temp_storage.reduce).Reduce(local_max_s1, cub::Max(), valid_items);
    __syncthreads();
    local_max_s2 = BlockReduce(temp_storage.reduce).Reduce(local_max_s2, cub::Max(), valid_items);
    if(unorm != NULL)
    {
      __syncthreads();
      local_unorm = BlockReduce(temp_storage.reduce).Reduce(local_unorm, cub::Sum(), valid_items);
    }

    if(threadIdx.x == 0)
    {
        atomicMax(&new_max1[0], local_max_s1);
        atomicMax(&new_max2[0], local_max_s2);
        if(unorm != NULL){ atomicAdd(&unorm[0], local_unorm); }
    }
}

#define NUM_PER_THREAD2 4
#define NUM_THREADS2 1024
#define NUM_PER_BLOCK2 4096

template<typename T, int OPTIMIZER>
__global__ void
__launch_bounds__(NUM_THREADS2, 1)
kOptimizerStatic8bit2State(T* p, T* const g, unsigned char* state1, unsigned char* state2,
                const float *unorm, const float max_unorm, const float param_norm, \
                const float beta1, const float beta2,
                const float eps, const int step, const float lr,
                float* __restrict__ const quantiles1, float* __restrict__ const quantiles2,
                float* max1, float* max2, float* new_max1, float* new_max2,
                float weight_decay,
                const float gnorm_scale, const int n)
{

    const int n_full = (blockDim.x * gridDim.x)*NUM_PER_THREAD2;
    const int base_idx = (blockIdx.x * blockDim.x * NUM_PER_THREAD2);
    int valid_items = 0;
    float g_val = 0.0f;
    float s1_vals[NUM_PER_THREAD2];
    float s2_vals[NUM_PER_THREAD2];
    const float correction1 = 1.0f - powf(beta1, step);
    const float correction2 = sqrtf(1.0f - powf(beta2, step));
    const float step_size = -lr*correction2/correction1;
    //const float step_size = -lr*correction2/correction1;
    float new_max_val1 = 1.0f/new_max1[0];
    float new_max_val2 = 1.0f/new_max2[0];
    float update_scale = 1.0f;

    if(max_unorm > 0.0f)
    {
      update_scale = max_unorm > 0.0f ? sqrtf(unorm[0]) : 1.0f;
      if(update_scale > max_unorm*param_norm){ update_scale = (max_unorm*param_norm)/update_scale; }
      else{ update_scale = 1.0f; }
    }
    else{ update_scale = 1.0f; }

    unsigned char c1s[NUM_PER_THREAD2];
    unsigned char c2s[NUM_PER_THREAD2];
    T p_vals[NUM_PER_THREAD2];
    T g_vals[NUM_PER_THREAD2];
    typedef cub::BlockLoad<T, NUM_THREADS2, NUM_PER_THREAD2, cub::BLOCK_LOAD_WARP_TRANSPOSE> LoadT;
    typedef cub::BlockLoad<unsigned char, NUM_THREADS2, NUM_PER_THREAD2, cub::BLOCK_LOAD_WARP_TRANSPOSE> LoadChar;

    typedef cub::BlockStore<unsigned char, NUM_THREADS2, NUM_PER_THREAD2, cub::BLOCK_STORE_WARP_TRANSPOSE> StoreChar;
    typedef cub::BlockStore<T, NUM_THREADS2, NUM_PER_THREAD2, cub::BLOCK_STORE_WARP_TRANSPOSE> StoreT;

    __shared__ float smem_quantiles1[256];
    __shared__ float smem_quantiles2[256];

    __shared__ union {
        typename LoadT::TempStorage loadh;
        typename LoadChar::TempStorage loadc;
        typename StoreChar::TempStorage storec;
        typename StoreT::TempStorage storeh;
    } temp_storage;

    if(threadIdx.x < 512)
    {
        if(threadIdx.x < 256)
            smem_quantiles1[threadIdx.x] = quantiles1[threadIdx.x];
        else
            smem_quantiles2[threadIdx.x-256] = quantiles2[threadIdx.x-256];
    }

    __syncthreads();

    for (unsigned int i = base_idx; i < n_full; i += gridDim.x*NUM_THREADS2*NUM_PER_THREAD2)
    {
        valid_items = n - i >= (TH*NUM_PER_THREAD) ? (TH*NUM_PER_THREAD) : n - i;
        LoadT(temp_storage.loadh).Load(&(g[i]), g_vals, valid_items, (T)0.0f);
        __syncthreads();
        LoadChar(temp_storage.loadc).Load(&(state1[i]), c1s, valid_items, 128);
        __syncthreads();
        LoadChar(temp_storage.loadc).Load(&(state2[i]), c2s, valid_items, 0);
        __syncthreads();
        LoadT(temp_storage.loadh).Load(&(p[i]), p_vals, valid_items);

        if((i + (threadIdx.x*NUM_PER_THREAD2) + NUM_PER_THREAD2) > n){ continue; }

        # pragma unroll 4
        for(unsigned int j = 0; j < NUM_PER_THREAD2; j++)
        {
            g_val = float(g_vals[j]);
            g_val *= gnorm_scale;
            s1_vals[j] = smem_quantiles1[c1s[j]];
            s1_vals[j] = s1_vals[j]*max1[0];

            s1_vals[j] = (s1_vals[j]*beta1) + (((1.0f-beta1)*g_val));

            c1s[j] = dQuantize<0>(smem_quantiles1, 0.0f, s1_vals[j]*new_max_val1);

            // make sure state1 term has still the same sign after quantization
            // (not needed for state2 term which has only positive values)
            if(signbit(smem_quantiles1[c1s[j]]) != signbit(s1_vals[j]))
            {
              if(s1_vals[j] > 0.0f)
                  c1s[j] += 1;
              else
                  c1s[j] -= 1;
            }

            s2_vals[j] = smem_quantiles2[c2s[j]];
            s2_vals[j] = s2_vals[j]*max2[0];
            s2_vals[j] = (s2_vals[j]*beta2) + (((1.0f-beta2)*g_val*g_val));
            c2s[j] = dQuantize<0>(smem_quantiles2, 0.0f, s2_vals[j]*new_max_val2);
        }

        # pragma unroll 4
        for(unsigned int j = 0; j < NUM_PER_THREAD2; j++)
        {
            p_vals[j] = (T)(((float)p_vals[j]) + ((update_scale*step_size*(s1_vals[j]/(sqrtf(s2_vals[j])+(correction2*eps))))));
            if(weight_decay > 0.0f)
                p_vals[j] = update_scale*((float)p_vals[j])*(1.0f-(lr*weight_decay));
        }

        StoreT(temp_storage.storeh).Store(&(p[i]), p_vals, valid_items);
        __syncthreads();
        StoreChar(temp_storage.storec).Store(&(state1[i]), c1s, valid_items);
        __syncthreads();
        StoreChar(temp_storage.storec).Store(&(state2[i]), c2s, valid_items);
        __syncthreads();
    }
}


template<typename T, int OPTIMIZER>
__global__ void
__launch_bounds__(NUM_THREADS, 2)
kPreconditionOptimizerStatic8bit1State(T* p, T* __restrict__ const g, unsigned char*__restrict__  const state1,
                float *unorm,
                const float beta1,
                const float eps, const int step,
                float* __restrict__ const quantiles1,
                float* max1, float* new_max1,
                const float weight_decay,
                const float gnorm_scale, const int n)
{
    const int n_full = gridDim.x * NUM_PER_BLOCK;
    const int base_idx = (blockIdx.x * blockDim.x * NUM_PER_THREAD);
    int valid_items = n - (blockIdx.x*NUM_PER_BLOCK) > NUM_PER_BLOCK ? NUM_PER_BLOCK : n - (blockIdx.x*NUM_PER_BLOCK);
    float g_val = 0.0f;
    float local_max_s1 = -FLT_MAX;
    float local_unorm = 0.0f;

    float s1_vals[NUM8BIT];
    T g_vals[NUM8BIT];
    unsigned char m_c1[NUM8BIT];

    typedef cub::BlockLoad<T, NUM_THREADS, NUM8BIT, cub::BLOCK_LOAD_WARP_TRANSPOSE> LoadT;
    typedef cub::BlockLoad<unsigned char, NUM_THREADS, NUM8BIT, cub::BLOCK_LOAD_WARP_TRANSPOSE> LoadUInt8;
    typedef cub::BlockReduce<float, NUM_THREADS> BlockReduce;


    __shared__ union {
        typename LoadT::TempStorage loadh;
        typename LoadUInt8::TempStorage loadc;
        typename BlockReduce::TempStorage reduce;
    } temp_storage;

    __shared__ float smem_quantiles1[256];

    if(threadIdx.x < 256)
      smem_quantiles1[threadIdx.x] = quantiles1[threadIdx.x];

    __syncthreads();

    for (unsigned int i = base_idx; i < n_full; i += gridDim.x*NUM_THREADS*NUM8BIT)
    {
        valid_items = n - i >= (TH*NUM_PER_THREAD) ? (TH*NUM_PER_THREAD) : n - i;

        __syncthreads();
        LoadT(temp_storage.loadh).Load(&(g[i]), g_vals, valid_items, (T)0.0f);
        __syncthreads();
        LoadUInt8(temp_storage.loadc).Load(&(state1[i]), m_c1, valid_items, 128);

        #pragma unroll 16
        for(int j = 0; j < NUM8BIT; j++)
        {
            g_val = g_vals[j];
            g_val *= gnorm_scale;
            s1_vals[j] = smem_quantiles1[m_c1[j]]*max1[0];
            switch(OPTIMIZER)
            {
                case MOMENTUM:
                    if(step == 1)
                      s1_vals[j] = (float)g_vals[j];
                    else
                      s1_vals[j] = s1_vals[j]*beta1 + ((float)g_vals[j]);
                    if(unorm != NULL)
                      local_unorm += s1_vals[j]*s1_vals[j];
                    break;
              case RMSPROP:
                    s1_vals[j] = s1_vals[j]*beta1 + ((1.0f-beta1)*(g_val*g_val));
                  break;
            }

            local_max_s1 = fmaxf(local_max_s1, fabsf(s1_vals[j]));
        }
    }

    __syncthreads();
    local_max_s1 = BlockReduce(temp_storage.reduce).Reduce(local_max_s1, cub::Max(), valid_items);
    if(threadIdx.x == 0){ atomicMax(&new_max1[0], local_max_s1); }
    if(unorm != NULL)
    {
      __syncthreads();
      local_unorm = BlockReduce(temp_storage.reduce).Reduce(local_unorm, cub::Sum(), valid_items);
      if(threadIdx.x == 0){ atomicAdd(&unorm[0], local_unorm); }
    }

}

template<typename T, int OPTIMIZER>
__global__ void
kOptimizerStatic8bit1State(T* p, T* const g, unsigned char* state1,
                const float *unorm, const float max_unorm, const float param_norm,
                const float beta1,
                const float eps, const int step, const float lr,
                float* __restrict__ const quantiles1,
                float* max1, float* new_max1,
                float weight_decay,
                const float gnorm_scale, const int n)
{

    const int n_full = (blockDim.x * gridDim.x)*NUM_PER_THREAD2;
    const int base_idx = (blockIdx.x * blockDim.x * NUM_PER_THREAD2);
    int valid_items = 0;
    float g_val = 0.0f;
    float s1_vals[NUM_PER_THREAD2];
    float new_max_val1 = 1.0f/new_max1[0];
    float update_scale = 1.0f;

    if(max_unorm > 0.0f)
    {
      update_scale = max_unorm > 0.0f ? sqrtf(unorm[0]) : 1.0f;
      if(update_scale > max_unorm*param_norm){ update_scale = (max_unorm*param_norm)/update_scale; }
      else{ update_scale = 1.0f; }
    }
    else{ update_scale = 1.0f; }

    unsigned char c1s[NUM_PER_THREAD2];
    T p_vals[NUM_PER_THREAD2];
    T g_vals[NUM_PER_THREAD2];
    typedef cub::BlockLoad<T, NUM_THREADS2, NUM_PER_THREAD2, cub::BLOCK_LOAD_WARP_TRANSPOSE> LoadT;
    typedef cub::BlockLoad<unsigned char, NUM_THREADS2, NUM_PER_THREAD2, cub::BLOCK_LOAD_WARP_TRANSPOSE> LoadChar;

    typedef cub::BlockStore<unsigned char, NUM_THREADS2, NUM_PER_THREAD2, cub::BLOCK_STORE_WARP_TRANSPOSE> StoreChar;
    typedef cub::BlockStore<T, NUM_THREADS2, NUM_PER_THREAD2, cub::BLOCK_STORE_WARP_TRANSPOSE> StoreT;

    __shared__ float smem_quantiles1[256];

    __shared__ union {
        typename LoadT::TempStorage loadh;
        typename LoadChar::TempStorage loadc;
        typename StoreChar::TempStorage storec;
        typename StoreT::TempStorage storeh;
    } temp_storage;

    if(threadIdx.x < 256)
        smem_quantiles1[threadIdx.x] = quantiles1[threadIdx.x];

    __syncthreads();

    for (unsigned int i = base_idx; i < n_full; i += gridDim.x*NUM_THREADS2*NUM_PER_THREAD2)
    {
        valid_items = n - i >= (TH*NUM_PER_THREAD) ? (TH*NUM_PER_THREAD) : n - i;
        LoadT(temp_storage.loadh).Load(&(g[i]), g_vals, valid_items, (T)0.0f);
        __syncthreads();
        LoadChar(temp_storage.loadc).Load(&(state1[i]), c1s, valid_items, 128);
        __syncthreads();
        LoadT(temp_storage.loadh).Load(&(p[i]), p_vals, valid_items);

        if((i + (threadIdx.x*NUM_PER_THREAD2) + NUM_PER_THREAD2) > n){ continue; }

        # pragma unroll 4
        for(unsigned int j = 0; j < NUM_PER_THREAD2; j++)
        {
            g_val = float(g_vals[j]);
            g_val *= gnorm_scale;
            if(weight_decay > 0.0f)
              g_val += ((float)p_vals[j])*weight_decay;
            s1_vals[j] = smem_quantiles1[c1s[j]]*max1[0];

            switch(OPTIMIZER)
            {
                case MOMENTUM:
                  if(step == 1)
                    s1_vals[j] = g_vals[j];
                  else
                    s1_vals[j] = s1_vals[j]*beta1 + ((float)g_vals[j]);

                  p_vals[j] = ((float)p_vals[j]) + (-lr*update_scale*(s1_vals[j]));
                  break;
              case RMSPROP:
                  s1_vals[j] = s1_vals[j]*beta1 + ((1.0f-beta1)*(g_val*g_val));
                  p_vals[j] = ((float)p_vals[j]) - (lr*__fdividef(g_val,sqrtf(s1_vals[j])+eps));
                  break;
            }

            c1s[j] = dQuantize<0>(smem_quantiles1, 0.0f, s1_vals[j]*new_max_val1);

            // make sure state1 term has still the same sign after quantization
            if(signbit(smem_quantiles1[c1s[j]]) != signbit(s1_vals[j]))
            {
              if(s1_vals[j] > 0.0f)
                  c1s[j] += 1;
              else
                  c1s[j] -= 1;
            }
        }

        StoreT(temp_storage.storeh).Store(&(p[i]), p_vals, valid_items);
        __syncthreads();
        StoreChar(temp_storage.storec).Store(&(state1[i]), c1s, valid_items);
        __syncthreads();
    }
}


template<typename T, int BLOCK_SIZE, int NUM_VALS>
__global__ void kPercentileClipping(T * __restrict__ g, float *gnorm_vec, int step, const int n)
{
  const int n_full = (BLOCK_SIZE*(n/BLOCK_SIZE)) + (n % BLOCK_SIZE == 0 ? 0 : BLOCK_SIZE);
  int valid_items = 0;

  typedef cub::BlockReduce<float, BLOCK_SIZE/NUM_VALS> BlockReduce;
  typedef cub::BlockLoad<T, BLOCK_SIZE/NUM_VALS, NUM_VALS, cub::BLOCK_LOAD_WARP_TRANSPOSE> LoadT;

  __shared__ typename BlockReduce::TempStorage reduce;

  __shared__ typename LoadT::TempStorage loadT;
  T vals[NUM_VALS];
  float local_sum = 0.0f;

  for (unsigned int i = (blockIdx.x * BLOCK_SIZE); i < n_full; i += gridDim.x*BLOCK_SIZE)
  {
      valid_items = n - i > BLOCK_SIZE ? BLOCK_SIZE : n - i;
      local_sum = 0.0f;

      __syncthreads();
      LoadT(loadT).Load(&(g[i]), vals, valid_items, (T)0.0f);

     #pragma unroll NUM_VALS
     for(int j = 0; j < NUM_VALS; j++)
       local_sum += ((float)vals[j])*((float)vals[j]);

    local_sum = BlockReduce(reduce).Sum(local_sum, valid_items);
    if(threadIdx.x == 0)
    {
      if(step == 1)
      {
        // initialize with the same norm for all positions
        //#pragma unroll 10
        for(int j = 0; j < 100; j++)
          atomicAdd(&gnorm_vec[j], local_sum);
      }
      else
          atomicAdd(&gnorm_vec[step % 100], local_sum);
    }

  }
}


#define LANES 2
#define QUAD 3
template<typename T, int OPTIMIZER, int BLOCK_SIZE, int N_PER_TH>
__launch_bounds__(256, 3)
__global__ void
kOptimizerStatic8bit2StateBlockwise(T* p, T* __restrict__ const g, unsigned char* state1, unsigned char* state2,
                const float beta1, const float beta2,
                const float eps, const int step, const float lr,
                float* __restrict__ const quantiles1, float* __restrict__ const quantiles2,
                float* absmax1, float* absmax2,
                float weight_decay,
                const float gnorm_scale, const bool skip_zeros, const int n)
{

    //const int n_full = n + (n%BLOCK_SIZE);
    const int n_full = gridDim.x * BLOCK_SIZE;
    const int base_idx = (blockIdx.x * BLOCK_SIZE);
    int valid_items = 0;
    float g_val = 0.0f;
    float s1_vals[N_PER_TH];
    float s2_vals[N_PER_TH];
    // 2-5%
    const float correction1 = 1.0f - __powf(beta1, step);
    const float correction2 = sqrtf(1.0f -__powf(beta2, step));
    const float step_size = __fdividef(-lr*correction2,correction1);
    const int lane_id = threadIdx.x % LANES;
    float new_local_abs_max1 = -FLT_MAX;
    float new_local_abs_max2 = -FLT_MAX;
    float quadrants1[QUAD];
    float quadrants2[QUAD];

    unsigned char c1s[N_PER_TH];
    unsigned char c2s[N_PER_TH];
    T g_vals[N_PER_TH];
    typedef cub::BlockLoad<T, BLOCK_SIZE/N_PER_TH, N_PER_TH, cub::BLOCK_LOAD_WARP_TRANSPOSE> LoadT;
    typedef cub::BlockLoad<unsigned char, BLOCK_SIZE/N_PER_TH, N_PER_TH, cub::BLOCK_LOAD_WARP_TRANSPOSE> LoadChar;

    typedef cub::BlockStore<unsigned char, BLOCK_SIZE/N_PER_TH, N_PER_TH, cub::BLOCK_STORE_WARP_TRANSPOSE> StoreChar;
    typedef cub::BlockStore<T, BLOCK_SIZE/N_PER_TH, N_PER_TH, cub::BLOCK_STORE_WARP_TRANSPOSE> StoreT;

    __shared__ float smem_quantiles1[LANES][257];
    __shared__ float smem_quantiles2[LANES][257];
    typedef cub::BlockReduce<float, BLOCK_SIZE/N_PER_TH> BlockReduce1;
    typedef cub::BlockReduce<float, BLOCK_SIZE/N_PER_TH> BlockReduce2;
    __shared__ typename BlockReduce1::TempStorage reduce1;
    __shared__ typename BlockReduce2::TempStorage reduce2;
    __shared__ float smem_exchange1[1];
    __shared__ float smem_exchange2[1];

    __shared__ union {
        typename LoadT::TempStorage loadh;
        typename LoadChar::TempStorage loadc;
        typename StoreChar::TempStorage storec;
        typename StoreT::TempStorage storeh;
    } temp_storage;
    // init: 0.2 -> 0.23

    // 0.23 -> 0.23
      smem_quantiles1[0][threadIdx.x] = quantiles1[threadIdx.x];
      smem_quantiles2[0][threadIdx.x] = quantiles2[threadIdx.x];
      # pragma unroll
      for(unsigned int j = 1; j < LANES; j++)
      {
        smem_quantiles1[j][threadIdx.x] = smem_quantiles1[0][threadIdx.x];
        smem_quantiles2[j][threadIdx.x] = smem_quantiles2[0][threadIdx.x];
      }

    __syncthreads();

    #pragma unroll
    for(int k = 0; k < QUAD; k++)
    {
      quadrants1[k] = smem_quantiles1[lane_id][(k*256/(QUAD+1)) + (256/(QUAD+1)-1)];
      quadrants2[k] = smem_quantiles2[lane_id][(k*256/(QUAD+1)) + (256/(QUAD+1)-1)];
    }


    for (unsigned int i = base_idx; i < n_full; i += gridDim.x*BLOCK_SIZE)
    {
        // loads: 0.23 -> 0.85/1.44
        valid_items = n - i >= BLOCK_SIZE ? BLOCK_SIZE : n - i;
        __syncthreads();
        LoadT(temp_storage.loadh).Load(&(g[i]), g_vals, valid_items, (T)0.0f);
        __syncthreads();
        LoadChar(temp_storage.loadc).Load(&(state1[i]), c1s, valid_items, 128);
        __syncthreads();
        LoadChar(temp_storage.loadc).Load(&(state2[i]), c2s, valid_items, 0);

        new_local_abs_max1 = -FLT_MAX;
        new_local_abs_max2 = -FLT_MAX;

        //  update: 2.48/1.57 -> 2.51/1.60
        # pragma unroll N_PER_TH
        for(unsigned int j = 0; j < N_PER_TH; j++)
        {
            g_val = float(g_vals[j]);
            g_val *= gnorm_scale;
						if(!skip_zeros || (skip_zeros && ((float)g_vals[j] != 0.0f)))
						{
							s1_vals[j] = smem_quantiles1[lane_id][c1s[j]]*absmax1[i/BLOCK_SIZE];
							s1_vals[j] = (s1_vals[j]*beta1) + (((1.0f-beta1)*g_val));

							s2_vals[j] = smem_quantiles2[lane_id][c2s[j]]*absmax2[i/BLOCK_SIZE];
							s2_vals[j] = (s2_vals[j]*beta2) + (((1.0f-beta2)*g_val*g_val));
						}

            new_local_abs_max1 = fmaxf(new_local_abs_max1, fabsf(s1_vals[j]));
            new_local_abs_max2 = fmaxf(new_local_abs_max2, fabsf(s2_vals[j]));
        }


        //  reduce: 2.51/1.60 -> 2.67/1.69
        new_local_abs_max1 = BlockReduce1(reduce1).Reduce(new_local_abs_max1, cub::Max());
        new_local_abs_max2 = BlockReduce2(reduce2).Reduce(new_local_abs_max2, cub::Max());

        if(threadIdx.x == 0)
        {
          smem_exchange1[0] = new_local_abs_max1;
          smem_exchange2[0] = new_local_abs_max2;
        }

        __syncthreads();

        if(threadIdx.x == 0)
        {
          absmax1[i/BLOCK_SIZE] = new_local_abs_max1;
          absmax2[i/BLOCK_SIZE] = new_local_abs_max2;
        }
        else
        {
          new_local_abs_max1 = smem_exchange1[0];
          new_local_abs_max2 = smem_exchange2[0];
        }

        __syncthreads();
        LoadT(temp_storage.loadh).Load(&(p[i]), g_vals, valid_items, (T)0.0f);
        //  reduce: 2.67/1.69 -> 2.67/1.70
        # pragma unroll N_PER_TH
        for(unsigned int j = 0; j < N_PER_TH; j++)
        {
						if(!skip_zeros || (skip_zeros && ((float)g_vals[j] != 0.0f)))
						{
							g_vals[j] = (T)(((float)g_vals[j]) + ((step_size*(__fdividef(s1_vals[j],(sqrtf(s2_vals[j])+(correction2*eps)))))));
							if(weight_decay > 0.0f)
									g_vals[j] = ((float)g_vals[j])*(1.0f-(lr*weight_decay));
						}
        }

        //  store: 0.85/1.44 -> 2.48/1.57
        __syncthreads();
        StoreT(temp_storage.storeh).Store(&(p[i]), g_vals, valid_items);

        //  quantizaztion: 2.67/1.70  -> 3.4/3.3
        # pragma unroll N_PER_TH
        for(unsigned int j = 0; j < N_PER_TH; j++)
        {
            c1s[j] = quantize_2D<1>(quadrants1, smem_quantiles1[lane_id], __fdividef(s1_vals[j],new_local_abs_max1));
            c2s[j] = quantize_2D<0>(quadrants2, smem_quantiles2[lane_id], __fdividef(s2_vals[j],new_local_abs_max2));

            // make sure state1 term has still the same sign after quantization
            // (not needed for state2 term which has only positive values)
            if(signbit(smem_quantiles1[lane_id][c1s[j]]) != signbit(s1_vals[j]))
            {
              if(s1_vals[j] > 0.0f)
                  c1s[j] += 1;
              else
                  c1s[j] -= 1;
            }
        }

        __syncthreads();
        StoreChar(temp_storage.storec).Store(&(state1[i]), c1s, valid_items);
        __syncthreads();
        StoreChar(temp_storage.storec).Store(&(state2[i]), c2s, valid_items);
    }
}


#define LANES 2
#define QUAD 3
template<typename T, int OPTIMIZER, int BLOCK_SIZE, int N_PER_TH>
__launch_bounds__(256, 3)
__global__ void
kOptimizerStatic8bit1StateBlockwise(T* p, T* __restrict__ const g, unsigned char* state1,
                const float beta1, const float beta2,
                const float eps, const int step, const float lr,
                float* __restrict__ const quantiles1,
                float* absmax1,
                float weight_decay,
                const float gnorm_scale, const bool skip_zeros, const int n)
{

    //const int n_full = n + (n%BLOCK_SIZE);
    const int n_full = gridDim.x * BLOCK_SIZE;
    const int base_idx = (blockIdx.x * BLOCK_SIZE);
    int valid_items = 0;
    float g_val = 0.0f;
    float s1_vals[N_PER_TH];
    // 2-5%
    const int lane_id = threadIdx.x % LANES;
    float new_local_abs_max1 = -FLT_MAX;
    float quadrants1[QUAD];

    unsigned char c1s[N_PER_TH];
    T g_vals[N_PER_TH];
		T p_vals[N_PER_TH];

    typedef cub::BlockLoad<T, BLOCK_SIZE/N_PER_TH, N_PER_TH, cub::BLOCK_LOAD_WARP_TRANSPOSE> LoadT;
    typedef cub::BlockLoad<unsigned char, BLOCK_SIZE/N_PER_TH, N_PER_TH, cub::BLOCK_LOAD_WARP_TRANSPOSE> LoadChar;

    typedef cub::BlockStore<unsigned char, BLOCK_SIZE/N_PER_TH, N_PER_TH, cub::BLOCK_STORE_WARP_TRANSPOSE> StoreChar;
    typedef cub::BlockStore<T, BLOCK_SIZE/N_PER_TH, N_PER_TH, cub::BLOCK_STORE_WARP_TRANSPOSE> StoreT;

    __shared__ float smem_quantiles1[LANES][257];
    typedef cub::BlockReduce<float, BLOCK_SIZE/N_PER_TH> BlockReduce1;
    __shared__ typename BlockReduce1::TempStorage reduce1;
    __shared__ float smem_exchange1[1];

    __shared__ union {
        typename LoadT::TempStorage loadh;
        typename LoadChar::TempStorage loadc;
        typename StoreChar::TempStorage storec;
        typename StoreT::TempStorage storeh;
    } temp_storage;
    // init: 0.2 -> 0.23

    // 0.23 -> 0.23
		smem_quantiles1[0][threadIdx.x] = quantiles1[threadIdx.x];
		# pragma unroll
		for(unsigned int j = 1; j < LANES; j++)
			smem_quantiles1[j][threadIdx.x] = smem_quantiles1[0][threadIdx.x];

    __syncthreads();

    #pragma unroll
    for(int k = 0; k < QUAD; k++)
      quadrants1[k] = smem_quantiles1[lane_id][(k*256/(QUAD+1)) + (256/(QUAD+1)-1)];

    for (unsigned int i = base_idx; i < n_full; i += gridDim.x*BLOCK_SIZE)
    {
        // loads: 0.23 -> 0.85/1.44
        valid_items = n - i >= BLOCK_SIZE ? BLOCK_SIZE : n - i;
        __syncthreads();
        LoadT(temp_storage.loadh).Load(&(g[i]), g_vals, valid_items, (T)0.0f);
        __syncthreads();
        LoadChar(temp_storage.loadc).Load(&(state1[i]), c1s, valid_items, 128);
        __syncthreads();
        LoadT(temp_storage.loadh).Load(&(p[i]), p_vals, valid_items, (T)0.0f);

        new_local_abs_max1 = -FLT_MAX;

        //  update: 2.48/1.57 -> 2.51/1.60
        # pragma unroll N_PER_TH
        for(unsigned int j = 0; j < N_PER_TH; j++)
        {
            g_val = float(g_vals[j]);
            g_val *= gnorm_scale;
						if(!skip_zeros || (skip_zeros && ((float)g_vals[j] != 0.0f)))
						{
							if(weight_decay > 0.0f)
								g_val += ((float)p_vals[j])*weight_decay;

							s1_vals[j] = smem_quantiles1[lane_id][c1s[j]]*absmax1[i/BLOCK_SIZE];

							switch(OPTIMIZER)
							{
									case MOMENTUM:
										if(step == 1)
											s1_vals[j] = g_val;
										else
											s1_vals[j] = (s1_vals[j]*beta1) + g_val;
										break;
									case RMSPROP:
										s1_vals[j] = s1_vals[j]*beta1 + ((1.0f-beta1)*(g_val*g_val));
										break;
									case ADAGRAD:
										s1_vals[j] = s1_vals[j] + (g_val*g_val);
										break;
							}
						}

            new_local_abs_max1 = fmaxf(new_local_abs_max1, fabsf(s1_vals[j]));
        }


        //  reduce: 2.51/1.60 -> 2.67/1.69
        new_local_abs_max1 = BlockReduce1(reduce1).Reduce(new_local_abs_max1, cub::Max());

        if(threadIdx.x == 0)
          smem_exchange1[0] = new_local_abs_max1;

        __syncthreads();

        if(threadIdx.x == 0)
          absmax1[i/BLOCK_SIZE] = new_local_abs_max1;
        else
          new_local_abs_max1 = smem_exchange1[0];

        //  reduce: 2.67/1.69 -> 2.67/1.70
        # pragma unroll N_PER_TH
        for(unsigned int j = 0; j < N_PER_TH; j++)
				{
						if(!skip_zeros || (skip_zeros && ((float)g_vals[j] != 0.0f)))
						{
							switch(OPTIMIZER)
							{
									case MOMENTUM:
										p_vals[j] = ((float)p_vals[j]) - lr*(s1_vals[j]);
										break;
									case RMSPROP:
										g_val = g_vals[j];
										p_vals[j] = ((float)p_vals[j]) - lr*(__fdividef(g_val, sqrtf(s1_vals[j])+eps));
										break;
									case ADAGRAD:
										g_val = g_vals[j];
										p_vals[j] = ((float)p_vals[j]) - lr*(__fdividef(g_val, sqrtf(s1_vals[j])+eps));
										break;
							}
						}
				}

        //  store: 0.85/1.44 -> 2.48/1.57
        __syncthreads();
        StoreT(temp_storage.storeh).Store(&(p[i]), p_vals, valid_items);

        //  quantizaztion: 2.67/1.70  -> 3.4/3.3
        # pragma unroll N_PER_TH
        for(unsigned int j = 0; j < N_PER_TH; j++)
        {
            c1s[j] = quantize_2D<1>(quadrants1, smem_quantiles1[lane_id], __fdividef(s1_vals[j],new_local_abs_max1));

            // make sure state1 term has still the same sign after quantization
            // (not needed for state2 term which has only positive values)
            if(signbit(smem_quantiles1[lane_id][c1s[j]]) != signbit(s1_vals[j]))
            {
              if(s1_vals[j] > 0.0f)
                  c1s[j] += 1;
              else
                  c1s[j] -= 1;
            }
        }

        __syncthreads();
        StoreChar(temp_storage.storec).Store(&(state1[i]), c1s, valid_items);
    }
}

template<typename T, int THREADS, int ITEMS_PER_THREAD, int TILE_ROWS, int TILE_COLS, int SPARSE_DECOMP> __global__ void kgetColRowStats(T * __restrict__ A, float *rowStats, float *colStats, int * nnz_count_row, float nnz_threshold, int rows, int cols, int tiledRows, int tiledCols)
{
  // 0. reset stats to -FLT_MAX
  // 1. load row-by-row ITEMS_PER_THREAD (TILE_SIZE==THREADS*ITEMS_PER_THREAD)
  // 2. compute col max (per thread); store in smem due to register pressure
  // 3. compute row max (per block); store in smem to accumulate full global mem transation
  // 4. store data via atomicMax

  // each block loads TILE_COLs columns and TILE_ROW rows
  // after reading a tile the row counter increase by TILE_ROWS
  // the col counter reset after reading TILE_COL elements
  const int base_row = ((blockIdx.x*TILE_COLS)/tiledCols)*TILE_ROWS;
  // col increases by TILE_SIZE for each block and wraps back to 0 after tiledCols is reached
  const int base_col = (blockIdx.x*TILE_COLS) % tiledCols;
  const int base_idx = (base_row*cols) + base_col;
  const int items_per_load = ITEMS_PER_THREAD*THREADS;

  typedef cub::BlockLoad<T, THREADS, ITEMS_PER_THREAD, cub::BLOCK_LOAD_VECTORIZE> LoadT;
  typedef cub::BlockReduce<float, THREADS> BlockRowReduce;
  typedef cub::BlockReduce<int, THREADS> BlockRowSum;
  typedef cub::BlockExchange<float, THREADS, ITEMS_PER_THREAD> BlockExchange;

  __shared__ union {
    typename BlockExchange::TempStorage exchange;
    typename BlockRowReduce::TempStorage rowreduce;
    typename BlockRowSum::TempStorage rowsum;
    typename LoadT::TempStorage loadt;
  } temp_storage;

  __shared__ float smem_row_absmax_values[ITEMS_PER_THREAD*THREADS];
  __shared__ int smem_row_nnz_values[TILE_ROWS];

  half local_data[ITEMS_PER_THREAD];
  float local_data_fp32[ITEMS_PER_THREAD];
  float local_col_absmax_values[ITEMS_PER_THREAD];
  int local_row_nnz_count = 0;
  float row_absmax = -FLT_MAX;

  // 0. reset stats to -FLT_MAX
  for(int j = 0; j < ITEMS_PER_THREAD; j++)
  {
    //smem_col_absmax_values[threadIdx.x + (j*THREADS)] = -FLT_MAX;
    smem_row_absmax_values[threadIdx.x + (j*THREADS)] = -FLT_MAX;
    smem_row_nnz_values[threadIdx.x + (j*THREADS)] = 0;
  }

  #pragma unroll ITEMS_PER_THREAD
  for(int j = 0; j < ITEMS_PER_THREAD; j++)
    local_col_absmax_values[j] = -FLT_MAX;

  __syncthreads();

  int valid_items = cols - base_col > items_per_load ? items_per_load : cols - base_col;
  int i = base_idx;
  // we load row after row from the base_position
  // 1. load row-by-row ITEMS_PER_THREAD (TILE_SIZE==THREADS*ITEMS_PER_THREAD)
  for(int row = 0; row < TILE_ROWS; row++)
  {
    if(base_row+row >= rows){ break; }
    local_row_nnz_count = 0;
    i = base_idx + ((row)*cols);
    // each thread gets data from the same column
    __syncthreads();
    LoadT(temp_storage.loadt).Load(&(A[i]), local_data, valid_items, __float2half(0.0f));

    #pragma unroll ITEMS_PER_THREAD
    for(int j = 0; j < ITEMS_PER_THREAD; j++)
      local_data[j] = fabsf(local_data[j]);


    if(SPARSE_DECOMP)
      #pragma unroll ITEMS_PER_THREAD
      for(int j = 0; j < ITEMS_PER_THREAD; j++)
      {
        if((float)local_data[j] >= nnz_threshold)
        {
          local_row_nnz_count += 1;
          local_data[j] = 0.0f;
        }
      }

    // 2. compute col max (per thread); store in smem due to register pressure
    #pragma unroll ITEMS_PER_THREAD
    for(int j = 0; j < ITEMS_PER_THREAD; j++)
      // take the col max for this row
      // we use shared memory because register pressure is too high if we do this locally
      //smem_col_absmax_values[threadIdx.x + (j*THREADS)] = fmaxf(smem_col_absmax_values[threadIdx.x + (j*THREADS)], __half2float(local_data[j]));
      local_col_absmax_values[j] = fmaxf(local_col_absmax_values[j], __half2float(local_data[j]));

    // 3. compute row max (per block); store in smem to accumulate full global mem transation

    // this is slow as it uses extra registers, but we need this to be compatible with Kepler and Maxwell (no fp16 units)
    #pragma unroll ITEMS_PER_THREAD
    for(int j = 0; j < ITEMS_PER_THREAD; j++)
      local_data_fp32[j] = local_data[j];

    __syncthreads();

    row_absmax = (float)BlockRowReduce(temp_storage.rowreduce).Reduce(local_data_fp32, cub::Max());
    if(SPARSE_DECOMP)
    {
      __syncthreads();
      local_row_nnz_count = BlockRowSum(temp_storage.rowsum).Sum(local_row_nnz_count);
    }
    // we store the data temporarily in shared memory so we
    // can execute a full atomic block transaction into global memory later
    // we use a striped arrangement [0, 8, 16, 24, ..] for t0 for faster stores
    if(threadIdx.x == 0)
    {
      smem_row_absmax_values[(row % ITEMS_PER_THREAD) + ((row/ITEMS_PER_THREAD)*ITEMS_PER_THREAD)] = row_absmax;
      // each blockIdx.x process 16 rows and 64*4=256 columns -> we sum nnz over 256 columns and have 16 values per block
      smem_row_nnz_values[row] = local_row_nnz_count;
    }

    __syncthreads();

  }

  // 4. store data via atomicMax
  // to store col data efficienctly we need to rewrite the smem blocked data [0, 1, 2, 3...] for t0
  // into a striped arangement: [0, 8, 16, 24, ..] for t0
  __syncthreads();
  BlockExchange(temp_storage.exchange).BlockedToStriped(local_col_absmax_values);

  #pragma unroll ITEMS_PER_THREAD
  for(int j = 0; j < ITEMS_PER_THREAD; j++)
    if(base_col+threadIdx.x+(j*THREADS) < cols)
    {
      float val = colStats[base_col+(threadIdx.x+(j*THREADS))];
      if(val < local_col_absmax_values[j])
        atomicMax(&colStats[base_col+(threadIdx.x+(j*THREADS))], local_col_absmax_values[j]);
    }

  for(int j = 0; j < ITEMS_PER_THREAD; j++)
    if(base_row+threadIdx.x+(j*THREADS) < rows)
    {
      float val = rowStats[base_row+(threadIdx.x+(j*THREADS))];
      if(val < smem_row_absmax_values[threadIdx.x+(j*THREADS)])
        atomicMax(&rowStats[base_row+(threadIdx.x+(j*THREADS))], smem_row_absmax_values[threadIdx.x+(j*THREADS)]);
    }

    if(SPARSE_DECOMP)
      if(threadIdx.x < TILE_ROWS)
        nnz_count_row[blockIdx.x*TILE_ROWS+threadIdx.x+1] = smem_row_nnz_values[threadIdx.x];

}

template __global__ void kgetColRowStats<half, 64, 4, 16, 64*4, 0>(half * __restrict__ A, float *rowStats, float *colStats, int * nnz_count_row, float nnz_threshold, int rows, int cols, int tiledRows, int tiledCols);
template __global__ void kgetColRowStats<half, 64, 4, 16, 64*4, 1>(half * __restrict__ A, float *rowStats, float *colStats, int * nnz_count_row, float nnz_threshold, int rows, int cols, int tiledRows, int tiledCols);

#define MM_DEQUANT_CONST 6.200012e-05f //1.0f/(127.0f*127.0f)

template <int ITEMS_PER_THREAD, int SUBTILE_ROWS, int THREADS>__global__ void kdequant_mm_int32_fp16(int *__restrict__ const A, float *__restrict__ const rowStats, float *__restrict__ const colStats, half *out, float* newRowStats, float* newcolStats, half *__restrict__ const bias, const int numRows, const int numCols, const int tileCols, const int n)
{

  // Strategy: To dequantize we need to load col/row statistics. This can be very expensive
  // since different row/col stats need to be loaded with each thread.
  // (1, bad algorithm) Loading 32 items per thread would only occur 1 row load, but this increases register pressure
  // and would lead to low global load utilization.
  // (2, bad algorithm) If each thread loads some columns and multiple rows one needs to do lot of row loads
  // for each thread and this is duplicated by a factor of 32/num-cols-per-thread.
  // (3, good algorithm) Combining (1) and (2) we use sub-tiles of size 32xk in shared memory per threadblock.
  // This allows for efficient row/col loading from shared memory within the tile.
  // We can run for example 32x128 sub-tiles and warp-strided loads of 4 elements so that each thread has
  // the same col statistic but needs to load 4 row stats from shared memory. To prevent bank conflicts
  // we use a block-striped shared memory config [1, 31, 63, 95] so no bank conflicts happen during the
  // shared memory loads.

  // data is in 32 column-tile major with tile width 32 columns and numRows rows
  // L1. Load sub-tile row/col statistics. Each thread only holds 1 col, load rows into shared memory.
  // L2. Load data in warp-striped arangement (t0 holds colidx [0, 0, 0, 0], rowidx [0, 1, 2, 3])
  // C1. Compute val(row_stat*col_stat)/(127*127) (load 1/(127*127 into register))
  // C2. Compute normalization values and store col values in register
  // S1. Store C1 into 16-bit output
  // S2. Store col/row statistics of new buffer in shared memory

  // We allow for sub-tiles to span multiple col32 tiles. This is okay
  // since the items per thread only rely on a single column statistic.


  const int n_out = numRows*numCols;

  int num_row_tiles = (numRows/SUBTILE_ROWS) + (numRows % SUBTILE_ROWS == 0 ? 0 : 1);
  // we have tiles of size numRows*32, thus col only increases every numRows
  // num_row_tiles is the tiles after which the column increases by 32
  // blockIdx.x is the index of the current tile
  int col = ((threadIdx.x % 32) + ((blockIdx.x/num_row_tiles)*32));
  // base_row increases by SUBTILE_ROWS every block. It wraps back to zero once num_row_tiles is reached
  int base_row = (blockIdx.x*SUBTILE_ROWS) % (num_row_tiles*SUBTILE_ROWS);

  // SUBTILE_ROWS is independent from ITEMS_PER_THREAD is independent from THREADS
  // subtiles have 32*SUBTILE_ROWS elements <= THREADS*ITEMS_PER_THREAD
  // Total subtiles should be n/(32*SUBTILE_ROWS) where each subtile has SUBTILE_ROW*32/4 threads.
  // For example for a 1024x1024 matrix with 128 SUBTILE_ROWS and 4 ITEMS_PER_THREAD we have
  // 1024*1024/(128*32) = 256 tiles
  // 256 tiles are 256*128*32/4 = 256*1024 threads

  // 1. Figure out how index relates to the start of the sub-tile
  // 2. Each thread < SUBTILE_ROWS calculates row index
  // 3. Load striped and store in shared memory

  int local_values[ITEMS_PER_THREAD];
  half local_output[ITEMS_PER_THREAD];
  float local_rowStats[ITEMS_PER_THREAD];
  __shared__ float smem_rowStats[SUBTILE_ROWS];

  typedef cub::BlockLoad<int, THREADS, ITEMS_PER_THREAD, cub::BLOCK_LOAD_DIRECT> LoadInt32;
  typedef cub::BlockExchange<int, THREADS, ITEMS_PER_THREAD> ExchangeInt32;
  __shared__ typename LoadInt32::TempStorage loadint32;
  __shared__ typename ExchangeInt32::TempStorage exchangeint32;


  // L1. Load sub-tile row/col statistics. Each thread only holds 1 col, load rows into shared memory.
  float colStat = col >= numCols ? 0.0f : colStats[col];
  float local_biasValue = ((bias == NULL) || (col >= numCols)) ? 0.0f : __half2float(bias[col]);
  // no block loads for rows for now -- keep it simple
  for(int j = threadIdx.x; j < SUBTILE_ROWS; j+=blockDim.x)
  {
    // todo: is this global mem access slow due to overlaps or does the L1 cache work well here?
    int row = (base_row+j) % numRows; // wrap around
    // each warp accesses the same element, for four consequitive elements
    // todo: update description about striped shared memory, it is not needed
    // rowidx: [0, 1, 2, 3...] and each warp reads ITEMS_PER_THREAD consequitive elements
    smem_rowStats[j] = rowStats[row];
  }
  __syncthreads();


  // each block processes SUBTILE_ROWS*32 elements
  const int items_per_load = THREADS*ITEMS_PER_THREAD;
  const int rows_per_load = items_per_load/32;

  int subtile_base_row = (threadIdx.x / 32)*ITEMS_PER_THREAD; // row within the tile
  int row_offset = 0;
  // subtile_idx starts at the base_row*32 + the total offset for a full numRow*32 tile is passed
  int subtile_start = (blockIdx.x/num_row_tiles)*(numRows*32) + (base_row*32);
  for(int subtile_idx = subtile_start; subtile_idx < subtile_start + (SUBTILE_ROWS*32); subtile_idx+=items_per_load)
  {
    int valid_rows = numRows - (base_row+row_offset) > rows_per_load ? rows_per_load : numRows - (base_row+row_offset);
    int valid_items = valid_rows*32;
    if(valid_items <= 0) // the sub-tile might have more elements than the tile itself
      break;

    // L2. Load data in warp-striped arangement (t0 holds colidx [0, 0, 0, 0], rowidx [0, 1, 2, 3])
    LoadInt32(loadint32).Load(&(A[subtile_idx]), local_values, valid_items, 0);
    ExchangeInt32(exchangeint32).BlockedToWarpStriped(local_values, local_values);

    #pragma unroll ITEMS_PER_THREAD
    for(int j = 0; j < ITEMS_PER_THREAD; j++)
      local_rowStats[j] = smem_rowStats[subtile_base_row+row_offset+j];

    #pragma unroll ITEMS_PER_THREAD
    for(int j = 0; j < ITEMS_PER_THREAD; j++)
      local_output[j] = __float2half((local_values[j]*MM_DEQUANT_CONST*local_rowStats[j]*colStat) + local_biasValue);
      //absmax_col = fmax(fabsf(local_output[j]), absmax_col);

    // we store data in row major
    // to store data efficiently, we want to use block exchange: [0, 32, 64, 92] -> [0, 1, 2, 3]
    // so that each thread holds ITEMS_PER_THREAD consecutive items for each row
    // this way throughput into storage is increased by a factor of ~2x
    // for now we use a simple store
    #pragma unroll ITEMS_PER_THREAD
    for(int j = 0; j < ITEMS_PER_THREAD; j++)
    {
      int outIdx = col + ((base_row+subtile_base_row+row_offset+j)*numCols);
      if(outIdx< n_out && col < numCols)
        out[outIdx] = local_output[j];
    }

    row_offset += rows_per_load;
  }
}


template <int THREADS, int ITEMS_PER_THREAD, int TILE_ROWS, int TILE_COLS, int SPARSE_DECOMP> __global__ void kDoubleRowColQuant(half *__restrict__ const A, float *__restrict__ const rowStats, float * __restrict__ const colStats, char *out_col_normed, char *out_row_normed, int *rowidx, int *colidx, half *val, int * __restrict__ nnz_block_ptr, float threshold, int rows, int cols, int tiledCols)
{
  // assumes TILE_SIZE == THREADS*ITEMS_PER_THREAD
  // Each thread reads the same column but multiple rows
  // Rows are loaded in shared memory and access is shared across the threadblock (broadcast)

  // 0. Load row stats data into shared memory; load col stat (1 fixed per thread)
  // 1. Load data row by row (should be at least with TILE_SIZE = 512)
  // 2. quantize data with row/col stats
  // 3. Store data (TILE_SIZE = 512 is a bit slow, but should still be close enough to good performance)

  // each block loads TILE_COLs columns and TILE_ROW rows
  // after reading a tile the row counter increase by TILE_ROWS
  // the col counter reset after reading TILE_COL elements
  const int base_row = ((blockIdx.x*TILE_COLS)/tiledCols)*TILE_ROWS;
  // col increases by TILE_SIZE for each block and wraps back to 0 after tiledCols is reached
  const int base_col = (blockIdx.x*TILE_COLS) % tiledCols;
  const int base_idx = (base_row*cols) + base_col;
  const int items_per_load = ITEMS_PER_THREAD*THREADS;

  typedef cub::BlockLoad<half, THREADS, ITEMS_PER_THREAD, cub::BLOCK_LOAD_VECTORIZE> LoadHalf;
  __shared__ typename LoadHalf::TempStorage loadhalf;
  typedef cub::BlockStore<char, THREADS, ITEMS_PER_THREAD, cub::BLOCK_STORE_VECTORIZE> StoreInt8;
  __shared__ typename StoreInt8::TempStorage storeint8;

  __shared__ float smem_row_stats[TILE_ROWS];
  __shared__ unsigned int smem_nnz_row_idx[TILE_ROWS];

  half local_data[ITEMS_PER_THREAD];
  float local_col_stats[ITEMS_PER_THREAD];
  char local_quantized_data[ITEMS_PER_THREAD];

  // 0. Load row stats data into shared memory; load col stat (1 fixed per thread)
  #pragma unroll ITEMS_PER_THREAD
  for(int j = 0; j < ITEMS_PER_THREAD; j++)
    if(base_col+(threadIdx.x*ITEMS_PER_THREAD) + j < cols)
      local_col_stats[j] = __fdividef(127.0f, colStats[base_col+(threadIdx.x*ITEMS_PER_THREAD)+j]);

  for(int i = threadIdx.x; i < TILE_ROWS; i+=blockDim.x)
  {
    if(base_row + i < rows)
      smem_row_stats[i] = rowStats[base_row+i];

    if(SPARSE_DECOMP)
      smem_nnz_row_idx[i] = nnz_block_ptr[(TILE_ROWS*blockIdx.x) + i];
  }
  __syncthreads();

  // we load row after row from the base_position
  // 1. Load data row by row (should be at least with TILE_SIZE = 512)
  for(int row = 0; row < TILE_ROWS; row++)
  {
    if(base_row + row >= rows){ break; }
    int i = base_idx + (row*cols);
    int valid_items = cols - base_col > items_per_load ? items_per_load : cols - base_col;


    LoadHalf(loadhalf).Load(&(A[i]), local_data, valid_items, 0.0f);
    float row_stat = __fdividef(127.0f, smem_row_stats[row]);

    // 2. quantize data with row/col stats
    #pragma unroll ITEMS_PER_THREAD
    for(int j = 0; j < ITEMS_PER_THREAD; j++)
    {
      // we already pre-normalized the col/row stat:
      // what this does is float/absmax*127 = int8
      if(SPARSE_DECOMP)
      {
        if(fabsf((float)local_data[j]) >= threshold)
        {
          local_quantized_data[j] = 0;

					int old_idx = atomicInc(&smem_nnz_row_idx[row], UINT_MAX);

          rowidx[old_idx] = base_row+row;
          colidx[old_idx] = base_col+(threadIdx.x*ITEMS_PER_THREAD)+j;
          val[old_idx] = local_data[j];
        }
				else
				{
					local_quantized_data[j] = (char)(rintf(__half2float(local_data[j])*row_stat));
				}
      }
      else
        local_quantized_data[j] = (char)(rintf(__half2float(local_data[j])*row_stat));
    }

    StoreInt8(storeint8).Store(&(out_row_normed[i]), local_quantized_data, valid_items);

    // 2. quantize data with row/col stats
    #pragma unroll ITEMS_PER_THREAD
    for(int j = 0; j < ITEMS_PER_THREAD; j++)
    {
      // we already pre-normalized the col/row stat:
      // what this does is float/absmax*127 = int8
			local_quantized_data[j] = (char)(rintf(__half2float(local_data[j])*local_col_stats[j]));
    }

    __syncthreads();
    StoreInt8(storeint8).Store(&(out_col_normed[i]), local_quantized_data, valid_items);

  }
}

template <int THREADS, int ITEMS_PER_THREAD, int TILE_ROWS, int TILE_COLS, int TRANSPOSE, int FORMAT> __global__ void kTransformRowToFormat(char *__restrict__ const A, char *out, int rows, int cols, int tiledCols, int outRows, int outCols)
{

  // 0. Load data into 32*32 shared memory tiles
  // 1. transpose / reorder in shared memory
  // 2. store

  // COL32 FORMAT:
  // rows*32 tiles

  // TURING FORMAT:
  // 8*32 tiles with 4*4 subtiles
  // the 8*32 subtile has first all 4*4 subtiles of even rows (max 4*4*4 = 64 elements)
  // the subsequent 4*4 subtiles are for all odd rows if some rows columns are empty the values are zero
  // the tile repeats again after the 8*32 tile in a major column order, meaning: (next 8 rows are A[8:16, 0:32])
  // the next tile is the next 8 rows for the same 32 columns. Once all rows are finished, the column
  // index increases by 32

  // AMPERE FORMAT:
  // 32*32 tiles with 8*32 subtiles. The rows are interleaved in pairs of two rows with offset of 8 between pairs of two rows:
	// row idx (each number stands for 32 values): [0 1 8 9 16 17 24 25] [2 3 10 11 18 19 26 27]...
  // the tiles are column-major ordered, so after 1024*1024 values we process: A[32:64, 0:32]


  // To have efficient loads and stores if we transpose we need 128 consequitive bytes which at 1 byte are 128 values
  // As such we need:
  // at least 32*4 shared memory tiles for col32; preferably 32*32
  // at least 32*6 shared memory tiles for col32_ampere: preferably 32*32
  // at least 32*8 shared memory tiles for col4_turing: preferably 32*32
  // for efficient loading of row major we need to load 128 elements and repeat this 32 items
  // this would imply a 32x128 shared memory tile -> 4kb
  // It is more efficient to have more than 1 warp, so with 64 threads we need 32x128 -> 8 kb
  // we have 64k sharded mem per SM in Turing which is 8 blocks per SM which is 2*8 = 32 warps = 100% occupancy
  // for turing and 50% for A100 and 75% for RTX 30s / A40 which is probably good enough
  // register pressure should be low with: 8 registers from local memoryh per block and 64 registers per SM
  //
  // to make the shared memory work with that occupancy we might need to union the block loads/stores

  // each block loads TILE_COLs columns and TILE_ROW rows
  // after reading a tile the row counter increase by TILE_ROWS
  // the col counter reset after reading TILE_COL elements
  const int base_row = ((blockIdx.x*TILE_COLS)/tiledCols)*TILE_ROWS;
  // col increases by TILE_SIZE for each block and wraps back to 0 after tiledCols is reached
  const int base_col = (blockIdx.x*TILE_COLS) % tiledCols;
  const int base_idx = (base_row*cols) + base_col;

  // we load 128 bytes per warp with
  // 32 rows for transposes that fill col32 types
  // so that we can have contiguous stores
  __shared__ char smem_data[32*33*ITEMS_PER_THREAD];
  char local_data[ITEMS_PER_THREAD];
  typedef cub::BlockExchange<char, THREADS, ITEMS_PER_THREAD> BlockExchange;

  // we load row after row from the base_position
  // Load data row by row
  int warps = blockDim.x/32;
  int warp_id = threadIdx.x/32;
  int warp_lane = threadIdx.x % 32;
  int offset = 0;

  int smem_row = 0;
  // each warp loads one row of 128 bytes
  for(int row = warp_id; row < TILE_ROWS; row+=warps)
  {
    int i = base_idx + (row*cols);
    // we load up to 128 bytes/items per load
    int valid_items = cols - base_col > 32*ITEMS_PER_THREAD ? 32*ITEMS_PER_THREAD : cols - base_col;

    // 0. Load data into 32*32 shared memory tiles
    if(base_row + row < rows)
    {
      #pragma unroll ITEMS_PER_THREAD
      for(int j = 0; j < ITEMS_PER_THREAD; j++)
      {
        int col_idx = warp_lane+(j*32);
        if(col_idx < valid_items)
          local_data[j] = A[i+col_idx];
        else
          local_data[j] = 0;
      }
    }
    else
    {
      #pragma unroll ITEMS_PER_THREAD
      for(int j = 0; j < ITEMS_PER_THREAD; j++)
        local_data[j] = 0;
    }

    if(TRANSPOSE)
    {
      #pragma unroll ITEMS_PER_THREAD
      for(int j = 0; j < ITEMS_PER_THREAD; j++)
      {
        int local_col = (32*j)+warp_lane;
        //int local_row = row;
        // store as 256x32
        smem_data[(local_col*33) + row] = local_data[j];
      }
    }
    else
    {
      // treat smem as 32x256, that is 32 rows and 256 columns
      #pragma unroll ITEMS_PER_THREAD
      for(int j = 0; j < ITEMS_PER_THREAD; j++)
        smem_data[row*32*ITEMS_PER_THREAD + (warp_lane) + (j*32)] = local_data[j];
    }



    smem_row += warps;

    // 1. transpose / reorder in shared memory
    if(smem_row % 32 == 0)
    {
      smem_row = 0;
      __syncthreads();

      for(int subrow = warp_id; subrow < 32; subrow+=warps)
      {
        for(int j = 0; j < ITEMS_PER_THREAD; j++)
        {

          switch(FORMAT)
          {
              case COL32:
                if(TRANSPOSE)
                {
                  // data lies in shared memory in the following way:
                  // row0 [col0 col1 ... col31]
                  // row1 [col0 col1 ... col31]
                  // ...
                  //
                  // As such we read consequtive entries with 256 threads (8rows x 32 columns)
                  // as j increase, the row increase by a factor of 8
                  // We load 8 rows per subrow loop, and subrow increase by 8 per loop
                  // so we have an offset of 8 rows every loop or (subrow/warps)*8 = (subrow/8)*8
                  const int jrow = j*ITEMS_PER_THREAD; // 8 rows per j
                  const int subrow_loop_row = (subrow/warps)*ITEMS_PER_THREAD*ITEMS_PER_THREAD; // 8 rows per j; 8j per subrow loop (subrow/warps)
                  //const int local_row =  warp_id; // each warp_id is one row
                  //const int block_row = base_col; // block offset for row
                  //const int local_col = warp_lane
                  //const int global_col = base_row; // block offset for col
                  if((base_col + subrow_loop_row + jrow + warp_id < outRows) && (base_row+warp_lane < rows))
                  {
                    // each row hae 32 columns and is offset by 1 to prevent bank conflict during storage into smem
                    char data = smem_data[(subrow_loop_row + jrow + warp_id)*33 + warp_lane];

                    // each 32 columns we have new tile
                    // each tile has size outRows*32 and base_row is done in increments of 32
                    offset = base_row*outRows;
                    out[offset + (base_col + jrow + subrow_loop_row)*32 + threadIdx.x] = data;
                  }
                }
                else
                {
                  if(((base_row+subrow) < rows) && (base_col+(j*32)+warp_lane < outCols))
                  {
                    offset = (base_col/32)*(32*rows);
                    char data = smem_data[(subrow*32*ITEMS_PER_THREAD) + (j*32) + warp_lane];
                    out[offset+(base_row+subrow)*32 + ((j)*rows*32)+warp_lane] = data;
                  }
                }
                break;
              case COL_TURING:
                // TURING FORMAT:
                // 8*32 tiles with 4*4 subtiles
                // the 8*32 subtile has first all 4*4 subtiles of even rows (max 4*4*4 = 64 elements)
                // the subsequent 4*4 subtiles are for all odd rows if some rows columns are empty the values are zero
                // the tile repeats again after the 8*32 tile in a major column order, meaning: (next 8 rows are A[8:16, 0:32])
                // the next tile is the next 8 rows for the same 32 columns. Once all rows are finished, the column
                // index increases by 32
                //
                // [0 0 0 0, 2 2 2 2, 4 4 4 4, 6 6 6 6, 0 0 0 0 ...]
                if(TRANSPOSE)
                {
                  const int jrow = j*ITEMS_PER_THREAD; // 8 rows per j
                  const int subrow_loop_row = (subrow/warps)*ITEMS_PER_THREAD*ITEMS_PER_THREAD; // 8 rows per j; 8j per subrow loop (subrow/warps)
                  //const int local_row =  warp_id; // each warp_id is one row
                  //const int block_row = base_col; // block offset for row
                  //const int local_col = warp_lane
                  //const int global_col = base_row; // block offset for col
                  if((base_col + subrow_loop_row + jrow + warp_id < outRows) && (base_row+warp_lane < rows))
                  {
                    // each row hae 32 columns and is offset by 1 to prevent bank conflict during storage into smem
                    char data = smem_data[(subrow_loop_row + jrow + warp_id)*33 + warp_lane];

                    // each 32 columns we have new tile
                    // each tile has size 8*32 = 256 elements offset
                    // for each row offset of 8 we increaes the tile first
                    // after all rows are exhausted, we increase the col
                    int row_offset = ((base_col+jrow+subrow_loop_row+warp_id)/8)*256; // global_row+jrow+subrow_loop_row+local_row, increase tile(=256) every 8 rows

                    // we increase by row_tile_column every 32 columns
                    // base_row increase in increments of 32
                    //int row_tile_column = 256*outRows/8; // there are outRows/8 row tiles, and each tile is 256 elements
                    //int col_offset = (base_row/32)*row_tile_column;
                    // -> we can remove the divisions to speed up compute since outRows is always a multiple of 8
                    // 256*outRows/8*base_row/32 = outRows*base_row
                    int col_offset = outRows*base_row;

                    offset = row_offset+col_offset;

                    // since we process even number of rows with each j (8) and with each subrow (8j) we can determine
                    // odd or even rows with the warp_id (each warp processes one row)
                    // the col is warp_lane (max 32 columns per row) and the row warp_id
                    if(warp_id % 2 == 1)
                      // odd
                      offset += 128 + (warp_lane/4)*16 + (warp_lane%4) + (((warp_id%8)-1)*2);
                    else
                      // even
                      offset += 0   + (warp_lane/4)*16 + (warp_lane%4) + ((warp_id%8)*2);

                    out[offset] = data;
                  }
                }
                else
                {
                  if(((base_row+subrow) < rows) && (base_col+(j*32)+warp_lane < outCols))
                  {
                    char data = smem_data[(subrow*32*ITEMS_PER_THREAD) + (j*32) + warp_lane];
                    // set offset designates the tile offset among the 8*32 tiles
                    // we first increase rows and then columns. Since we load 128 columns at once
                    // we increase the offset by outRows*32 every 32 columns
                    // additionally, we increase the offset by 8*32=256 every 8 rows
                    offset = ((base_col+(j*32))/32)*outRows*32 + (((base_row+subrow)/8)*256); // global offset (8x32 tile)
                    // first 4 rows are reserved for even rows, [0, 2, 4, 6], the next 4 for odd
                    // each of these has 32 values in total for 32*4 = 128 as offset if odd
                    // every set of 4 columns increases the total offset by 16
                    // each even row increase the offset by 4, for example row 2 is offset by 4, 4 by 6 etc so: subrow/2*4 = subrow*2
                    // this happends every 8 rows anew (subrow % 8)
                    // one writes 4 columns at once that is (col % 4) for the particular index in the subtile
                    int subcol = warp_lane;

                    // add local offset (4x4 sub-tile)
                    if(subrow % 2 == 1)
                      // odd
                      offset += 128 + (subcol/4)*16 + (subcol%4) + (((subrow%8)-1)*2);
                    else
                      // even
                      offset += 0   + (subcol/4)*16 + (subcol%4) + ((subrow%8)*2);

                    out[offset] = data;
                  }
                }
                break;
								case COL_AMPERE:
									// AMPERE FORMAT:
									// 32*32 tiles with 8*32 subtiles. The rows are interleaved in pairs of two rows with offset of 8 between pairs of two rows:
									// row idx (each number stands for 32 values): [0 1 8 9 16 17 24 25] [2 3 10 11 18 19 26 27]...
									// the tiles are column-major ordered, so after 1024*1024 values we process: A[32:64, 0:32]
									if(TRANSPOSE)
									{
										const int jrow = j*ITEMS_PER_THREAD; // 8 rows per j
										const int subrow_loop_row = (subrow/warps)*ITEMS_PER_THREAD*ITEMS_PER_THREAD; // 8 rows per j; 8j per subrow loop (subrow/warps)
										//const int local_row =  warp_id; // each warp_id is one row
										//const int block_row = base_col; // block offset for row
										//const int local_col = warp_lane
										//const int global_col = base_row; // block offset for col
										if((base_col + subrow_loop_row + jrow + warp_id < outRows) && (base_row+warp_lane < rows))
										{
											// each row hae 32 columns and is offset by 1 to prevent bank conflict during storage into smem
											char data = smem_data[(subrow_loop_row + jrow + warp_id)*33 + warp_lane];

											// each 32 columns we have new tile
											// each tile has size 32*32 = 1024 elements offset
											// for each row offset of 32 we increaes the tile first
											// after all rows are exhausted, we increase the col
											int row_offset = ((base_col+jrow+subrow_loop_row+warp_id)/32)*1024; // global_row+jrow+subrow_loop_row+local_row, increase tile(=256) every 8 rows

											// we increase by row_tile_column every 32 columns
											// base_row increase in increments of 32
											//int row_tile_column = 1024*outRows/32; // there are outRows/32 row tiles, and each tile is 1024 elements
											//int col_offset = (base_row/32)*row_tile_column;
											// -> we can remove the divisions to speed up compute since outRows is always a multiple of 8
											// 1024*outRows/32*base_row/32 = outRows*base_row
											int col_offset = outRows*base_row;

											offset = row_offset+col_offset;


											// same as in the non-transpose case (see below)
											// the difference is that now rows = cols
											// in this case warp_id = subrow

											// [0 1 8 9 16 17 24 25] [2 3 10 11 18 19 26 27]...
											// subrow % 8 -> [0,1] in tile0, [2, 3] in tile 1 etc
											// subrow % 2 -> 0 for 1st row in the pair, 1 for the 2nd row
											// every 2 rows, the offset increases by two [0, 1, 8, 9...]
											// every 2 rows, the row index increase by 8 [0, 1, 8, 9...]
											int local_row = (jrow + warp_id) % 32; // offset for row > 32 is already calculated into row_offset
											int ampere_row = ((local_row % 8)/2)*8 + (local_row/8)*2 + (local_row % 2);

											// global offset + row with 32 cols each + 32 cols per j + col_idx=warp_lane
											out[offset + (ampere_row*32) + warp_lane] = data;
										}
									}
									else
									{
										if(((base_row+subrow) < rows) && (base_col+(j*32)+warp_lane < outCols))
										{
											char data = smem_data[(subrow*32*ITEMS_PER_THREAD) + (j*32) + warp_lane];

											// set offset designates the tile offset among the 32*32 tiles
											// we first increase rows and then columns. Since we load 128 columns at once
											// we increase the offset by outRows*32 every 32 columns
											// additionally, we increase the offset by 32*32=1024 every 32 rows
											offset = ((base_col+(j*32))/32)*outRows*32 + (((base_row+subrow)/32)*1024); // global offset (32x32 tile)

											// [0 1 8 9 16 17 24 25] [2 3 10 11 18 19 26 27]...
											// subrow % 8 -> [0,1] in tile0, [2, 3] in tile 1 etc
											// subrow % 2 -> 0 for 1st row in the pair, 1 for the 2nd row
											// every 2 rows, the offset increases by two [0, 1, 8, 9...]
											// every 2 rows, the row index increase by 8 [0, 1, 8, 9...]
											int local_row = ((subrow % 8)/2)*8 + (subrow/8)*2 + (subrow % 2);

											// global offset + row with 32 cols each + 32 cols per j + col_idx
											out[offset + (local_row*32) + warp_lane] = data;
										}
									}
								break;
          }
        }
      }
    }
  }
}

#define C 1.0f/127.0f
#define MAX_SPARSE_COUNT 32
#define SMEM_SIZE 8*256
template <typename T, int SPMM_ITEMS, int BITS>
__global__ void kspmm_coo_very_sparse_naive(int *max_count, int *max_idx, int *offset_rowidx, int *rowidx, int *colidx, half *values, T *B, half *out, float * __restrict__ const dequant_stats, int nnz, int rowsA, int rowsB, int colsB)
{

  // 0. load balancing: We process rows with most columns first (count_vec)and we process one row per block
  //    If a block finishes, the next one is scheduled. Since the last blocks like have fewer
  //    elements they finish faster "fillin up" the gaps left by larger blocks

  // without tensor cores
  // 1. use rowidx_length to find what to load (as many blocks as there are rows)
  // 2. Load A into registers
  // 3. each warp loads all required rows of B but each warp is offset by k
  // 4. Do mma operations that accumulate into registers
  // 5. Each warp stores its output row into matrix C

  const int count = max_count[blockIdx.x];
  const int local_max_idx = max_idx[blockIdx.x];
  const int offset = local_max_idx == 0 ? 0 : offset_rowidx[local_max_idx-1];
  const int local_row_idx = rowidx[offset];

  const int warp_id = threadIdx.x / 32;
  const int warp_idx = threadIdx.x % 32;
  const int warp_offset = (warp_id*32)*SPMM_ITEMS;
  const int num_items = BITS == 8 ? 8 : 8;
  int idx_col_B = warp_offset;
  int local_idx_col_B_offset = 0;

  half local_valA[MAX_SPARSE_COUNT];
  int local_colidxA[MAX_SPARSE_COUNT];
  half local_valC[SPMM_ITEMS];
  T local_valsB[num_items];
  half local_valOut[num_items];
  // 128 byte loads per warp == 4 bytes per thread

  // 2. Load A into registers
  for(int j = 0; j < MAX_SPARSE_COUNT; j++)
  {
    local_valA[j] = j < count ? values[offset+j] : __float2half(0.0f);
    local_colidxA[j] = j < count ? colidx[offset+j] : 0;
  }

  // each thread processes SPMM_ITEMS=32 per iteration. We have 256 threads. 32*256=x192
  // we expect each warp to be SPMM_ITEMS*32 apart
  // we have a total of 128 bytes for the bank with a bank size of 4 bytes
  // added 3 bytes = 6 values between warps should reduce bank conflicts
  __shared__ half smem_dequant_stats[SMEM_SIZE];


  while(idx_col_B <  colsB)
  {

    if(dequant_stats != NULL)
    {
      for(int i = threadIdx.x; i < SMEM_SIZE; i+=blockDim.x)
        if((idx_col_B+i-local_idx_col_B_offset) < colsB)
          smem_dequant_stats[i] = dequant_stats[idx_col_B+i-local_idx_col_B_offset];

      __syncthreads();
    }

    #pragma unroll SPMM_ITEMS
    for(int j = 0; j < SPMM_ITEMS; j++)
      local_valC[j] = 0.0f;

    #pragma unroll
    for(int i = 0; i < count; i++)
    {
        // 3. each warp loads all required rows of B but each warp is offset by k
        int row_offset = colsB*local_colidxA[i];

        #pragma unroll SPMM_ITEMS
        for(int j = 0; j < SPMM_ITEMS; j+=num_items)
        {
          // 4. Multiply the tile -> accumulate outputs in shared memory until 128 bytes it reached
          int idx = idx_col_B + (warp_idx*SPMM_ITEMS) + j;
          if(idx >= colsB){ break; }
          //printf("%i %i\n", (row_offset+idx) % num_items, row_offset+idx);
          if((idx+num_items < colsB))
          {
            if(BITS == 8)
              reinterpret_cast<float2(&)[num_items]>(local_valsB)[0] = reinterpret_cast<float2*>(B)[(row_offset+ idx)/num_items];
            else
              reinterpret_cast<float4(&)[num_items]>(local_valsB)[0] = reinterpret_cast<float4*>(B)[(row_offset+ idx)/num_items];
          }
          else
          {
            #pragma unroll num_items
            for(int k = 0; k < num_items; k++)
              if(idx+k < colsB)
                local_valsB[k] = B[row_offset+idx+k];
              else
                local_valsB[k] = 0.0f;
          }
          #pragma unroll num_items
          for(int k = 0; k < num_items; k++)
          {
            //if((float)local_valsB[k] != 0.0)
            //  printf("%f %i %i %i\n", (float)local_valsB[k], k, idx, colsB);
            if(BITS == 8 && dequant_stats != NULL)
              // we do texture cache reads (__ldg) on dequant_stats which should be super fast
            {
              float valB = local_valsB[k];
              float valA = local_valA[i];
              if(valB != 0.0 && valA != 0.0)
                local_valC[j+k] = (float)local_valC[j+k] + ((float)smem_dequant_stats[idx+k-local_idx_col_B_offset])*C*valB*valA;
            }
            else
              local_valC[j+k] = (float)local_valC[j+k] + (float)local_valsB[k]*(float)local_valA[i];
          }
        }
    }

    int idx_row_C = (colsB*local_row_idx);

    #pragma unroll SPMM_ITEMS
    for(int j = 0; j < SPMM_ITEMS; j+=num_items)
    {
      //int idx_col_C =  idx_col_B + (32*j) + warp_idx;
      int idx_col_C =  idx_col_B + warp_idx*SPMM_ITEMS + j;
      int idx_val = idx_col_C + idx_row_C;

      if(idx_col_C +num_items < colsB)
      {

          // load outputs to do inplace addition
          reinterpret_cast<float4(&)[num_items/4]>(local_valOut)[0] = reinterpret_cast<float4*>(out)[idx_val/num_items];

          #pragma unroll num_items
          for(int k = 0; k < num_items; k++)
            local_valC[(j/num_items) + k] = (float)local_valC[(j/num_items) + k] + (float)local_valOut[k];

          reinterpret_cast<float4*>(out)[idx_val/num_items] = reinterpret_cast<float4(&)[num_items]>(local_valC)[j/num_items];
      }
      else
      {
        #pragma unroll num_items
        for(int k = 0; k < num_items; k++)
         if(idx_col_C + k < colsB)
           out[idx_val+k] = (float)out[idx_val+k]+(float)local_valC[j+k];
      }
    }

    idx_col_B += blockDim.x*SPMM_ITEMS;
    local_idx_col_B_offset += blockDim.x*SPMM_ITEMS;
  }
}

template <int FORMAT> __global__ void kExtractOutliers(char *A, int *idx, char *out, int idx_size, int rowsA, int colsA, int tiledRowsA, int tiledColsA)
{
	int local_colidx = idx[blockIdx.x];

	if(FORMAT==COL_TURING)
	{
		// TURING FORMAT:
		// 8*32 tiles with 4*4 subtiles
		// the 8*32 subtile has first all 4*4 subtiles of even rows (max 4*4*8 = 128 elements)
		// the subsequent 4*4 subtiles are for all odd rows if some rows columns are empty the values are zero
		// the tile repeats again after the 8*32 tile in a major column order, meaning: (next 8 rows are A[8:16, 0:32])
		// the next tile is the next 8 rows for the same 32 columns. Once all rows are finished, the column
		// index increases by 32
		// columns are grouped in increments of 4, meaning that one has the following rows and columns
		// rows: [0 0 0 0, 2 2 2 2, 4 4 4 4, 6 6 6 6, 0 0 0 0 ...]
		// cols: [0 1 2 3, 0 1 2 4, 0 1 2 3, 0 1 2 3, 4 5 6 7 ...]

		// each thread reads 1 element = 1 row
		for(int row = threadIdx.x; row < rowsA; row+= blockDim.x)
		{
			int offset_per_col_tile = ((rowsA+7)/8)*32*8;
			int tile_offset_rows = (row/8)*32*8;
			int tile_offset_cols = (local_colidx/32)*offset_per_col_tile;
			int offset = 0;
			int subtile_col_idx = local_colidx%32;
			int subtile_row_idx = row % 8;
			if(row % 2 == 1)
				offset += 128 + (subtile_col_idx/4)*16 + (subtile_col_idx%4) + ((subtile_row_idx-1)*2);
			else
				// even
				offset += 0   + (subtile_col_idx/4)*16 + (subtile_col_idx%4) + (subtile_row_idx*2);

			offset += tile_offset_rows + tile_offset_cols;

			char val = A[offset];

			int out_idx = (row*idx_size) + blockIdx.x;
			out[out_idx] = val;
		}
	}
	else if(FORMAT == COL_AMPERE)
	{

		for(int row = threadIdx.x; row < rowsA; row+= blockDim.x)
		{
			// we got 32x32 tiles and we use the magic equation from the cublasLt doc to get the element
			// within each tile.
			int offset_per_col_tile = ((rowsA+31)/32)*32*32;
			int tile_offset_rows = (row/32)*32*32;
			int tile_offset_cols = (local_colidx/32)*offset_per_col_tile;
			int subtile_col_idx = local_colidx%32;
			int subtile_row_idx = row % 32;
			// this magic is taken from the cublasLt doc (search for COL32)
			int offset = (((subtile_row_idx%8)/2*4+subtile_row_idx/8)*2+subtile_row_idx%2)*32+subtile_col_idx;
			offset += tile_offset_cols + tile_offset_rows;

			char val = A[offset];
			int out_idx = (row*idx_size) + blockIdx.x;
			out[out_idx] = val;
		}
	}
}

//==============================================================
//                   TEMPLATE DEFINITIONS
//==============================================================

template __global__ void kExtractOutliers<COL_TURING>(char *A, int *idx, char *out, int idx_size, int rowsA, int colsA, int tiledRowsA, int tiledColsA);
template __global__ void kExtractOutliers<COL_AMPERE>(char *A, int *idx, char *out, int idx_size, int rowsA, int colsA, int tiledRowsA, int tiledColsA);

template __global__ void kspmm_coo_very_sparse_naive<half, 8, 16>(int *max_count, int *max_idx, int *offset_rowidx, int *rowidx, int *colidx, half *values, half *B, half *out, float *dequant_stats, int nnz, int rowsA, int rowsB, int colsB);
template __global__ void kspmm_coo_very_sparse_naive<half, 16, 16>(int *max_count, int *max_idx, int *offset_rowidx, int *rowidx, int *colidx, half *values, half *B, half *out, float *dequant_stats, int nnz, int rowsA, int rowsB, int colsB);
template __global__ void kspmm_coo_very_sparse_naive<half, 32, 16>(int *max_count, int *max_idx, int *offset_rowidx, int *rowidx, int *colidx, half *values, half *B, half *out, float *dequant_stats, int nnz, int rowsA, int rowsB, int colsB);
template __global__ void kspmm_coo_very_sparse_naive<signed char, 8, 8>(int *max_count, int *max_idx, int *offset_rowidx, int *rowidx, int *colidx, half *values, signed char *B, half *out, float *dequant_stats, int nnz, int rowsA, int rowsB, int colsB);
template __global__ void kspmm_coo_very_sparse_naive<signed char, 16, 8>(int *max_count, int *max_idx, int *offset_rowidx, int *rowidx, int *colidx, half *values, signed char *B, half *out, float *dequant_stats, int nnz, int rowsA, int rowsB, int colsB);
template __global__ void kspmm_coo_very_sparse_naive<signed char, 32, 8>(int *max_count, int *max_idx, int *offset_rowidx, int *rowidx, int *colidx, half *values, signed char *B, half *out, float *dequant_stats, int nnz, int rowsA, int rowsB, int colsB);

template __global__ void kTransformRowToFormat<256, 8, 32, 32*8, 0, COL32>(char *__restrict__ const A, char *out, int rows, int cols, int tiledCols, int outRows, int outCols);
template __global__ void kTransformRowToFormat<256, 8, 32, 32*8, 1, COL32>(char *__restrict__ const A, char *out, int rows, int cols, int tiledCols, int outRows, int outCols);
template __global__ void kTransformRowToFormat<256, 8, 32, 32*8, 0, COL_TURING>(char *__restrict__ const A, char *out, int rows, int cols, int tiledCols, int outRows, int outCols);
template __global__ void kTransformRowToFormat<256, 8, 32, 32*8, 1, COL_TURING>(char *__restrict__ const A, char *out, int rows, int cols, int tiledCols, int outRows, int outCols);
template __global__ void kTransformRowToFormat<256, 8, 32, 32*8, 0, COL_AMPERE>(char *__restrict__ const A, char *out, int rows, int cols, int tiledCols, int outRows, int outCols);
template __global__ void kTransformRowToFormat<256, 8, 32, 32*8, 1, COL_AMPERE>(char *__restrict__ const A, char *out, int rows, int cols, int tiledCols, int outRows, int outCols);

template __global__ void kdequant_mm_int32_fp16<4, 128, 512>(int *__restrict__ const A, float *__restrict__ const rowStats, float *__restrict__ const colStats, half *out, float* newRowStats, float* newcolStats, half * __restrict__ const bias, const int numRows, const int numCols, const int tileCols, const int n);

template __global__ void kDoubleRowColQuant<64, 4, 16, 64*4, 0>(half *__restrict__ const A, float *__restrict__ const rowStats, float * __restrict__ const colStats, char *out_col_normed, char *out_row_normed, int *rowidx, int *colidx, half *val, int * __restrict__ nnz_block_ptr, float threshold, int rows, int cols, int tiledCols);
template __global__ void kDoubleRowColQuant<64, 4, 16, 64*4, 1>(half *__restrict__ const A, float *__restrict__ const rowStats, float * __restrict__ const colStats, char *out_col_normed, char *out_row_normed, int *rowidx, int *colidx, half *val, int * __restrict__ nnz_block_ptr, float threshold, int rows, int cols, int tiledCols);

template __device__ unsigned char dQuantize<0>(float* smem_code, const float rand, float x);
template __device__ unsigned char dQuantize<1>(float* smem_code, const float rand, float x);

template __global__ void kEstimateQuantiles(float *__restrict__ const A, float *code, const float offset, const float max_val, const int n);
template __global__ void kEstimateQuantiles(half *__restrict__ const A, float *code, const float offset, const half max_val, const int n);

#define MAKE_PreconditionOptimizer32bit1State(oname, gtype) \
template __global__ void kPreconditionOptimizer32bit1State<gtype, oname, 4096, 8>(gtype* g, gtype* p, \
                float* state1, float *unorm, \
                const float beta1, const float eps, const float weight_decay, \
                const int step, const float lr, const float gnorm_scale, const int n); \

MAKE_PreconditionOptimizer32bit1State(MOMENTUM, half)
MAKE_PreconditionOptimizer32bit1State(MOMENTUM, float)
MAKE_PreconditionOptimizer32bit1State(RMSPROP, half)
MAKE_PreconditionOptimizer32bit1State(RMSPROP, float)
MAKE_PreconditionOptimizer32bit1State(ADAGRAD, half)
MAKE_PreconditionOptimizer32bit1State(ADAGRAD, float)

#define MAKE_Optimizer32bit1State(oname, gtype) \
template __global__ void kOptimizer32bit1State<gtype, oname>(gtype* g, gtype* p, float* state1, float *unorm, const float max_unorm, const float param_norm, \
    const float beta1, const float eps, const float weight_decay,const int step, const float lr, const float gnorm_scale, const bool skip_zeros, const int n); \

MAKE_Optimizer32bit1State(MOMENTUM, half)
MAKE_Optimizer32bit1State(MOMENTUM, float)
MAKE_Optimizer32bit1State(RMSPROP, half)
MAKE_Optimizer32bit1State(RMSPROP, float)
MAKE_Optimizer32bit1State(ADAGRAD, half)
MAKE_Optimizer32bit1State(ADAGRAD, float)

#define MAKE_PreconditionOptimizer32bit2State(oname, gtype) \
template __global__ void kPreconditionOptimizer32bit2State<gtype, oname, 4096, 8>(gtype* g, gtype* p,  \
                float* state1, float* state2, float *unorm, \
                const float beta1, const float beta2, const float eps, const float weight_decay, \
                const int step, const float lr, const float gnorm_scale, const int n); \

MAKE_PreconditionOptimizer32bit2State(ADAM, half)
MAKE_PreconditionOptimizer32bit2State(ADAM, float)

template __global__ void kOptimizer32bit2State<half, ADAM>(half* g, half* p, float* state1, float* state2, float *unorm, const float max_unorm, const float param_norm,
    const float beta1, const float beta2, const float eps, const float weight_decay,const int step, const float lr, const float gnorm_scale, const bool skip_zeros, const int n);
template __global__ void kOptimizer32bit2State<float, ADAM>(float* g, float* p, float* state1, float* state2, float *unorm, const float max_unorm, const float param_norm,
    const float beta1, const float beta2, const float eps, const float weight_decay,const int step, const float lr, const float gnorm_scale, const bool skip_zeros, const int n);

#define MAKE_PreconditionStatic8bit1State(oname, gtype) \
template __global__ void kPreconditionOptimizerStatic8bit1State<gtype, oname>(gtype* p, gtype* __restrict__ const g, unsigned char*__restrict__  const state1,  \
                float *unorm,  \
                const float beta1,  \
                const float eps, const int step,  \
                float* __restrict__ const quantiles1,  \
                float* max1, float* new_max1,  \
                const float weight_decay, \
                const float gnorm_scale,  \
                const int n); \

MAKE_PreconditionStatic8bit1State(MOMENTUM, half)
MAKE_PreconditionStatic8bit1State(MOMENTUM, float)
MAKE_PreconditionStatic8bit1State(RMSPROP, half)
MAKE_PreconditionStatic8bit1State(RMSPROP, float)

#define MAKE_optimizerStatic8bit1State(oname, gtype) \
template __global__ void kOptimizerStatic8bit1State<gtype, oname>(gtype* p, gtype* const g, unsigned char* state1,  \
                const float *unorm, const float max_unorm, const float param_norm, \
                const float beta1,  \
                const float eps, const int step, const float lr, \
                float* __restrict__ const quantiles1,  \
                float* max1, float* new_max1,  \
                float weight_decay, \
                const float gnorm_scale,  \
                const int n); \

MAKE_optimizerStatic8bit1State(MOMENTUM, half)
MAKE_optimizerStatic8bit1State(MOMENTUM, float)
MAKE_optimizerStatic8bit1State(RMSPROP, half)
MAKE_optimizerStatic8bit1State(RMSPROP, float)

#define MAKE_PreconditionStatic8bit2State(oname, gtype) \
template __global__ void kPreconditionOptimizerStatic8bit2State<gtype, oname>(gtype* p, gtype* __restrict__ const g, unsigned char*__restrict__  const state1, unsigned char* __restrict__ const state2, \
                float *unorm, \
                const float beta1, const float beta2, \
                const float eps, const int step,  \
                float* __restrict__ const quantiles1, float* __restrict__ const quantiles2, \
                float* max1, float* max2, float* new_max1, float* new_max2, \
                const float gnorm_scale,  \
                const int n); \

MAKE_PreconditionStatic8bit2State(ADAM, half)
MAKE_PreconditionStatic8bit2State(ADAM, float)

#define MAKE_optimizerStatic8bit2State(oname, gtype) \
template __global__ void kOptimizerStatic8bit2State<gtype, oname>(gtype* p, gtype* const g, unsigned char* state1, unsigned char* state2, \
                const float *unorm, const float max_unorm, const float param_norm, \
                const float beta1, const float beta2, \
                const float eps, const int step, const float lr, \
                float* __restrict__ const quantiles1, float* __restrict__ const quantiles2, \
                float* max1, float* max2, float* new_max1, float* new_max2, \
                float weight_decay, \
                const float gnorm_scale,  \
                const int n); \

MAKE_optimizerStatic8bit2State(ADAM, half)
MAKE_optimizerStatic8bit2State(ADAM, float)

template __global__ void kPercentileClipping<float, 2048, 4>(float * __restrict__ g, float *gnorm_vec, int step, const int n);
template __global__ void kPercentileClipping<half, 2048, 4>(half * __restrict__ g, float *gnorm_vec, int step, const int n);

template __global__ void kQuantizeBlockwise<half, 4096, 4, 0>(float * code, half * __restrict__ const A, float *absmax, unsigned char *out, float * __restrict__ const rand, const int rand_offset, const int n);
template __global__ void kQuantizeBlockwise<float, 4096, 4, 0>(float * code, float * __restrict__ const A, float *absmax, unsigned char *out, float * __restrict__ const rand, const int rand_offset, const int n);
template __global__ void kQuantizeBlockwise<half, 4096, 4, 1>(float * code, half * __restrict__ const A, float *absmax, unsigned char *out, float * __restrict__ const rand, const int rand_offset, const int n);
template __global__ void kQuantizeBlockwise<float, 4096, 4, 1>(float * code, float * __restrict__ const A, float *absmax, unsigned char *out, float * __restrict__ const rand, const int rand_offset, const int n);
template __global__ void kQuantizeBlockwise<half, 2048, 4, 0>(float * code, half * __restrict__ const A, float *absmax, unsigned char *out, float * __restrict__ const rand, const int rand_offset, const int n);
template __global__ void kQuantizeBlockwise<float, 2048, 4, 0>(float * code, float * __restrict__ const A, float *absmax, unsigned char *out, float * __restrict__ const rand, const int rand_offset, const int n);
template __global__ void kQuantizeBlockwise<half, 1024, 4, 0>(float * code, half * __restrict__ const A, float *absmax, unsigned char *out, float * __restrict__ const rand, const int rand_offset, const int n);
template __global__ void kQuantizeBlockwise<float, 1024, 4, 0>(float * code, float * __restrict__ const A, float *absmax, unsigned char *out, float * __restrict__ const rand, const int rand_offset, const int n);
template __global__ void kQuantizeBlockwise<half, 512, 2, 0>(float * code, half * __restrict__ const A, float *absmax, unsigned char *out, float * __restrict__ const rand, const int rand_offset, const int n);
template __global__ void kQuantizeBlockwise<float, 512, 2, 0>(float * code, float * __restrict__ const A, float *absmax, unsigned char *out, float * __restrict__ const rand, const int rand_offset, const int n);
template __global__ void kQuantizeBlockwise<half, 256, 2, 0>(float * code, half * __restrict__ const A, float *absmax, unsigned char *out, float * __restrict__ const rand, const int rand_offset, const int n);
template __global__ void kQuantizeBlockwise<float, 256, 2, 0>(float * code, float * __restrict__ const A, float *absmax, unsigned char *out, float * __restrict__ const rand, const int rand_offset, const int n);
template __global__ void kQuantizeBlockwise<half, 128, 2, 0>(float * code, half * __restrict__ const A, float *absmax, unsigned char *out, float * __restrict__ const rand, const int rand_offset, const int n);
template __global__ void kQuantizeBlockwise<float, 128, 2, 0>(float * code, float * __restrict__ const A, float *absmax, unsigned char *out, float * __restrict__ const rand, const int rand_offset, const int n);
template __global__ void kQuantizeBlockwise<half, 64, 1, 0>(float * code, half * __restrict__ const A, float *absmax, unsigned char *out, float * __restrict__ const rand, const int rand_offset, const int n);
template __global__ void kQuantizeBlockwise<float, 64, 1, 0>(float * code, float * __restrict__ const A, float *absmax, unsigned char *out, float * __restrict__ const rand, const int rand_offset, const int n);

template __global__ void kDequantizeBlockwise<half, 4096, 1024, 4>(float *code, unsigned char * A, float * absmax, half *out, const int n);
template __global__ void kDequantizeBlockwise<float, 4096, 1024, 4>(float *code, unsigned char * A, float * absmax, float *out, const int n);
template __global__ void kDequantizeBlockwise<half, 2048, 512, 4>(float *code, unsigned char * A, float * absmax, half *out, const int n);
template __global__ void kDequantizeBlockwise<float, 2048, 512, 4>(float *code, unsigned char * A, float * absmax, float *out, const int n);
template __global__ void kDequantizeBlockwise<half, 1024, 256, 4>(float *code, unsigned char * A, float * absmax, half *out, const int n);
template __global__ void kDequantizeBlockwise<float, 1024, 256, 4>(float *code, unsigned char * A, float * absmax, float *out, const int n);
template __global__ void kDequantizeBlockwise<half, 512, 256, 2>(float *code, unsigned char * A, float * absmax, half *out, const int n);
template __global__ void kDequantizeBlockwise<float, 512, 256, 2>(float *code, unsigned char * A, float * absmax, float *out, const int n);
template __global__ void kDequantizeBlockwise<half, 256, 128, 2>(float *code, unsigned char * A, float * absmax, half *out, const int n);
template __global__ void kDequantizeBlockwise<float, 256, 128, 2>(float *code, unsigned char * A, float * absmax, float *out, const int n);
template __global__ void kDequantizeBlockwise<half, 128, 64, 2>(float *code, unsigned char * A, float * absmax, half *out, const int n);
template __global__ void kDequantizeBlockwise<float, 128, 64, 2>(float *code, unsigned char * A, float * absmax, float *out, const int n);
template __global__ void kDequantizeBlockwise<half, 64, 64, 1>(float *code, unsigned char * A, float * absmax, half *out, const int n);
template __global__ void kDequantizeBlockwise<float, 64, 64, 1>(float *code, unsigned char * A, float * absmax, float *out, const int n);



#define MAKE_OptimizerStatic8bit2StateBlockwise(oname, gtype, block_size, num_per_thread) \
template __global__ void kOptimizerStatic8bit2StateBlockwise<gtype, oname, block_size, num_per_thread>(gtype* p, gtype* __restrict__ const g, unsigned char* state1, unsigned char* state2, \
                const float beta1, const float beta2, \
                const float eps, const int step, const float lr, \
                float* __restrict__ const quantiles1, float* __restrict__ const quantiles2, \
                float* absmax1, float* absmax2,  \
                float weight_decay, \
                const float gnorm_scale, const bool skip_zeros, const int n); \

MAKE_OptimizerStatic8bit2StateBlockwise(ADAM, float, 2048, 8)
MAKE_OptimizerStatic8bit2StateBlockwise(ADAM, half, 2048, 8)

#define MAKE_OptimizerStatic8bit1StateBlockwise(oname, gtype, block_size, num_per_thread) \
template __global__ void kOptimizerStatic8bit1StateBlockwise<gtype, oname, block_size, num_per_thread>( \
		gtype* p, gtype* __restrict__ const g, unsigned char* state1, \
                const float beta1, const float beta2, \
                const float eps, const int step, const float lr, \
                float* __restrict__ const quantiles1, \
                float* absmax1, \
                float weight_decay, \
                const float gnorm_scale, const bool skip_zeros, const int n); \

MAKE_OptimizerStatic8bit1StateBlockwise(MOMENTUM, float, 2048, 8)
MAKE_OptimizerStatic8bit1StateBlockwise(MOMENTUM, half, 2048, 8)
MAKE_OptimizerStatic8bit1StateBlockwise(RMSPROP, float, 2048, 8)
MAKE_OptimizerStatic8bit1StateBlockwise(RMSPROP, half, 2048, 8)
MAKE_OptimizerStatic8bit1StateBlockwise(ADAGRAD, float, 2048, 8)
MAKE_OptimizerStatic8bit1StateBlockwise(ADAGRAD, half, 2048, 8)
