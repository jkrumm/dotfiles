"""Bind-mount speed: one sequential write+read and one small-file test, printed as JSON.
Run inside a container with the directory to test mounted at /work (docs/kiri-trial.md)."""
import json, os, time

d = "/work/bench"
os.makedirs(d, exist_ok=True)
chunk = b"\x5a" * (1 << 20)
n = 512
t = time.perf_counter()
with open(f"{d}/big", "wb") as f:
    for _ in range(n):
        f.write(chunk)
    f.flush()
    os.fsync(f.fileno())
w = n / (time.perf_counter() - t)
t = time.perf_counter()
with open(f"{d}/big", "rb") as f:
    while f.read(1 << 20):
        pass
r = n / (time.perf_counter() - t)
os.remove(f"{d}/big")
os.makedirs(f"{d}/small", exist_ok=True)
k = 2000
t = time.perf_counter()
for i in range(k):
    with open(f"{d}/small/f{i}", "wb") as f:
        f.write(b"x" * 4096)
c = k / (time.perf_counter() - t)
t = time.perf_counter()
for i in range(k):
    with open(f"{d}/small/f{i}", "rb") as f:
        f.read()
sr = k / (time.perf_counter() - t)
for i in range(k):
    os.remove(f"{d}/small/f{i}")
os.rmdir(f"{d}/small")
os.rmdir(d)
print(json.dumps({"seq_write_MiBps": round(w), "seq_read_MiBps": round(r), "small_create_per_s": round(c), "small_read_per_s": round(sr)}))
