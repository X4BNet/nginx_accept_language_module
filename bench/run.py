"""Benchmark the real handler and optional localhost HTTP requests (Linux)."""

import argparse
import csv
import hashlib
import http.client
import io
import json
import os
from pathlib import Path
import platform
import random
import socket
import statistics
import subprocess
import tempfile
import time


COUNTS = (1, 10, 100, 200)


def cases(count):
    last = f"x-{count - 1:03d}"
    return {
        "first_match": ("x-000", "x-000"),
        "last_match": (last, last),
        "no_match": ("x-997,x-998;q=0.8,x-999;q=0.5", "x-000"),
        "fourth_preference": (f"x-997,x-998;q=0.9,x-999;q=0.8,{last};q=0.7", last),
        "no_header": (None, "x-000"),
    }


def pinned(command, cpu):
    return (["taskset", "-c", str(cpu)] if cpu is not None else []) + command


def execute(command, **kwargs):
    result = subprocess.run(command, capture_output=True, text=True,
                            timeout=120, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{command}\n{result.stdout}\n{result.stderr}")
    return result.stdout


def configuration(count, extra):
    languages = " ".join(f"x-{i:03d}" for i in range(count))
    return ("daemon off;\nmaster_process off;\npid nginx.pid;\n"
            "error_log stderr crit;\nevents { worker_connections 1024; }\n"
            "http {\naccess_log off;\nkeepalive_requests 1000000;\n"
            f"set_from_accept_language $bench_language {languages};\n"
            + extra + "\n}\n")


def summarize(path, rows, metric):
    with path.open("w", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(["languages", "case", f"median_{metric}",
                         f"min_{metric}", f"max_{metric}"])
        for count in COUNTS:
            for name in dict.fromkeys(row["case"] for row in rows):
                values = [float(row[metric]) for row in rows
                          if row["languages"] == count and row["case"] == name]
                if values:
                    writer.writerow([count, name, statistics.median(values),
                                     min(values), max(values)])


def handler_benchmark(args, directory, rng):
    rows = []
    fields = ["languages", "repeat", "case", "iterations", "cpu_ns", "wall_ns"]
    with (args.output / "handler.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        for repeat in range(1, args.handler_repeats + 1):
            for count in rng.sample(COUNTS, len(COUNTS)):
                workloads = list(cases(count).items())
                rng.shuffle(workloads)
                directives = "\n".join(
                    f'benchmark_accept_language {name} "{header or "-"}" '
                    f'{expected} {args.iterations};'
                    for name, (header, expected) in workloads)
                (directory / "nginx.conf").write_text(configuration(count, directives))
                command = pinned([str(args.nginx), "-p", str(directory) + "/",
                                  "-c", "nginx.conf", "-e", "stderr", "-t"],
                                 args.server_cpu)
                output = execute(command)
                samples = list(csv.reader(io.StringIO(output)))
                if len(samples) != len(workloads):
                    raise RuntimeError(f"Missing handler samples: {output}")
                for name, iterations, cpu_ns, wall_ns in samples:
                    row = dict(zip(fields, [count, repeat, name, iterations,
                                            cpu_ns, wall_ns]))
                    rows.append(row)
                    writer.writerow(row)
                stream.flush()
                print(f"handler: repeat {repeat}, {count} languages", flush=True)
    summarize(args.output / "handler-summary.csv", rows, "cpu_ns")


def http_benchmark(args, directory, rng):
    script = directory / "report.lua"
    script.write_text('''
done = function(summary, latency, requests)
    local errors = summary.errors
    io.write(string.format("BENCH %.3f %.3f %.3f %.3f %d\\n",
        summary.requests * 1e6 / summary.duration,
        latency.mean, latency:percentile(50), latency:percentile(99),
        errors.connect + errors.read + errors.write + errors.status + errors.timeout))
end
''')
    rows = []
    fields = ["languages", "repeat", "case", "requests_per_second", "mean_us",
              "p50_us", "p99_us", "errors"]
    with (args.output / "http.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        for repeat in range(1, args.http_repeats + 1):
            for count in rng.sample(COUNTS, len(COUNTS)):
                with socket.socket() as listener:
                    listener.bind(("127.0.0.1", 0))
                    port = listener.getsockname()[1]
                extra = f'''server {{
                    listen 127.0.0.1:{port};
                    location = /language {{ return 200 "$bench_language\\n"; }}
                    location = /constant {{ return 200 "x-000\\n"; }}
                }}'''
                (directory / "nginx.conf").write_text(configuration(count, extra))
                command = pinned([str(args.nginx), "-p", str(directory) + "/",
                                  "-c", "nginx.conf", "-e", "stderr"], args.server_cpu)
                with (directory / "nginx.log").open("w+") as log:
                    process = subprocess.Popen(command, stdout=log, stderr=log)
                    try:
                        deadline = time.monotonic() + 5
                        while True:
                            try:
                                with socket.create_connection(("127.0.0.1", port), 0.1):
                                    break
                            except OSError:
                                if process.poll() is not None or time.monotonic() > deadline:
                                    log.seek(0)
                                    raise RuntimeError("nginx failed to start: " + log.read())
                                time.sleep(0.05)

                        common = [str(args.wrk), "-t1", f"-c{args.connections}",
                                  "--timeout", "2s", "-s", str(script)]
                        workloads = {name: ("language", *cases(count)[name])
                                     for name in ("first_match", "last_match", "no_match")}
                        workloads["constant"] = ("constant", "x-000", "x-000")
                        # Check all response bodies before timed requests.
                        for path, header, expected in workloads.values():
                            connection = http.client.HTTPConnection("127.0.0.1", port,
                                                                    timeout=5)
                            try:
                                connection.request("GET", f"/{path}",
                                                   headers={"Accept-Language": header})
                                response = connection.getresponse()
                                if response.status != 200 or response.read() != (expected + "\n").encode():
                                    raise RuntimeError("Unexpected HTTP benchmark response")
                            finally:
                                connection.close()

                        execute(pinned(common + ["-d1s", "-H", "Accept-Language: x-000",
                                                 f"http://127.0.0.1:{port}/language"],
                                       args.client_cpu))
                        for name in rng.sample(list(workloads), len(workloads)):
                            path, header, _ = workloads[name]
                            output = execute(pinned(common + [f"-d{args.duration}s", "-H",
                                f"Accept-Language: {header}", f"http://127.0.0.1:{port}/{path}"],
                                args.client_cpu))
                            samples = [line.split()[1:] for line in output.splitlines()
                                       if line.startswith("BENCH ")]
                            if len(samples) != 1 or int(samples[0][-1]) != 0:
                                raise RuntimeError(f"wrk reported errors: {output}")
                            row = dict(zip(fields, [count, repeat, name, *samples[0]]))
                            rows.append(row)
                            writer.writerow(row)
                            stream.flush()
                        print(f"http: repeat {repeat}, {count} languages", flush=True)
                    finally:
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=5)
    summarize(args.output / "http-summary.csv", rows, "requests_per_second")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nginx", type=Path, required=True,
                        help="nginx built with this module and the bench companion")
    parser.add_argument("--wrk", type=Path, help="also measure HTTP throughput")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--server-cpu", type=int)
    parser.add_argument("--client-cpu", type=int)
    parser.add_argument("--iterations", type=int, default=5000000)
    parser.add_argument("--handler-repeats", type=int, default=7)
    parser.add_argument("--http-repeats", type=int, default=5)
    parser.add_argument("--duration", type=int, default=3)
    parser.add_argument("--connections", type=int, default=32)
    args = parser.parse_args()
    for field in ("iterations", "handler_repeats", "http_repeats", "duration", "connections"):
        if getattr(args, field) <= 0:
            parser.error(f"--{field.replace('_', '-')} must be positive")
    args.nginx = args.nginx.resolve()
    if args.wrk:
        args.wrk = args.wrk.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    root = Path(__file__).resolve().parent.parent
    metadata = {
        "arguments": {name: str(value) if isinstance(value, Path) else value
                      for name, value in vars(args).items()},
        "utc_started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "platform": platform.platform(),
        "cpu": next(line.split(":", 1)[1].strip() for line in
                    Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name")),
        "affinity_available": sorted(os.sched_getaffinity(0)),
        "source_sha256": hashlib.sha256((root / "ngx_http_accept_language_module.c").read_bytes()).hexdigest(),
        "nginx_version": subprocess.run([str(args.nginx), "-V"], capture_output=True,
                                        text=True, check=True).stderr,
        "random_seed": 20261002,
        "cases": {count: cases(count) for count in COUNTS},
    }
    if args.wrk:
        version = subprocess.run([str(args.wrk), "--version"], capture_output=True,
                                 text=True, timeout=10)
        metadata["wrk_version"] = next(
            line for line in (version.stdout + version.stderr).splitlines()
            if line.startswith("wrk "))
    (args.output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    rng = random.Random(metadata["random_seed"])
    with tempfile.TemporaryDirectory(prefix="accept-language-benchmark-") as temporary:
        handler_benchmark(args, Path(temporary), rng)
        if args.wrk:
            http_benchmark(args, Path(temporary), rng)


if __name__ == "__main__":
    main()
