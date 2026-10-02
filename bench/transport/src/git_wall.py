"""Wall cost of the existing Git comparison, including process start."""
import os
import subprocess
import sys
import time
start=time.perf_counter()
subprocess.run(sys.argv[1:],check=True,stdout=subprocess.DEVNULL)
if os.environ.get('BENCH_SMOKE')!='1':print(f'{(time.perf_counter()-start)*1000:.3f}')
