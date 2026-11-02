#!/usr/bin/env python3
"""Regenerate the synthetic 400MP test PNG with constant-size row buffers.

1-bit grayscale, all black. No real photo data; no full decoded image allocated.
"""
import struct
import zlib
from pathlib import Path

output = Path(__file__).resolve().parents[1] / 'VerificationSupport/Resources/oversized-20000.png'

def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))

with output.open('wb') as file:
    file.write(b'\x89PNG\r\n\x1a\n')
    file.write(chunk(b'IHDR', struct.pack('>IIBBBBB', 20000, 20000, 1, 0, 0, 0, 0)))
    compressor = zlib.compressobj(level=9)
    row = bytes(1 + 20000 // 8)  # filter byte + packed 1-bit pixels
    for _ in range(20000):
        compressed = compressor.compress(row)
        if compressed:
            file.write(chunk(b'IDAT', compressed))
    file.write(chunk(b'IDAT', compressor.flush()))
    file.write(chunk(b'IEND', b''))
print(f'{output.name}: {output.stat().st_size} bytes, 20000 x 20000 pixels')
