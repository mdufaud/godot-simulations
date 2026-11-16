"""Void-and-cluster blue noise (Ulichney 1993), 64x64 torus, 8-bit PNG. numpy only: python3 -I tools/gen_blue_noise.py out.png"""
import sys
import struct
import zlib
import numpy as np

N = 64
SIGMA = 1.5
rng = np.random.default_rng(1993)

ax = np.minimum(np.arange(N), N - np.arange(N)).astype(np.float64)
kernel = np.exp(-(ax[:, None] ** 2 + ax[None, :] ** 2) / (2.0 * SIGMA * SIGMA))


def splat(energy, idx, sign):
    y, x = divmod(idx, N)
    energy += sign * np.roll(kernel, (y, x), (0, 1))


def energy_of(mask):
    e = np.zeros((N, N))
    for idx in np.flatnonzero(mask.ravel()):
        splat(e, idx, 1.0)
    return e


def tightest(e, mask):
    return int(np.argmax(np.where(mask, e, -np.inf)))


def largest_void(e, mask):
    return int(np.argmin(np.where(mask, np.inf, e)))


mask = np.zeros((N, N), dtype=bool)
mask.ravel()[rng.choice(N * N, N * N // 10, replace=False)] = True
energy = energy_of(mask)
while True:
    t = tightest(energy, mask)
    mask.ravel()[t] = False
    splat(energy, t, -1.0)
    v = largest_void(energy, mask)
    mask.ravel()[v] = True
    splat(energy, v, 1.0)
    if v == t:
        break

rank = np.zeros(N * N, dtype=np.int64)
ones = int(mask.sum())
work = mask.copy()
e = energy_of(work)
for r in range(ones - 1, -1, -1):
    t = tightest(e, work)
    rank[t] = r
    work.ravel()[t] = False
    splat(e, t, -1.0)
work = mask.copy()
e = energy_of(work)
for r in range(ones, N * N):
    v = largest_void(e, work)
    rank[v] = r
    work.ravel()[v] = True
    splat(e, v, 1.0)

img = (rank.reshape(N, N) * 256 // (N * N)).astype(np.uint8)
raw = b"".join(b"\x00" + img[y].tobytes() for y in range(N))


def chunk(tag, data):
    c = struct.pack(">I", len(data)) + tag + data
    return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", N, N, 8, 0, 0, 0, 0)) \
    + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
with open(sys.argv[1], "wb") as f:
    f.write(png)
print("ranks unique:", len(set(rank.tolist())), "mean", img.mean())
