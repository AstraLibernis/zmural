#include "waywallen_display_vulkan_presenter.h"

#include "backend_vulkan_blit.h"

#include <errno.h>
#include <stdlib.h>

struct waywallen_vulkan_presentable {
#ifdef WW_HAVE_VULKAN
    ww_vk_retained_shadow_t shadow;
#endif
    struct waywallen_vulkan_presentable* next;
};

struct waywallen_vulkan_presenter {
#ifdef WW_HAVE_VULKAN
    ww_vk_blitter_t blitter;
#endif
    waywallen_vulkan_presentable_t* retained;
};

#ifdef WW_HAVE_VULKAN
static void describe_shadow(VkImage image, uint32_t width, uint32_t height, VkFormat format,
                            VkImageLayout layout, VkDeviceSize allocation_size, bool has_content,
                            waywallen_vulkan_presentable_descriptor_t* descriptor) {
    *descriptor = (waywallen_vulkan_presentable_descriptor_t) {
        .image           = (void*)image,
        .width           = width,
        .height          = height,
        .format          = (uint32_t)format,
        .layout          = (uint32_t)layout,
        .allocation_size = (uint64_t)allocation_size,
        .has_content     = has_content,
    };
}
#endif

int waywallen_vulkan_presenter_create(void* instance, void* physical_device, void* device,
                                      uint32_t queue_family_index, void* queue,
                                      void* (*get_instance_proc_addr)(void*, const char*),
                                      waywallen_vulkan_presenter_t** presenter) {
    if (! presenter) return -EINVAL;
    *presenter = NULL;
#ifdef WW_HAVE_VULKAN
    waywallen_vulkan_presenter_t* value = calloc(1, sizeof(*value));
    if (! value) return -ENOMEM;
    const int result = ww_vk_blitter_init(&value->blitter,
                                          (VkInstance)instance,
                                          (VkPhysicalDevice)physical_device,
                                          (VkDevice)device,
                                          queue_family_index,
                                          (VkQueue)queue,
                                          (ww_vk_get_instance_proc_addr_fn)get_instance_proc_addr);
    if (result != 0) {
        free(value);
        return result;
    }
    *presenter = value;
    return 0;
#else
    (void)instance;
    (void)physical_device;
    (void)device;
    (void)queue_family_index;
    (void)queue;
    (void)get_instance_proc_addr;
    return -ENOSYS;
#endif
}

void waywallen_vulkan_presenter_destroy(waywallen_vulkan_presenter_t* presenter) {
    if (! presenter) return;
#ifdef WW_HAVE_VULKAN
    (void)ww_vk_blitter_drain_pending_release(&presenter->blitter, NULL);
    while (presenter->retained) {
        waywallen_vulkan_presentable_t* retained = presenter->retained;
        presenter->retained                      = retained->next;
        ww_vk_blitter_release_retained(&presenter->blitter, &retained->shadow);
        free(retained);
    }
    ww_vk_blitter_shutdown(&presenter->blitter);
#endif
    free(presenter);
}

int waywallen_vulkan_presenter_prepare(waywallen_vulkan_presenter_t* presenter,
                                       void* imported_image, uint32_t width, uint32_t height,
                                       uint32_t fourcc, bool force_replace, bool reuse_candidate,
                                       void* acquire_semaphore, int release_syncobj_fd,
                                       bool* candidate_ready, bool* release_armed) {
#ifdef WW_HAVE_VULKAN
    if (! presenter) return -EINVAL;
    return ww_vk_blitter_prepare_reusing_candidate(&presenter->blitter,
                                                   (VkImage)imported_image,
                                                   width,
                                                   height,
                                                   fourcc,
                                                   force_replace,
                                                   reuse_candidate,
                                                   (VkSemaphore)acquire_semaphore,
                                                   release_syncobj_fd,
                                                   candidate_ready,
                                                   release_armed);
#else
    (void)presenter;
    (void)imported_image;
    (void)width;
    (void)height;
    (void)fourcc;
    (void)force_replace;
    (void)reuse_candidate;
    (void)acquire_semaphore;
    (void)release_syncobj_fd;
    (void)candidate_ready;
    (void)release_armed;
    return -ENOSYS;
#endif
}

int waywallen_vulkan_presenter_commit(waywallen_vulkan_presenter_t*    presenter,
                                      waywallen_vulkan_presentable_t** retained_outgoing) {
    if (! presenter || ! retained_outgoing || *retained_outgoing) return -EINVAL;
#ifdef WW_HAVE_VULKAN
    waywallen_vulkan_presentable_t* retained = calloc(1, sizeof(*retained));
    if (! retained) return -ENOMEM;
    const VkResult result =
        ww_vk_blitter_commit_candidate_retaining(&presenter->blitter, &retained->shadow);
    if (result != VK_SUCCESS) {
        free(retained);
        return -EIO;
    }
    if (retained->shadow.image == VK_NULL_HANDLE && retained->shadow.memory == VK_NULL_HANDLE) {
        free(retained);
        *retained_outgoing = NULL;
        return 0;
    }
    retained->next      = presenter->retained;
    presenter->retained = retained;
    *retained_outgoing  = retained;
    return 0;
#else
    return -ENOSYS;
#endif
}

int waywallen_vulkan_presenter_discard_candidate(waywallen_vulkan_presenter_t* presenter) {
#ifdef WW_HAVE_VULKAN
    return presenter ? ww_vk_blitter_discard_candidate(&presenter->blitter) : -EINVAL;
#else
    (void)presenter;
    return -ENOSYS;
#endif
}

int waywallen_vulkan_presenter_drain_pending_release(waywallen_vulkan_presenter_t* presenter,
                                                     bool*                         release_armed) {
#ifdef WW_HAVE_VULKAN
    return presenter ? ww_vk_blitter_drain_pending_release(&presenter->blitter, release_armed)
                     : -EINVAL;
#else
    (void)presenter;
    (void)release_armed;
    return -ENOSYS;
#endif
}

bool waywallen_vulkan_presenter_current(const waywallen_vulkan_presenter_t*        presenter,
                                        waywallen_vulkan_presentable_descriptor_t* descriptor) {
    if (! presenter || ! descriptor) return false;
#ifdef WW_HAVE_VULKAN
    describe_shadow(presenter->blitter.shadow_image,
                    presenter->blitter.shadow_w,
                    presenter->blitter.shadow_h,
                    presenter->blitter.shadow_fmt,
                    ww_vk_blitter_shadow_layout(&presenter->blitter),
                    presenter->blitter.shadow_allocation_size,
                    presenter->blitter.shadow_has_content,
                    descriptor);
    return descriptor->image != NULL;
#else
    return false;
#endif
}

bool waywallen_vulkan_presenter_candidate(const waywallen_vulkan_presenter_t*        presenter,
                                          waywallen_vulkan_presentable_descriptor_t* descriptor) {
    if (! presenter || ! descriptor) return false;
#ifdef WW_HAVE_VULKAN
    describe_shadow(presenter->blitter.candidate_image,
                    presenter->blitter.candidate_w,
                    presenter->blitter.candidate_h,
                    presenter->blitter.candidate_fmt,
                    ww_vk_blitter_shadow_layout(&presenter->blitter),
                    presenter->blitter.candidate_allocation_size,
                    presenter->blitter.candidate_has_content,
                    descriptor);
    return descriptor->image != NULL;
#else
    return false;
#endif
}

bool waywallen_vulkan_presentable_descriptor(
    const waywallen_vulkan_presentable_t*      presentable,
    waywallen_vulkan_presentable_descriptor_t* descriptor) {
    if (! presentable || ! descriptor) return false;
#ifdef WW_HAVE_VULKAN
    describe_shadow(presentable->shadow.image,
                    presentable->shadow.width,
                    presentable->shadow.height,
                    presentable->shadow.format,
                    presentable->shadow.layout,
                    presentable->shadow.allocation_size,
                    presentable->shadow.has_content,
                    descriptor);
    return descriptor->image != NULL;
#else
    return false;
#endif
}

void waywallen_vulkan_presenter_release(waywallen_vulkan_presenter_t*   presenter,
                                        waywallen_vulkan_presentable_t* presentable) {
    if (! presenter || ! presentable) return;
#ifdef WW_HAVE_VULKAN
    waywallen_vulkan_presentable_t** link = &presenter->retained;
    while (*link && *link != presentable) link = &(*link)->next;
    if (! *link) return;
    *link = presentable->next;
    ww_vk_blitter_release_retained(&presenter->blitter, &presentable->shadow);
    free(presentable);
#endif
}

bool waywallen_vulkan_presenter_busy(const waywallen_vulkan_presenter_t* presenter) {
#ifdef WW_HAVE_VULKAN
    return presenter && presenter->blitter.fence_armed;
#else
    (void)presenter;
    return false;
#endif
}
