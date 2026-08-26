#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

typedef int32_t (*akasha_worker_callback)(void *context);

struct akasha_worker {
    pthread_t thread;
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    void *context;
    akasha_worker_callback callback;
    bool pending;
    bool running;
    bool closing;
    int32_t failure;
};

static void *akasha_worker_main(void *raw) {
    struct akasha_worker *worker = (struct akasha_worker *)raw;
    pthread_mutex_lock(&worker->mutex);
    for (;;) {
        while (!worker->pending && !worker->closing) {
            pthread_cond_wait(&worker->condition, &worker->mutex);
        }
        if (worker->closing && !worker->pending) {
            break;
        }
        worker->pending = false;
        worker->running = true;
        pthread_mutex_unlock(&worker->mutex);

        int32_t result = worker->callback(worker->context);

        pthread_mutex_lock(&worker->mutex);
        worker->running = false;
        if (result != 0) {
            worker->failure = result;
            worker->pending = false;
        }
        pthread_cond_broadcast(&worker->condition);
    }
    pthread_cond_broadcast(&worker->condition);
    pthread_mutex_unlock(&worker->mutex);
    return NULL;
}

void *akasha_worker_open(void *context, akasha_worker_callback callback) {
    if (callback == NULL) {
        return NULL;
    }
    struct akasha_worker *worker = calloc(1, sizeof(*worker));
    if (worker == NULL) {
        return NULL;
    }
    worker->context = context;
    worker->callback = callback;
    if (pthread_mutex_init(&worker->mutex, NULL) != 0) {
        free(worker);
        return NULL;
    }
    if (pthread_cond_init(&worker->condition, NULL) != 0) {
        pthread_mutex_destroy(&worker->mutex);
        free(worker);
        return NULL;
    }
    if (pthread_create(&worker->thread, NULL, akasha_worker_main, worker) != 0) {
        pthread_cond_destroy(&worker->condition);
        pthread_mutex_destroy(&worker->mutex);
        free(worker);
        return NULL;
    }
    return worker;
}

int32_t akasha_worker_valid(void *raw) {
    return raw != NULL;
}

int32_t akasha_worker_request(void *raw) {
    struct akasha_worker *worker = (struct akasha_worker *)raw;
    pthread_mutex_lock(&worker->mutex);
    if (worker->closing) {
        pthread_mutex_unlock(&worker->mutex);
        return -1;
    }
    if (worker->failure != 0) {
        pthread_mutex_unlock(&worker->mutex);
        return -2;
    }
    if (worker->pending) {
        pthread_mutex_unlock(&worker->mutex);
        return 0;
    }
    worker->pending = true;
    pthread_cond_signal(&worker->condition);
    pthread_mutex_unlock(&worker->mutex);
    return 1;
}

int32_t akasha_worker_pending_count(void *raw) {
    struct akasha_worker *worker = (struct akasha_worker *)raw;
    pthread_mutex_lock(&worker->mutex);
    int32_t result = worker->pending ? 1 : 0;
    pthread_mutex_unlock(&worker->mutex);
    return result;
}

int32_t akasha_worker_is_running(void *raw) {
    struct akasha_worker *worker = (struct akasha_worker *)raw;
    pthread_mutex_lock(&worker->mutex);
    int32_t result = worker->running ? 1 : 0;
    pthread_mutex_unlock(&worker->mutex);
    return result;
}

int32_t akasha_worker_drain(void *raw) {
    struct akasha_worker *worker = (struct akasha_worker *)raw;
    pthread_mutex_lock(&worker->mutex);
    while (worker->pending || worker->running) {
        pthread_cond_wait(&worker->condition, &worker->mutex);
    }
    int32_t result = worker->failure;
    pthread_mutex_unlock(&worker->mutex);
    return result;
}

int32_t akasha_worker_close(void *raw) {
    struct akasha_worker *worker = (struct akasha_worker *)raw;
    pthread_mutex_lock(&worker->mutex);
    worker->closing = true;
    pthread_cond_broadcast(&worker->condition);
    pthread_mutex_unlock(&worker->mutex);

    int32_t join_result = (int32_t)pthread_join(worker->thread, NULL);
    int32_t result = worker->failure != 0 ? worker->failure : join_result;
    pthread_cond_destroy(&worker->condition);
    pthread_mutex_destroy(&worker->mutex);
    free(worker);
    return result;
}
