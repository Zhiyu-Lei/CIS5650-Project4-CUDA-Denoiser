#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <thrust/execution_policy.h>
#include <thrust/device_ptr.h>
#include <thrust/random.h>
#include <thrust/shuffle.h>
#include <thrust/sort.h>
#include <thrust/remove.h>

#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"

#define ERRORCHECK 1

#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)
void checkCUDAErrorFn(const char* msg, const char* file, int line) {
#if ERRORCHECK
	cudaDeviceSynchronize();
	cudaError_t err = cudaGetLastError();
	if (cudaSuccess == err) {
		return;
	}

	fprintf(stderr, "CUDA error");
	if (file) {
		fprintf(stderr, " (%s:%d)", file, line);
	}
	fprintf(stderr, ": %s: %s\n", msg, cudaGetErrorString(err));
#  ifdef _WIN32
	getchar();
#  endif
	exit(EXIT_FAILURE);
#endif
}

__host__ __device__
thrust::default_random_engine makeSeededRandomEngine(int iter, int index, int depth) {
	int h = utilhash((1 << 31) | (depth << 22) | iter) ^ utilhash(index);
	return thrust::default_random_engine(h);
}

//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution,
	int iter, glm::vec3* image) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < resolution.x && y < resolution.y) {
		int index = x + (y * resolution.x);
		glm::vec3 pix = image[index];

		glm::ivec3 color;
		color.x = glm::clamp((int)(pix.x / iter * 255.0), 0, 255);
		color.y = glm::clamp((int)(pix.y / iter * 255.0), 0, 255);
		color.z = glm::clamp((int)(pix.z / iter * 255.0), 0, 255);

		// Each thread writes one pixel location in the texture (textel)
		pbo[index].w = 0;
		pbo[index].x = color.x;
		pbo[index].y = color.y;
		pbo[index].z = color.z;
	}
}

__global__ void gbufferToPBO(uchar4* pbo, glm::ivec2 resolution, GBufferPixel* gBuffer, bool showPosition) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;
	
	if (x < resolution.x && y < resolution.y) {
		int index = x + (y * resolution.x);
		glm::vec3 toShow = glm::abs(showPosition ? gBuffer[index].position / 10.f : gBuffer[index].normal) * 256.f;
		
		pbo[index].w = 0;
		pbo[index].x = glm::clamp((int)toShow.x, 0, 255);
		pbo[index].y = glm::clamp((int)toShow.y, 0, 255);
		pbo[index].z = glm::clamp((int)toShow.z, 0, 255);
    }
}

static Scene* hst_scene = NULL;
static GuiDataContainer* guiData = NULL;
static glm::vec3* dev_image = NULL;
static Geom* dev_geoms = NULL;
static Material* dev_materials = NULL;
static PathSegment* dev_paths = NULL;
static ShadeableIntersection* dev_intersections = NULL;
static GBufferPixel* dev_gBuffer = NULL;
// TODO: static variables for device memory, any extra info you need, etc
// ...
static thrust::device_ptr<PathSegment> dev_thrust_paths;
static thrust::device_ptr<ShadeableIntersection> dev_thrust_intersections;
static glm::vec2* dev_jitteredSample = NULL;
static thrust::device_ptr<glm::vec2> dev_thrust_jitteredSample;
static glm::vec3* dev_denoised1 = NULL;
static glm::vec3* dev_denoised2 = NULL;
static float* dev_filter = NULL;
static glm::ivec2* dev_offset = NULL;

void InitDataContainer(GuiDataContainer* imGuiData)
{
	guiData = imGuiData;
}

void pathtraceInit(Scene* scene) {
	hst_scene = scene;

	const Camera& cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));

	cudaMalloc(&dev_paths, pixelcount * sizeof(PathSegment));
	dev_thrust_paths = thrust::device_ptr<PathSegment>(dev_paths);

	cudaMalloc(&dev_geoms, scene->geoms.size() * sizeof(Geom));
	cudaMemcpy(dev_geoms, scene->geoms.data(), scene->geoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_materials, scene->materials.size() * sizeof(Material));
	cudaMemcpy(dev_materials, scene->materials.data(), scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_intersections, pixelcount * sizeof(ShadeableIntersection));
	dev_thrust_intersections = thrust::device_ptr<ShadeableIntersection>(dev_intersections);
	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

	cudaMalloc(&dev_gBuffer, pixelcount * sizeof(GBufferPixel));
	cudaMemset(dev_gBuffer, 0, pixelcount * sizeof(GBufferPixel));

	// TODO: initialize any extra device memeory you need
	cudaMalloc(&dev_jitteredSample, pixelcount * sizeof(glm::vec2));
	dev_thrust_jitteredSample = thrust::device_ptr<glm::vec2>(dev_jitteredSample);

	cudaMalloc(&dev_denoised1, pixelcount * sizeof(glm::vec3));
	cudaMalloc(&dev_denoised2, pixelcount * sizeof(glm::vec3));

	cudaMalloc(&dev_filter, 25 * sizeof(float));
	float filter[] = {
		0.0039f, 0.0156f, 0.0234f, 0.0156f, 0.0039f,
		0.0156f, 0.0625f, 0.0938f, 0.0625f, 0.0156f,
		0.0234f, 0.0938f, 0.1406f, 0.0938f, 0.0234f,
		0.0156f, 0.0625f, 0.0938f, 0.0625f, 0.0156f,
		0.0039f, 0.0156f, 0.0234f, 0.0156f, 0.0039f
	};
	cudaMemcpy(dev_filter, filter, 25 * sizeof(float), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_offset, 25 * sizeof(glm::ivec2));
	glm::ivec2 offset[] = {
		glm::ivec2(-2, -2), glm::ivec2(-1, -2), glm::ivec2(0, -2), glm::ivec2(1, -2), glm::ivec2(2, -2),
		glm::ivec2(-2, -1), glm::ivec2(-1, -1), glm::ivec2(0, -1), glm::ivec2(1, -1), glm::ivec2(2, -1),
		glm::ivec2(-2, 0), glm::ivec2(-1, 0), glm::ivec2(0, 0), glm::ivec2(1, 0), glm::ivec2(2, 0),
		glm::ivec2(-2, 1), glm::ivec2(-1, 1), glm::ivec2(0, 1), glm::ivec2(1, 1), glm::ivec2(2, 1),
		glm::ivec2(-2, 2), glm::ivec2(-1, 2), glm::ivec2(0, 2), glm::ivec2(1, 2), glm::ivec2(2, 2)
	};
	cudaMemcpy(dev_offset, offset, 25 * sizeof(glm::ivec2), cudaMemcpyHostToDevice);

	checkCUDAError("pathtraceInit");
}

void pathtraceFree() {
	cudaFree(dev_image);  // no-op if dev_image is null
	cudaFree(dev_paths);
	cudaFree(dev_geoms);
	cudaFree(dev_materials);
	cudaFree(dev_intersections);
	cudaFree(dev_gBuffer);
	// TODO: clean up any extra device memory you created
	cudaFree(dev_jitteredSample);
	cudaFree(dev_denoised1);
	cudaFree(dev_denoised2);
	cudaFree(dev_filter);
	cudaFree(dev_offset);
	checkCUDAError("pathtraceFree");
}

__global__ void jitteredSamping(Camera cam, int iter, glm::vec2* jitteredSample)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < cam.resolution.x && y < cam.resolution.y) {
		int index = x + (y * cam.resolution.x);
		thrust::default_random_engine rng = makeSeededRandomEngine(iter, index, 0);
		thrust::uniform_real_distribution<float> u01(0, 1);
		jitteredSample[index].x = (x + u01(rng)) / cam.resolution.x - 0.5f;
		jitteredSample[index].y = (y + u01(rng)) / cam.resolution.y - 0.5f;
	}
}

/**
* Generate PathSegments with rays from the camera through the screen into the
* scene, which is the first bounce of rays.
*
* Antialiasing - add rays for sub-pixel sampling
* motion blur - jitter rays "in time"
* lens effect - jitter ray origin positions based on a lens
*/
__global__ void generateRayFromCamera(Camera cam, int iter, int traceDepth, PathSegment* pathSegments, glm::vec2* jitteredSample)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < cam.resolution.x && y < cam.resolution.y) {
		int index = x + (y * cam.resolution.x);
		PathSegment& segment = pathSegments[index];
		glm::vec2 jitter = jitteredSample[index];

		segment.ray.origin = cam.position;
		segment.color = glm::vec3(1.0f, 1.0f, 1.0f);

		segment.ray.direction = glm::normalize(cam.view
			- cam.right * cam.pixelLength.x * ((float)x + jitter.x - (float)cam.resolution.x * 0.5f)
			- cam.up * cam.pixelLength.y * ((float)y + jitter.y - (float)cam.resolution.y * 0.5f)
		);

		segment.pixelIndex = index;
		segment.remainingBounces = traceDepth;
	}
}

__global__ void computeIntersections(
	int depth
	, int num_paths
	, PathSegment* pathSegments
	, Geom* geoms
	, int geoms_size
	, ShadeableIntersection* intersections
)
{
	int path_index = blockIdx.x * blockDim.x + threadIdx.x;

	if (path_index < num_paths)
	{
		PathSegment pathSegment = pathSegments[path_index];

		float t;
		glm::vec3 intersect_point;
		glm::vec3 normal;
		float t_min = FLT_MAX;
		int hit_geom_index = -1;
		bool outside = true;

		glm::vec3 tmp_intersect;
		glm::vec3 tmp_normal;

		// naive parse through global geoms

		for (int i = 0; i < geoms_size; i++)
		{
			Geom& geom = geoms[i];

			if (geom.type == CUBE)
			{
				t = boxIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			else if (geom.type == SPHERE)
			{
				t = sphereIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}

			// Compute the minimum t from the intersection tests to determine what
			// scene geometry object was hit first.
			if (t > 0.0f && t_min > t)
			{
				t_min = t;
				hit_geom_index = i;
				intersect_point = tmp_intersect;
				normal = tmp_normal;
			}
		}

		if (hit_geom_index == -1)
		{
			intersections[path_index].t = -1.0f;
		}
		else
		{
			//The ray hits something
			intersections[path_index].t = t_min;
			intersections[path_index].materialId = geoms[hit_geom_index].materialid;
			intersections[path_index].surfaceNormal = normal;
		}
	}
}

__global__ void shadeFakeMaterial(
	int iter
	, int num_paths
	, ShadeableIntersection* shadeableIntersections
	, PathSegment* pathSegments
	, Material* materials
	, glm::vec3* image
)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths)
	{
		ShadeableIntersection intersection = shadeableIntersections[idx];
		PathSegment &path = pathSegments[idx];
		if (intersection.t > 0.0f) { // if the intersection exists...
			// Set up the RNG
			thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, 0);
			thrust::uniform_real_distribution<float> u01(0, 1);

			Material material = materials[intersection.materialId];
			glm::vec3 materialColor = material.color;

			// If the material indicates that the object was a light, "light" the ray
			if (material.emittance > 0.0f) {
				pathSegments[idx].color *= (materialColor * material.emittance);
				image[path.pixelIndex] += path.color;
				path.remainingBounces = 0;
			}
			else {
				scatterRay(path, path.ray.origin + intersection.t * path.ray.direction, path.ray.origin + (intersection.t + 0.0002f) * path.ray.direction,
					intersection.surfaceNormal, material, rng);
				if (pathSegments[idx].remainingBounces == 0) {
					float lightTerm = glm::dot(intersection.surfaceNormal, glm::vec3(0.0f, 1.0f, 0.0f));
					path.color *= (materialColor * lightTerm) * 0.3f + ((1.0f - intersection.t * 0.02f) * materialColor) * 0.7f;
					path.color *= u01(rng); // apply some noise because why not
					image[path.pixelIndex] += path.color;
				}
			}
		}
		// If there was no intersection, color the ray black.
		// Lots of renderers use 4 channel color, RGBA, where A = alpha, often
		// used for opacity, in which case they can indicate "no opacity".
		// This can be useful for post-processing and image compositing.
		else {
			path.color = glm::vec3(0.0f);
			path.remainingBounces = 0;
		}
	}
}

__global__ void generateGBuffer (
	int num_paths,
	ShadeableIntersection* shadeableIntersections,
	PathSegment* pathSegments,
	GBufferPixel* gBuffer
)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths)
	{
		ShadeableIntersection intersection = shadeableIntersections[idx];
		PathSegment path = pathSegments[idx];
		GBufferPixel &gb = gBuffer[idx];
		gb.normal = intersection.surfaceNormal;
		gb.position = path.ray.origin + intersection.t * path.ray.direction;
	}
}

// Add the current iteration's output to the overall image
__global__ void finalGather(int nPaths, glm::vec3* image, PathSegment* iterationPaths)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < nPaths)
	{
		PathSegment iterationPath = iterationPaths[index];
		image[iterationPath.pixelIndex] += iterationPath.color;
	}
}

struct PathEnd {
	__host__ __device__ bool operator()(const PathSegment& pathSegment) {
		return pathSegment.remainingBounces == 0;
	}
};

struct MaterialComp {
	__host__ __device__ bool operator()(const ShadeableIntersection& intersection1, const ShadeableIntersection& intersection2) {
		return intersection1.materialId < intersection2.materialId;
	}
};

__global__ void kernDenoise(Camera cam, const glm::vec3* in, glm::vec3* out, const float* filter, const glm::ivec2* offset, int step,
	bool weighted, const GBufferPixel* gBuffer, float c_phi, float n_phi, float p_phi) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x >= cam.resolution.x || y >= cam.resolution.y) {
		return;
	}
	int index = x + (y * cam.resolution.x);
	glm::vec3 sum;
	float cum_w = 0.f;
	for (int i = 0; i < 25; i++) {
		int u = x + offset[i].x * step, v = y + offset[i].y * step;
		if (u < 0 || u >= cam.resolution.x || v < 0 || v >= cam.resolution.y) {
			continue;
		}
		int index_temp = u + (v * cam.resolution.x);
		if (weighted) {
			glm::vec3 t = in[index] - in[index_temp];
			float dist2 = glm::dot(t, t);
			float c_w = glm::min(glm::exp(-dist2 / c_phi), 1.f);

			t = gBuffer[index].normal - gBuffer[index_temp].normal;
			dist2 = glm::dot(t, t);
			float n_w = glm::min(glm::exp(-dist2 / n_phi), 1.f);

			t = gBuffer[index].position - gBuffer[index_temp].position;
			dist2 = glm::dot(t, t);
			float p_w = glm::min(glm::exp(-dist2 / p_phi), 1.f);

			float weight = c_w * n_w * p_w;
			sum += in[index_temp] * weight * filter[i];
			cum_w += weight * filter[i];
		}
		else {
			sum += in[index_temp] * filter[i];
			cum_w += filter[i];
		}
	}
	out[index] = sum / cum_w;
}

/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(int frame, int iter, bool denoise, int filter_size, bool weighted, float c_phi, float n_phi, float p_phi) {
	const int traceDepth = hst_scene->state.traceDepth;
	const Camera& cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	// 2D block for generating ray from camera
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// 1D block for path tracing
	const int blockSize1d = 128;

	///////////////////////////////////////////////////////////////////////////

	// Pathtracing Recap:
	// * Initialize array of path rays (using rays that come out of the camera)
	//   * You can pass the Camera object to that kernel.
	//   * Each path ray must carry at minimum a (ray, color) pair,
	//   * where color starts as the multiplicative identity, white = (1, 1, 1).
	//   * This has already been done for you.
	// * NEW: For the first depth, generate geometry buffers (gbuffers)
	// * For each depth:
	//   * Compute an intersection in the scene for each path ray.
	//     A very naive version of this has been implemented for you, but feel
	//     free to add more primitives and/or a better algorithm.
	//     Currently, intersection distance is recorded as a parametric distance,
	//     t, or a "distance along the ray." t = -1.0 indicates no intersection.
	//     * Color is attenuated (multiplied) by reflections off of any object
	//   * Stream compact away all of the terminated paths.
	//     You may use either your implementation or `thrust::remove_if` or its
	//     cousins.
	//     * Note that you can't really use a 2D kernel launch any more - switch
	//       to 1D.
	//   * Shade the rays that intersected something or didn't bottom out.
	//     That is, color the ray by performing a color computation according
	//     to the shader, then generate a new ray to continue the ray path.
	//     We recommend just updating the ray's PathSegment in place.
	//     Note that this step may come before or after stream compaction,
	//     since some shaders you write may also cause a path to terminate.
	// * Finally:
    //     * if not denoising, add this iteration's results to the image
    //     * TODO: if denoising, run kernels that take both the raw pathtraced result and the gbuffer, and put the result in the "pbo" from opengl

	// TODO: perform one iteration of path tracing
	jitteredSamping << <blocksPerGrid2d, blockSize2d >> > (cam, iter, dev_jitteredSample);
	thrust::shuffle(thrust::device, dev_thrust_jitteredSample, dev_thrust_jitteredSample + pixelcount, thrust::default_random_engine());
	checkCUDAError("jittered sampling");

	generateRayFromCamera << <blocksPerGrid2d, blockSize2d >> > (cam, iter, traceDepth, dev_paths, dev_jitteredSample);
	checkCUDAError("generate camera ray");

	int depth = 0;
	PathSegment* dev_path_end = dev_paths + pixelcount;
	int num_paths = dev_path_end - dev_paths;

	// --- PathSegment Tracing Stage ---
	// Shoot ray into scene, bounce between objects, push shading chunks

	bool iterationComplete = false;
	while (!iterationComplete) {

		// clean shading chunks
		cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

		// tracing
		dim3 numblocksPathSegmentTracing = (num_paths + blockSize1d - 1) / blockSize1d;
		computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
			depth
			, num_paths
			, dev_paths
			, dev_geoms
			, hst_scene->geoms.size()
			, dev_intersections
			);
		checkCUDAError("trace one bounce");
		cudaDeviceSynchronize();

		if (depth == 0) {
			generateGBuffer<<<numblocksPathSegmentTracing, blockSize1d>>>(num_paths, dev_intersections, dev_paths, dev_gBuffer);
		}

		depth++;

		shadeFakeMaterial << <numblocksPathSegmentTracing, blockSize1d >> > (
			iter,
			num_paths,
			dev_intersections,
			dev_paths,
			dev_materials,
			dev_image
			);
		checkCUDAError("shade path segments");
		cudaDeviceSynchronize();
		
		auto dev_thrust_path_end = thrust::remove_if(dev_thrust_paths, dev_thrust_paths + num_paths, PathEnd());
		checkCUDAError("stream compact");
		num_paths = dev_thrust_path_end - dev_thrust_paths;

		iterationComplete = num_paths == 0 || depth == traceDepth;

		if (guiData != NULL)
		{
			guiData->TracedDepth = depth;
		}
	}

	if (num_paths != 0) {
		// Assemble this iteration and apply it to the image
		dim3 numblocksPathSegmentTracing = (num_paths + blockSize1d - 1) / blockSize1d;
		finalGather << <numblocksPathSegmentTracing, blockSize1d >> > (num_paths, dev_image, dev_paths);
	}

	if (denoise) {
		for (int i = 0; i < filter_size; i++) {
			int step = 1 << i;
			if (i == 0) {
				kernDenoise << <blocksPerGrid2d, blockSize2d >> > (cam, dev_image, dev_denoised1, dev_filter, dev_offset, step,
					weighted, dev_gBuffer, c_phi, n_phi, p_phi);
			}
			else {
				kernDenoise << <blocksPerGrid2d, blockSize2d >> > (cam, dev_denoised1, dev_denoised2, dev_filter, dev_offset, step,
					weighted, dev_gBuffer, c_phi, n_phi, p_phi);
				std::swap(dev_denoised1, dev_denoised2);
			}
		}
	}

	///////////////////////////////////////////////////////////////////////////

	// CHECKITOUT: use dev_image as reference if you want to implement saving denoised images.
    // Otherwise, screenshots are also acceptable.
	// Retrieve image from GPU
	cudaMemcpy(hst_scene->state.image.data(), denoise ? dev_denoised1 : dev_image,
		pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);

	checkCUDAError("pathtrace");
}

// CHECKITOUT: this kernel "post-processes" the gbuffer/gbuffers into something that you can visualize for debugging.
void showGBuffer(uchar4* pbo, bool showPosition) {
	const Camera &cam = hst_scene->state.camera;
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);
	
	// CHECKITOUT: process the gbuffer results and send them to OpenGL buffer for visualization
	gbufferToPBO<<<blocksPerGrid2d, blockSize2d>>>(pbo, cam.resolution, dev_gBuffer, showPosition);
}

void showImage(uchar4* pbo, int iter, bool denoise) {
	const Camera &cam = hst_scene->state.camera;
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);
	
	// Send results to OpenGL buffer for rendering
	sendImageToPBO<<<blocksPerGrid2d, blockSize2d>>>(pbo, cam.resolution, iter, denoise ? dev_denoised1 : dev_image);
}
