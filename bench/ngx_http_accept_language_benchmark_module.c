/* Benchmark-only companion module: invokes the real registered handler. */
#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>
#include <time.h>

static char *ngx_http_accept_language_benchmark(ngx_conf_t *cf,
    ngx_command_t *cmd, void *conf);

static ngx_command_t ngx_http_accept_language_benchmark_commands[] = {
    { ngx_string("benchmark_accept_language"),
      NGX_HTTP_MAIN_CONF|NGX_CONF_TAKE4,
      ngx_http_accept_language_benchmark,
      NGX_HTTP_MAIN_CONF_OFFSET,
      0,
      NULL },
    ngx_null_command
};

static ngx_http_module_t ngx_http_accept_language_benchmark_ctx = {
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
};

ngx_module_t ngx_http_accept_language_benchmark_module = {
    NGX_MODULE_V1,
    &ngx_http_accept_language_benchmark_ctx,
    ngx_http_accept_language_benchmark_commands,
    NGX_HTTP_MODULE,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NGX_MODULE_V1_PADDING
};

static double
elapsed_ns(struct timespec *start, struct timespec *end)
{
    return (end->tv_sec - start->tv_sec) * 1000000000.0
           + end->tv_nsec - start->tv_nsec;
}

static char *
ngx_http_accept_language_benchmark(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    ngx_str_t                  *args;
    ngx_int_t                   iterations, n;
    ngx_uint_t                  i;
    ngx_hash_key_t             *keys;
    ngx_http_core_main_conf_t  *cmcf;
    ngx_http_variable_t        *variable = NULL;
    ngx_http_request_t          request;
    ngx_table_elt_t             header;
    ngx_http_variable_value_t   value;
    struct timespec            cpu_start, cpu_end, wall_start, wall_end;

    args = cf->args->elts;
    iterations = ngx_atoi(args[4].data, args[4].len);
    if (iterations <= 0) {
        return "requires a positive iteration count";
    }

    cmcf = ngx_http_conf_get_module_main_conf(cf, ngx_http_core_module);
    keys = cmcf->variables_keys->keys.elts;
    for (i = 0; i < cmcf->variables_keys->keys.nelts; i++) {
        if (keys[i].key.len == sizeof("bench_language") - 1
            && ngx_strncmp(keys[i].key.data, "bench_language",
                           sizeof("bench_language") - 1) == 0)
        {
            variable = keys[i].value;
            break;
        }
    }

    if (variable == NULL || variable->get_handler == NULL) {
        return "requires set_from_accept_language $bench_language first";
    }

    ngx_memzero(&request, sizeof(request));
    ngx_memzero(&header, sizeof(header));
    ngx_memzero(&value, sizeof(value));
    header.value = args[2];
    if (args[2].len != 1 || args[2].data[0] != '-') {
        request.headers_in.accept_language = &header;
    }

    if (variable->get_handler(&request, &value, variable->data) != NGX_OK
        || value.len != args[3].len
        || ngx_strncmp(value.data, args[3].data, value.len) != 0)
    {
        return "produced an unexpected language";
    }

    for (n = 0; n < 100000; n++) {
        variable->get_handler(&request, &value, variable->data);
    }

    if (clock_gettime(CLOCK_MONOTONIC, &wall_start) != 0
        || clock_gettime(CLOCK_THREAD_CPUTIME_ID, &cpu_start) != 0)
    {
        return "could not read the benchmark clock";
    }

    /* Runtime function pointer prevents inlining/removal of handler calls. */
    for (n = 0; n < iterations; n++) {
        variable->get_handler(&request, &value, variable->data);
    }

    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &cpu_end) != 0
        || clock_gettime(CLOCK_MONOTONIC, &wall_end) != 0)
    {
        return "could not read the benchmark clock";
    }

    printf("%.*s,%ld,%.3f,%.3f\n", (int) args[1].len, args[1].data,
           (long) iterations, elapsed_ns(&cpu_start, &cpu_end) / iterations,
           elapsed_ns(&wall_start, &wall_end) / iterations);
    return NGX_CONF_OK;
}
