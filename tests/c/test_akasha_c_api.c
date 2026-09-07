#define _XOPEN_SOURCE 700

#include "akasha.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define CHECK(expr) do { \
    if (!(expr)) { \
        fprintf(stderr, "CHECK failed at %s:%d: %s\n", __FILE__, __LINE__, #expr); \
        return 1; \
    } \
} while (0)

_Static_assert(sizeof(akasha_error_t) == 288, "error ABI layout changed");
_Static_assert(sizeof(akasha_collection_config_t) == 112,
               "config ABI layout changed");
_Static_assert(sizeof(akasha_search_options_t) == 32,
               "search options ABI layout changed");
_Static_assert(sizeof(akasha_search_result_t) == 32,
               "search result ABI layout changed");
_Static_assert(sizeof(akasha_search_stats_t) == 112,
               "search stats ABI layout changed");
_Static_assert(offsetof(akasha_search_result_t, id) == 16,
               "search result id offset changed");

static int expect_status(
    akasha_status_t actual,
    akasha_status_t expected,
    const akasha_error_t *error
) {
    if (actual != expected) {
        fprintf(stderr, "status %u != %u; error=%s\n", actual, expected,
                error == NULL ? "<null>" : error->message);
        return 0;
    }
    return 1;
}

static int test_contract_failures(const char *path) {
    akasha_error_t error;
    akasha_error_init(&error);
    akasha_collection_config_t config = akasha_collection_config_default(2);
    akasha_collection_t *collection = NULL;

    CHECK(expect_status(
        akasha_collection_open(NULL, 1, &config, &collection, &error),
        AKASHA_STATUS_INVALID_ARGUMENT, &error));
    CHECK(error.message_length > 0 && error.message[error.message_length] == '\0');
    CHECK(strstr(error.message, "path") != NULL);
    CHECK(expect_status(
        akasha_collection_open(path, strlen(path), NULL, &collection, &error),
        AKASHA_STATUS_INVALID_ARGUMENT, &error));
    CHECK(expect_status(
        akasha_collection_open(path, strlen(path), &config, NULL, &error),
        AKASHA_STATUS_INVALID_ARGUMENT, &error));
    CHECK(akasha_collection_open(path, strlen(path), &config, &collection, NULL)
          == AKASHA_STATUS_INVALID_ARGUMENT);

    config.struct_size--;
    CHECK(expect_status(
        akasha_collection_open(path, strlen(path), &config, &collection, &error),
        AKASHA_STATUS_INVALID_ARGUMENT, &error));
    config = akasha_collection_config_default(2);
    config.api_version++;
    CHECK(expect_status(
        akasha_collection_open(path, strlen(path), &config, &collection, &error),
        AKASHA_STATUS_INVALID_ARGUMENT, &error));
    config = akasha_collection_config_default(2);
    config.ann_metric = 99;
    CHECK(expect_status(
        akasha_collection_open(path, strlen(path), &config, &collection, &error),
        AKASHA_STATUS_INVALID_ARGUMENT, &error));
    config = akasha_collection_config_default(2);
    config.scalar_kind = 99;
    CHECK(expect_status(
        akasha_collection_open(path, strlen(path), &config, &collection, &error),
        AKASHA_STATUS_INVALID_ARGUMENT, &error));

    error.struct_size--;
    CHECK(akasha_collection_open(path, strlen(path), &config, &collection, &error)
          == AKASHA_STATUS_INVALID_ARGUMENT);
    akasha_error_init(&error);
    error.api_version++;
    CHECK(akasha_collection_open(path, strlen(path), &config, &collection, &error)
          == AKASHA_STATUS_INVALID_ARGUMENT);
    akasha_error_init(&error);
    error.message_capacity--;
    CHECK(akasha_collection_open(path, strlen(path), &config, &collection, &error)
          == AKASHA_STATUS_INVALID_ARGUMENT);
    akasha_error_init(&error);
    return 0;
}

static int test_lifecycle_and_persistence(const char *path) {
    akasha_error_t error;
    akasha_error_init(&error);
    akasha_collection_config_t config = akasha_collection_config_default(2);
    akasha_collection_t *collection = NULL;
    CHECK(expect_status(
        akasha_collection_open(path, strlen(path), &config, &collection, &error),
        AKASHA_STATUS_OK, &error));
    CHECK(collection != NULL);

    const float p9[2] = {0.0f, 0.0f};
    const float p3[2] = {1.0f, 0.0f};
    const float p7[2] = {2.0f, 0.0f};
    CHECK(expect_status(akasha_collection_upsert(collection, 9, p9, 2, &error),
                        AKASHA_STATUS_OK, &error));
    CHECK(expect_status(akasha_collection_upsert(collection, 3, p3, 2, &error),
                        AKASHA_STATUS_OK, &error));
    CHECK(expect_status(akasha_collection_upsert(collection, 7, p7, 1, &error),
                        AKASHA_STATUS_INVALID_ARGUMENT, &error));
    CHECK(expect_status(akasha_collection_upsert(collection, 7, NULL, 2, &error),
                        AKASHA_STATUS_INVALID_ARGUMENT, &error));
    const float nonfinite[2] = {NAN, 0.0f};
    CHECK(expect_status(akasha_collection_upsert(
        collection, 7, nonfinite, 2, &error),
        AKASHA_STATUS_INVALID_ARGUMENT, &error));
    CHECK(expect_status(akasha_collection_upsert(NULL, 7, p7, 2, &error),
                        AKASHA_STATUS_INVALID_ARGUMENT, &error));

    akasha_search_options_t options = akasha_search_options_default(2);
    akasha_search_result_t results[2];
    akasha_search_result_init(&results[0]);
    akasha_search_result_init(&results[1]);
    results[0].id = -1;
    results[1].id = -1;
    results[0].score = -1.0f;
    results[1].score = -1.0f;
    uint64_t count = UINT64_MAX;
    CHECK(expect_status(akasha_collection_search(
        collection, p9, 2, &options, results, 1, &count, &error),
        AKASHA_STATUS_BUFFER_TOO_SMALL, &error));
    CHECK(count == 2);
    CHECK(results[0].id == -1 && results[1].id == -1);
    count = UINT64_MAX;
    CHECK(expect_status(akasha_collection_search(
        collection, p9, 2, &options, NULL, 0, &count, &error),
        AKASHA_STATUS_BUFFER_TOO_SMALL, &error));
    CHECK(count == 2);
    CHECK(expect_status(akasha_collection_search(
        collection, p9, 2, &options, results, 2, &count, &error),
        AKASHA_STATUS_OK, &error));
    CHECK(count == 2);
    CHECK(results[0].id == 9 && results[1].id == 3);
    CHECK(fabsf(results[0].score - 0.0f) < 1e-6f);
    CHECK(fabsf(results[1].score - 1.0f) < 1e-6f);
    results[0].struct_size--;
    CHECK(expect_status(akasha_collection_search(
        collection, p9, 2, &options, results, 2, &count, &error),
        AKASHA_STATUS_INVALID_ARGUMENT, &error));
    akasha_search_result_init(&results[0]);

    results[0].api_version++;
    CHECK(expect_status(akasha_collection_search(
        collection, p9, 2, &options, results, 2, &count, &error),
        AKASHA_STATUS_INVALID_ARGUMENT, &error));
    akasha_search_result_init(&results[0]);

    options.struct_size--;
    CHECK(expect_status(akasha_collection_search(
        collection, p9, 2, &options, results, 2, &count, &error),
        AKASHA_STATUS_INVALID_ARGUMENT, &error));
    options = akasha_search_options_default(2);
    options.api_version++;
    CHECK(expect_status(akasha_collection_search(
        collection, p9, 2, &options, results, 2, &count, &error),
        AKASHA_STATUS_INVALID_ARGUMENT, &error));
    options = akasha_search_options_default(2);
    CHECK(expect_status(akasha_collection_search(
        collection, p9, 2, NULL, results, 2, &count, &error),
        AKASHA_STATUS_INVALID_ARGUMENT, &error));
    options.k = 0;
    CHECK(expect_status(akasha_collection_search(
        collection, p9, 2, &options, results, 2, &count, &error),
        AKASHA_STATUS_INVALID_ARGUMENT, &error));
    options = akasha_search_options_default(2);
    options.ef_search = config.max_ef_search + 1;
    CHECK(expect_status(akasha_collection_search(
        collection, p9, 2, &options, results, 2, &count, &error),
        AKASHA_STATUS_INVALID_ARGUMENT, &error));
    options = akasha_search_options_default(2);
    CHECK(expect_status(akasha_collection_search(
        collection, NULL, 2, &options, results, 2, &count, &error),
        AKASHA_STATUS_INVALID_ARGUMENT, &error));
    CHECK(expect_status(akasha_collection_search(
        collection, p9, 1, &options, results, 2, &count, &error),
        AKASHA_STATUS_INVALID_ARGUMENT, &error));
    CHECK(expect_status(akasha_collection_search(
        collection, p9, 2, &options, NULL, 2, &count, &error),
        AKASHA_STATUS_INVALID_ARGUMENT, &error));
    CHECK(expect_status(akasha_collection_search(
        collection, p9, 2, &options, results, 2, NULL, &error),
        AKASHA_STATUS_INVALID_ARGUMENT, &error));

    akasha_search_stats_t stats;
    akasha_search_stats_init(&stats);
    CHECK(expect_status(akasha_collection_last_search_stats(
        collection, NULL, &error), AKASHA_STATUS_INVALID_ARGUMENT, &error));
    CHECK(expect_status(akasha_collection_last_search_stats(
        collection, &stats, &error), AKASHA_STATUS_OK, &error));
    CHECK(stats.requested_ef == 64 && stats.effective_ef >= 64);
    stats.struct_size--;
    CHECK(expect_status(akasha_collection_last_search_stats(
        collection, &stats, &error), AKASHA_STATUS_INVALID_ARGUMENT, &error));
    akasha_search_stats_init(&stats);
    stats.api_version++;
    CHECK(expect_status(akasha_collection_last_search_stats(
        collection, &stats, &error), AKASHA_STATUS_INVALID_ARGUMENT, &error));

    CHECK(expect_status(akasha_collection_delete(collection, 3, &error),
                        AKASHA_STATUS_OK, &error));
    CHECK(expect_status(akasha_collection_delete(NULL, 3, &error),
                        AKASHA_STATUS_INVALID_ARGUMENT, &error));
    CHECK(expect_status(akasha_collection_flush(collection, &error),
                        AKASHA_STATUS_OK, &error));
    CHECK(expect_status(akasha_collection_flush(NULL, &error),
                        AKASHA_STATUS_INVALID_ARGUMENT, &error));
    CHECK(expect_status(akasha_collection_close(&collection, &error),
                        AKASHA_STATUS_OK, &error));
    CHECK(collection == NULL);
    CHECK(expect_status(akasha_collection_close(&collection, &error),
                        AKASHA_STATUS_OK, &error));
    CHECK(expect_status(akasha_collection_close(NULL, &error),
                        AKASHA_STATUS_INVALID_ARGUMENT, &error));

    CHECK(expect_status(
        akasha_collection_open(path, strlen(path), &config, &collection, &error),
        AKASHA_STATUS_OK, &error));
    options = akasha_search_options_default(2);
    count = 0;
    CHECK(expect_status(akasha_collection_search(
        collection, p9, 2, &options, results, 2, &count, &error),
        AKASHA_STATUS_OK, &error));
    CHECK(count == 1 && results[0].id == 9);
    CHECK(expect_status(akasha_collection_close(&collection, &error),
                        AKASHA_STATUS_OK, &error));
    return 0;
}

int main(void) {
    char path[256];
    CHECK(snprintf(path, sizeof(path), "/tmp/akasha-c-api-%ld", (long)getpid())
          > 0);
    CHECK(mkdir(path, 0700) == 0);
    char collection_path[512];
    CHECK(snprintf(collection_path, sizeof(collection_path), "%s/collection", path)
          > 0);

    CHECK(test_contract_failures(collection_path) == 0);
    CHECK(test_lifecycle_and_persistence(collection_path) == 0);
    return 0;
}
