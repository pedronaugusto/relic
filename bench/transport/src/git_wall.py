"""Wall cost of the existing Git comparison, including process start."""
import os
import subprocess
import sys
import time

_smoke_ticks = 0
def benchmark_clock_ns():
    global _smoke_ticks
    if os.environ.get("BENCH_SMOKE") == "1":
        _smoke_ticks += 1
        return _smoke_ticks
    return time.perf_counter_ns()
def benchmark_clock():
    if os.environ.get("BENCH_SMOKE") == "1":
        return benchmark_clock_ns() / 1e9
    return time.perf_counter()

start=benchmark_clock()
subprocess.run(sys.argv[1:],check=True,stdout=subprocess.DEVNULL)
if os.environ.get('BENCH_SMOKE')!='1':print(f'{(benchmark_clock()-start)*1000:.3f}')
