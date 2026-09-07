#ifndef AKASHA_H
#define AKASHA_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define AKASHA_ABI_VERSION UINT64_C(1)
#define AKASHA_ERROR_MESSAGE_CAPACITY UINT64_C(256)

typedef uint32_t akasha_status_t;

enum {
    AKASHA_STATUS_OK = 0,
    AKASHA_STATUS_INVALID_ARGUMENT = 1,
    AKASHA_STATUS_BUFFER_TOO_SMALL = 2,
    AKASHA_STATUS_ENGINE_ERROR = 3
};

enum {
    AKASHA_METRIC_DOT = 0,
    AKASHA_METRIC_L2 = 1,
    AKASHA_METRIC_COSINE = 2
};

enum {
    AKASHA_SCALAR_F32 = 0,
    AKASHA_SCALAR_BF16 = 1,
    AKASHA_SCALAR_F16 = 2,
    AKASHA_SCALAR_I8 = 3
};

typedef struct akasha_collection akasha_collection_t;

typedef struct akasha_error {
    uint64_t struct_size;
    uint64_t api_version;
    uint64_t message_capacity;
    uint64_t message_length;
    char message[256];
} akasha_error_t;

typedef struct akasha_collection_config {
    uint64_t struct_size;
    uint64_t api_version;
    uint64_t dimension;
    uint64_t ann_metric;
    uint64_t scalar_kind;
    uint64_t m;
    uint64_t m0;
    uint64_t ef_construction;
    uint64_t default_ef_search;
    uint64_t max_ef_search;
    uint64_t max_level;
    uint64_t rebuild_inactive_percent;
    uint64_t delta_max_points;
    uint64_t level_seed;
} akasha_collection_config_t;

typedef struct akasha_search_options {
    uint64_t struct_size;
    uint64_t api_version;
    uint64_t k;
    uint64_t ef_search;
} akasha_search_options_t;

typedef struct akasha_search_result {
    uint64_t struct_size;
    uint64_t api_version;
    int64_t id;
    float score;
    uint32_t reserved;
} akasha_search_result_t;

typedef struct akasha_search_stats {
    uint64_t struct_size;
    uint64_t api_version;
    uint64_t requested_ef;
    uint64_t effective_ef;
    uint64_t widening_rounds;
    uint64_t upper_visited;
    uint64_t base_visited;
    uint64_t distance_evaluations;
    uint64_t retained_candidates;
    uint64_t reranked_candidates;
    uint64_t filtered_rejections;
    uint64_t inactive_rejections;
    uint64_t base_candidates;
    uint64_t delta_candidates;
} akasha_search_stats_t;

static inline void akasha_error_init(akasha_error_t *error) {
    if (error == NULL) return;
    error->struct_size = sizeof(*error);
    error->api_version = AKASHA_ABI_VERSION;
    error->message_capacity = AKASHA_ERROR_MESSAGE_CAPACITY;
    error->message_length = 0;
    error->message[0] = '\0';
}

static inline akasha_collection_config_t akasha_collection_config_default(
    uint64_t dimension
) {
    akasha_collection_config_t config = {
        sizeof(akasha_collection_config_t), AKASHA_ABI_VERSION, dimension,
        AKASHA_METRIC_L2, AKASHA_SCALAR_F32, 16, 32, 128, 64, 512, 32, 25,
        10000, UINT64_C(0xA5A5A5A5A5A5A5A5)
    };
    return config;
}

static inline akasha_search_options_t akasha_search_options_default(
    uint64_t k
) {
    akasha_search_options_t options = {
        sizeof(akasha_search_options_t), AKASHA_ABI_VERSION, k, 64
    };
    return options;
}

static inline void akasha_search_stats_init(akasha_search_stats_t *stats) {
    if (stats == NULL) return;
    *stats = (akasha_search_stats_t){0};
    stats->struct_size = sizeof(*stats);
    stats->api_version = AKASHA_ABI_VERSION;
}

static inline void akasha_search_result_init(akasha_search_result_t *result) {
    if (result == NULL) return;
    *result = (akasha_search_result_t){0};
    result->struct_size = sizeof(*result);
    result->api_version = AKASHA_ABI_VERSION;
}

/* Input buffers are borrowed only for the duration of each call. */
akasha_status_t akasha_collection_open(
    const char *path,
    uint64_t path_length,
    const akasha_collection_config_t *config,
    akasha_collection_t **out_collection,
    akasha_error_t *error
);

/* Releases the handle once and sets *collection to NULL; NULL is idempotent. */
akasha_status_t akasha_collection_close(
    akasha_collection_t **collection,
    akasha_error_t *error
);

akasha_status_t akasha_collection_upsert(
    akasha_collection_t *collection,
    int64_t id,
    const float *vector,
    uint64_t dimension,
    akasha_error_t *error
);

akasha_status_t akasha_collection_delete(
    akasha_collection_t *collection,
    int64_t id,
    akasha_error_t *error
);

akasha_status_t akasha_collection_flush(
    akasha_collection_t *collection,
    akasha_error_t *error
);

/*
 * out_count always receives the required/actual result count. If capacity is
 * too small, no result element is written and BUFFER_TOO_SMALL is returned.
 */
akasha_status_t akasha_collection_search(
    akasha_collection_t *collection,
    const float *query,
    uint64_t dimension,
    const akasha_search_options_t *options,
    akasha_search_result_t *results,
    uint64_t result_capacity,
    uint64_t *out_count,
    akasha_error_t *error
);

akasha_status_t akasha_collection_last_search_stats(
    akasha_collection_t *collection,
    akasha_search_stats_t *stats,
    akasha_error_t *error
);

#ifdef __cplusplus
}
#endif

#endif
