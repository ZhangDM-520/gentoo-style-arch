/* CUDA driver-API stand-ins for the bindgen pass of ffmpeg-sys-next.
 *
 * ffmpeg-sys-next 9.0's hwcontext_wrapper.h suppresses <cuda.h> (defines
 * CUDA_VERSION first) and typedefs only CUcontext/CUstream inline — enough
 * for the ffmpeg 9.0 headers it was written against. The house ffmpeg-git
 * (9.1.dev) grew AVCUDAArrayFrameDescriptor/AVCUDAFramesContext.cuda_fields
 * in hwcontext_cuda.h, which reference CUarray, CUdeviceptr and
 * CUDA_ARRAY3D_DESCRIPTOR, so bindgen died on 'unknown type name'. These
 * opaque stand-ins complete the wrapper's set: they exist only so the
 * bindings COMPILE — wl-screenrec never touches the CUDA hwcontext (it
 * encodes via VA-API/Vulkan), so layouts are irrelevant here. Remove when
 * ffmpeg-sys-next's wrapper grows the same types.
 */
typedef struct CUarray_st *CUarray;
typedef unsigned long long CUdeviceptr;
typedef struct CUDA_ARRAY3D_DESCRIPTOR_st {
  unsigned int Width, Height, Depth;
  unsigned int NumChannels;
  unsigned int Flags;
} CUDA_ARRAY3D_DESCRIPTOR;
