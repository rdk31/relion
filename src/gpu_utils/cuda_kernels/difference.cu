#include "src/gpu_utils/cuda_kernels/difference.cuh"
#include <vector>
#include <iostream>

__global__ void cuda_kernel_D2(	FLOAT *g_refs_real,
									FLOAT *g_refs_imag,
									FLOAT *g_imgs_real,
									FLOAT *g_imgs_imag,
									FLOAT *g_Minvsigma2, FLOAT *g_diff2s,
									unsigned image_size, FLOAT sum_init,
									unsigned long todo_blocks,
									unsigned long translation_num,
									unsigned long *d_rot_idx,
									unsigned long *d_trans_idx,
									unsigned long *d_job_idx,
									unsigned long *d_job_num
									)
{
	// blockid
	int bid = blockIdx.y * gridDim.x + blockIdx.x;
	int tid = threadIdx.x;

	unsigned long ref_pixel_idx;

	__shared__ FLOAT s[BLOCK_SIZE*PROJDIFF_CHUNK_SIZE]; //We MAY have to do up to PROJDIFF_CHUNK_SIZE translations in each block
	__shared__ FLOAT s_outs[PROJDIFF_CHUNK_SIZE];

	if( bid < todo_blocks )
	{
		unsigned long int iy; // transidx
		unsigned long int ix = d_rot_idx[d_job_idx[bid]];
		unsigned long ref_start(ix * image_size);

		unsigned trans_num   = d_job_num[bid]; //how many transes we have for this rot
		for (int itrans=0; itrans<trans_num; itrans++)
		{
			s[itrans*BLOCK_SIZE+tid] = 0.0;
		}

		unsigned pass_num(ceilf(((float)image_size) / (float)BLOCK_SIZE  )), pixel;
		for (unsigned pass = 0; pass < pass_num; pass++)
		{
			pixel = pass * BLOCK_SIZE + tid;
			if (pixel < image_size) //Is inside image
			{
				ref_pixel_idx = ref_start + pixel;
				FLOAT ref_real=__ldg(&g_refs_real[ref_pixel_idx]);
				FLOAT ref_imag=__ldg(&g_refs_imag[ref_pixel_idx]);
				FLOAT diff_real;
				FLOAT diff_imag;
				for (int itrans=0; itrans<trans_num; itrans++) // finish all translations in each partial pass
				{
					iy=d_trans_idx[d_job_idx[bid]]+itrans;
					unsigned long img_start(iy * image_size);
					unsigned long img_pixel_idx = img_start + pixel;
					diff_real =  ref_real - __ldg(&g_imgs_real[img_pixel_idx]); // TODO  Put g_img_* in texture (in such a way that fetching of next image might hit in cache)
					diff_imag =  ref_imag - __ldg(&g_imgs_imag[img_pixel_idx]);
					s[itrans*BLOCK_SIZE + tid] += (diff_real * diff_real + diff_imag * diff_imag) * 0.5 * __ldg(&g_Minvsigma2[pixel]);
				}
				__syncthreads();
			}
		}
		__syncthreads();

		for(int j=(BLOCK_SIZE/2); j>0; j/=2)
		{
			if(tid<j)
			{
				for (int itrans=0; itrans<trans_num; itrans++) // finish all translations in each partial pass
				{
					s[itrans*BLOCK_SIZE+tid] += s[itrans*BLOCK_SIZE+tid+j];
				}
			}
			__syncthreads();
		}

		if (tid < trans_num)
		{
			s_outs[tid]=s[tid*BLOCK_SIZE]+sum_init;
		}
		if (tid < trans_num)
		{
			iy=d_job_idx[bid]+tid;
			g_diff2s[iy] = s_outs[tid];
		}
	}
}

__global__ void cuda_kernel_D2_CC(	FLOAT *g_refs_real,
										FLOAT *g_refs_imag,
										FLOAT *g_imgs_real,
										FLOAT *g_imgs_imag,
										FLOAT *g_Minvsigma2, FLOAT *g_diff2s,
										unsigned img_size, FLOAT exp_local_sqrtXi2,
										unsigned long significant_num,
										unsigned long translation_num,
										unsigned long *d_rotidx,
										unsigned long *d_transidx)
{
	// blockid
	int ex = blockIdx.y * gridDim.x + blockIdx.x;
	// inside the padded 2D orientation grid
	if( ex < significant_num )
	{
		// index of comparison
		unsigned long int ix=d_rotidx[ex];
		unsigned long int iy=d_transidx[ex];
		__shared__ double    s[BLOCK_SIZE];
		__shared__ double norm[BLOCK_SIZE];
		s[threadIdx.x] = 0;
		unsigned pass_num(ceilf((float)img_size/(float)BLOCK_SIZE));
		unsigned long pixel,
		ref_start(ix * img_size),
		img_start(iy * img_size);
		unsigned long ref_pixel_idx;
		unsigned long img_pixel_idx;
		for (unsigned pass = 0; pass < pass_num; pass ++)
		{
			pixel = pass * BLOCK_SIZE + threadIdx.x;

			if (pixel < img_size) //Is inside image
			{
				ref_pixel_idx = ref_start + pixel;
				img_pixel_idx = img_start + pixel;

				double diff_real = g_refs_real[ref_pixel_idx] * g_imgs_real[img_pixel_idx];
				double diff_imag = g_refs_imag[ref_pixel_idx] * g_imgs_imag[img_pixel_idx];

				double nR = g_refs_real[ref_pixel_idx]*g_refs_real[ref_pixel_idx];
				double nI = g_refs_imag[ref_pixel_idx]*g_refs_imag[ref_pixel_idx];

				s[threadIdx.x] -= (diff_real + diff_imag);
				norm[threadIdx.x] += nR+nI;
			}
		}
		// -------------------------------------------------------------------------
		__syncthreads();
		int trads = 32;
		int itr = BLOCK_SIZE/trads;
		if(threadIdx.x<trads)
		{
			for(int i=1; i<itr; i++)
			{
				s[threadIdx.x] += s[i*trads + threadIdx.x];
				norm[threadIdx.x] += norm[i*trads + threadIdx.x];
			}
		}
		for(int j=(trads/2); j>0; j/=2)
		{
			if(threadIdx.x<j)
			{
				s[threadIdx.x] += s[threadIdx.x+j];
				norm[threadIdx.x] += norm[threadIdx.x+j];
			}
		}
		__syncthreads();
		// -------------------------------------------------------------------------
		g_diff2s[ix * translation_num + iy] = s[0]/(sqrt(norm[0])*exp_local_sqrtXi2);
	}
}
