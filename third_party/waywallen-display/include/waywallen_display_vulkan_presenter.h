#ifndef WAYWALLEN_DISPLAY_VULKAN_PRESENTER_H
#define WAYWALLEN_DISPLAY_VULKAN_PRESENTER_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct waywallen_vulkan_presenter   waywallen_vulkan_presenter_t;
typedef struct waywallen_vulkan_presentable waywallen_vulkan_presentable_t;

typedef struct waywallen_vulkan_presentable_descriptor {
    void*    image;
    uint32_t width;
    uint32_t height;
    uint32_t format;
    uint32_t layout;
    uint64_t allocation_size;
    bool     has_content;
} waywallen_vulkan_presentable_descriptor_t;

/* All calls run on the host queue's owner thread. The presenter owns native
 * images; retained handles stay owned until release. */
int  waywallen_vulkan_presenter_create(void* instance, void* physical_device, void* device,
                                       uint32_t queue_family_index, void* queue,
                                       void* (*get_instance_proc_addr)(void*, const char*),
                                       waywallen_vulkan_presenter_t** presenter);
void waywallen_vulkan_presenter_destroy(waywallen_vulkan_presenter_t* presenter);

int waywallen_vulkan_presenter_prepare(waywallen_vulkan_presenter_t* presenter,
                                       void* imported_image, uint32_t width, uint32_t height,
                                       uint32_t fourcc, bool force_replace, bool reuse_candidate,
                                       void* acquire_semaphore, int release_syncobj_fd,
                                       bool* candidate_ready, bool* release_armed);
int waywallen_vulkan_presenter_commit(waywallen_vulkan_presenter_t*    presenter,
                                      waywallen_vulkan_presentable_t** retained_outgoing);
int waywallen_vulkan_presenter_discard_candidate(waywallen_vulkan_presenter_t* presenter);
int waywallen_vulkan_presenter_drain_pending_release(waywallen_vulkan_presenter_t* presenter,
                                                     bool*                         release_armed);

bool waywallen_vulkan_presenter_current(const waywallen_vulkan_presenter_t*        presenter,
                                        waywallen_vulkan_presentable_descriptor_t* descriptor);
bool waywallen_vulkan_presenter_candidate(const waywallen_vulkan_presenter_t*        presenter,
                                          waywallen_vulkan_presentable_descriptor_t* descriptor);
bool waywallen_vulkan_presentable_descriptor(const waywallen_vulkan_presentable_t*      presentable,
                                             waywallen_vulkan_presentable_descriptor_t* descriptor);
void waywallen_vulkan_presenter_release(waywallen_vulkan_presenter_t*   presenter,
                                        waywallen_vulkan_presentable_t* presentable);
bool waywallen_vulkan_presenter_busy(const waywallen_vulkan_presenter_t* presenter);

#ifdef __cplusplus
}
#endif

#endif
