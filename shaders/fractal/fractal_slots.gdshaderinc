// Which pixel of a stride x stride cell the sample pass covers this frame.
// Every cell walks the Bayer order of its cell (consecutive refreshes land far
// apart), from a per-cell hashed starting point: with a shared phase, pixels of
// the same refresh age would line up into a regular grid, and the small
// resampling drift of older pixels would show as stride-periodic stripes.
ivec2 fractal_slot_offset(ivec2 cell, int stride, int phase) {
	int count = stride * stride;
	uint h = uint(cell.x) * 73856093u ^ uint(cell.y) * 19349663u;
	h ^= h >> 13u;
	h *= 0x5bd1e995u;
	h ^= h >> 15u;
	int rank = (phase + int(h & uint(count - 1))) & (count - 1);
	int bits = findMSB(stride);
	ivec2 offset = ivec2(0);
	for (int b = 0; b < 3; b++) {
		if (b >= bits) break;
		int pair = (rank >> (2 * (bits - 1 - b))) & 3;
		int yb = pair & 1;
		int xb = (pair >> 1) ^ yb;
		offset |= ivec2(xb << b, yb << b);
	}
	return offset;
}
