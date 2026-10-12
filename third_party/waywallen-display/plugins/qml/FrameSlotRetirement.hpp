#pragma once

#include <cstdint>
#include <utility>
#include <vector>

struct FrameSlotRetirement {
    int           slot { -1 };
    std::uint64_t serial { 0 };

    bool ready(int currentSlot, std::uint64_t currentSerial) const {
        return slot >= 0 && currentSlot == slot && currentSerial > serial;
    }
};

template<typename Resource>
class FrameSlotRetirementQueue {
public:
    void retire(Resource resource, FrameSlotRetirement retirement) {
        m_entries.push_back({ std::move(resource), retirement });
    }

    template<typename Destroy>
    void collect(int frameSlot, std::uint64_t frameSerial, Destroy destroy) {
        for (auto iter = m_entries.begin(); iter != m_entries.end();) {
            if (! iter->retirement.ready(frameSlot, frameSerial)) {
                ++iter;
                continue;
            }
            destroy(iter->resource);
            iter = m_entries.erase(iter);
        }
    }

    template<typename Destroy>
    void drain(Destroy destroy) {
        for (auto& entry : m_entries) destroy(entry.resource);
        m_entries.clear();
    }

    bool empty() const { return m_entries.empty(); }

private:
    struct Entry {
        Resource            resource;
        FrameSlotRetirement retirement;
    };
    std::vector<Entry> m_entries;
};
