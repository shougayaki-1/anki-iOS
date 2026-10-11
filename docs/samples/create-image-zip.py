"""Create an offline import sample using only Python's standard library.
Run: python3 docs/samples/create-image-zip.py /tmp/image-sample.zip
The geometric symbols are original demo images, not official map symbols.
"""
import struct
import sys
import zlib
import zipfile


def png(cross):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    rows = bytearray()
    for y in range(80):
        rows.append(0)
        for x in range(80):
            line = (abs(x - 40) <= 1 or abs(y - 40) <= 1) if cross else abs(((x-40)**2 + (y-40)**2)**0.5 - 25) <= 1
            rows.extend((0, 0, 0, 255) if line else (255, 255, 255, 0))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 80, 80, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')


with zipfile.ZipFile(sys.argv[1], 'w', zipfile.ZIP_DEFLATED) as archive:
    archive.writestr('cards.csv', 'question,answer,image,deck,tags\n,円,images/circle.png,教材/図版,図形\n,十字,images/cross.png,教材/図版,図形\n')
    archive.writestr('images/circle.png', png(False))
    archive.writestr('images/cross.png', png(True))
