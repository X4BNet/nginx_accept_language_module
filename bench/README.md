# Accept-Language benchmarks

The runner measures 1, 10, 100 and 200 configured languages. Each language is an equal-length private-use tag (`x-000` through `x-199`), keeping token length independent of the number of configured languages.

## Build

Build a separate nginx binary with the normal module and the benchmark companion. The companion is only needed for these measurements; it is not included in normal module builds.

From an nginx source directory, substituting the absolute repository path:

```bash
./configure --with-cc-opt=-O2 \
  --add-module=/path/to/nginx_accept_language_module \
  --add-module=/path/to/nginx_accept_language_module/bench
make -j2
```

For HTTP throughput measurements, also build or install [wrk](https://github.com/wg/wrk).

## Run

From the repository root:

```bash
python3 bench/run.py \
  --nginx /path/to/nginx/objs/nginx \
  --wrk /path/to/wrk \
  --server-cpu 0 --client-cpu 1 \
  --output /tmp/accept-language-results
```

Choose two available CPUs for the affinity arguments, or omit them to leave affinity unrestricted. Omit `--wrk` to run only the handler benchmark. The runner requires Linux, Python 3 and `taskset` when setting affinity. It creates and stops its own temporary nginx instances; it does not use an installed server's configuration.

## Method

The benchmark companion locates the actual `$bench_language` variable registered by `set_from_accept_language`. After checking the expected result and warming up with 100,000 calls, it invokes that variable's real handler 5,000,000 times per sample. It does not reimplement the parser or hash. Each sample bypasses nginx's request-variable cache, measuring one fresh handler evaluation per call. Hash construction and configuration parsing are outside the timed region.

The handler benchmark uses seven samples per language count and case, with deterministic shuffled ordering. It records thread CPU time and monotonic elapsed time in nanoseconds per call. CPU time excludes time when the process is not scheduled. These are hot-cache timings for a repeated header, including the function call and loop, not full HTTP request latency.

Cases are: a single token matching the first configured language; a single token matching the last configured language; three unsupported preferences; a match after three unsupported preferences; and an absent header. First/last refer to configuration order. The fourth-preference case measures additional header parsing separately.

The optional HTTP benchmark uses one nginx process, one wrk thread and 32 keep-alive connections over localhost. Access logging is disabled and the response body contains the selected language, forcing evaluation. It checks response bodies before loading the server, warms up for one second, then measures five three-second samples per language count and case. It covers first match, last match, three unsupported preferences, and a same-sized constant response that does not evaluate the variable. Count and case order are shuffled. Any socket, status or timeout error fails the run.

`handler.csv` and `http.csv` contain raw samples; the corresponding `*-summary.csv` files contain medians and ranges. `metadata.json` records the invocation, CPU, nginx version/build flags, module source digest and exact headers. Full HTTP results include network, request parsing, variable evaluation and response generation, so small differences should be interpreted alongside run-to-run variation and the constant-response baseline.

## Recorded run: 2026-10-02

nginx 1.30.5, GCC 14.2.0, `-O2` without debug, AMD EPYC 7452 in a Xen VM. nginx was pinned to CPU 64 and wrk 4.2.0 to CPU 78. The default iterations, repeats, durations and connection count described above were used. All 80 HTTP samples reported zero errors.

| Accepted languages | First match (ns/call) | Last match (ns/call) | Three misses (ns/call) | Fourth preference matches (ns/call) | Last-match HTTP requests/sec |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 16.6 | 16.9 | 46.7 | 59.5 | 45,749 |
| 10 | 16.5 | 24.8 | 58.7 | 83.6 | 44,859 |
| 100 | 16.3 | 22.8 | 55.5 | 81.1 | 46,761 |
| 200 | 16.3 | 19.6 | 57.4 | 77.9 | 44,905 |

Values are medians; handler columns use thread CPU time. With no header, the handler took approximately 3.7–3.8 ns/call at all four sizes. First and last matches each inspect one header token; differences between them can reflect hash bucket layout as well as measurement variation.

The accepted-language count did not produce a linear increase in lookup cost. Parsing several header preferences costs more than a single-token match. HTTP throughput had substantial variation on this shared VM: last-match sample ranges were 42,723–51,251; 44,360–47,621; 41,251–83,630; and 41,733–49,541 requests/sec, respectively. Constant-response medians were 49,327; 47,130; 45,656; and 45,002 requests/sec. These overlapping ranges do not establish a throughput difference between list sizes.

[Raw data and metadata](results/2026-10-02) are included with this run. The HTTP results measure local benchmark throughput, while the handler results isolate the parsing/hash cost for repeated, hot-cache inputs.
