#!/usr/bin/env python3
"""Writes the AVI fixtures ffmpeg can't: run by make_avi_fixtures.sh after
the ffmpeg files exist, since it reuses their streams.

camera-mjpeg.avi
    What a camera or webcam records: 4:2:2 Motion JPEG frames with no
    Huffman tables (decoders use the standard ones) under an AVI1 marker,
    unsigned 8-bit PCM, and an idx1 whose offsets are absolute file
    positions rather than relative to the movie list. Flash on frame 30,
    click at 1.000 s.

opendml-cbr.avi
    An OpenDML file: indx super indexes pointing at ix## standard indexes,
    no idx1, the movie data split across a RIFF AVI and a RIFF AVIX. Its
    video is xvid-mp3.avi's, keyframe flags and dropped frame included. Its
    audio is constant-bitrate: xvid-mp3.avi's MP3 frames, mjpeg-ima.avi's
    IMA ADPCM blocks and xvid-ac3.avi's AC-3 frames, each cut into chunks
    that ignore packet boundaries.

opendml-vbr.avi
    The same four streams in an ordinary single-RIFF file with idx1, one
    packet per chunk. Both files must decode to the same samples, which
    proves the constant-bitrate streams were re-cut on the right bytes and
    timed the same way.

mp3-packed.avi
    xvid-mp3.avi's MP3 frames as variable-bitrate audio, but two frames to
    a chunk, as some muxers store it. It must decode like opendml-vbr.avi's
    MP3 track.

aac-adts.avi
    h264-aac.avi's AAC packets, each behind an ADTS header and with no
    decoder configuration in the stream format, as some muxers store AAC.
    It must decode like h264-aac.avi's audio.
"""
import io
import math
import struct
import sys
from pathlib import Path

from PIL import Image


def read_avi(path):
    """Header chunks and idx1-ordered (chunk id, data, keyframe) of an ffmpeg AVI."""
    data = Path(path).read_bytes()
    movi = data.find(b"movi")
    idx1 = data.find(b"idx1")
    count = struct.unpack_from("<I", data, idx1 + 4)[0] // 16
    chunks = []
    for i in range(count):
        cid, flags, offset, size = struct.unpack_from("<4sIII", data, idx1 + 8 + 16 * i)
        start = movi + offset + 8
        chunks.append((cid, data[start:start + size], bool(flags & 0x10)))

    def first(fourcc, after):
        at = data.find(fourcc, after)
        size = struct.unpack_from("<I", data, at + 4)[0]
        return at, data[at + 8:at + 8 + size]

    streams = []
    at = 0
    while True:
        at = data.find(b"strh", at + 1)
        if at < 0 or at > movi:
            break
        strh = data[at + 8:at + 8 + 56]
        _, strf = first(b"strf", at)
        streams.append((strh, strf))
    return streams, chunks


class RIFF:
    """A file written front to back; lists are closed by patching sizes."""

    def __init__(self):
        self.b = bytearray()

    def pos(self):
        return len(self.b)

    def open(self, fourcc, kind):
        start = self.pos()
        self.b += fourcc + b"\0\0\0\0" + kind
        return start

    def close(self, start):
        struct.pack_into("<I", self.b, start + 4, self.pos() - start - 8)
        if self.pos() & 1:
            self.b += b"\0"

    def chunk(self, fourcc, payload):
        start = self.pos()
        self.b += fourcc + struct.pack("<I", len(payload)) + payload
        if len(payload) & 1:
            self.b += b"\0"
        return start


def avih(frames, streams, width, height, us_per_frame=33333, flags=0x110):
    return struct.pack("<10I4I", us_per_frame, 0, 0, flags, frames, 0, streams, 0, width, height, 0, 0, 0, 0)


def strh(kind, handler, scale, rate, length, sample_size, width=0, height=0):
    return struct.pack("<4s4sIHHIIIIIIII4h", kind, handler, 0, 0, 0, 0, scale, rate, 0, length, 0,
                       0xFFFFFFFF, sample_size, 0, 0, width, height)


def bitmap_info(width, height, compression, bit_count=24):
    return struct.pack("<IiiHH4sIiiII", 40, width, height, 1, bit_count, compression,
                       width * height * 3, 0, 0, 0, 0)


def wave_format(tag, channels, rate, bytes_per_second, block_align, bits, extra=b""):
    return struct.pack("<HHIIHHH", tag, channels, rate, bytes_per_second, block_align, bits, len(extra)) + extra


# MARK: camera-mjpeg.avi

def camera_jpeg(white):
    """A 4:2:2 baseline JPEG with its DHT segments removed and JFIF's APP0
    replaced by the AVI1 marker cameras write."""
    image = Image.new("RGB", (160, 120), (255, 255, 255) if white else (0, 0, 0))
    out = io.BytesIO()
    image.save(out, "JPEG", quality=80, subsampling=1)  # 1 = 4:2:2
    jpeg = out.getvalue()
    result = bytearray(jpeg[:2])
    at = 2
    while at < len(jpeg):
        marker = jpeg[at + 1]
        if marker == 0xDA:  # start of scan: the rest is entropy-coded data
            result += jpeg[at:]
            break
        length = struct.unpack_from(">H", jpeg, at + 2)[0]
        segment = jpeg[at:at + 2 + length]
        if marker == 0xE0:
            segment = b"\xff\xe0" + struct.pack(">H", 16) + b"AVI1" + b"\0" * 10
        if marker != 0xC4:
            result += segment
        at += 2 + length
    assert b"\xff\xc4" not in bytes(result[:result.find(b"\xff\xda")])
    return bytes(result)


def camera_mjpeg(out):
    frames = [camera_jpeg(n == 30) for n in range(45)]
    rate = 11025
    pcm = bytearray()
    for n in range(int(1.5 * rate)):
        t = n / rate
        value = 0.9 * math.sin(2 * math.pi * 1000 * t) if 1 <= t <= 1.004 else 0
        pcm.append(max(0, min(255, round(128 + 127 * value))))
    per_frame = len(pcm) / len(frames)

    f = RIFF()
    riff = f.open(b"RIFF", b"AVI ")
    hdrl = f.open(b"LIST", b"hdrl")
    f.chunk(b"avih", avih(len(frames), 2, 160, 120))
    strl = f.open(b"LIST", b"strl")
    f.chunk(b"strh", strh(b"vids", b"MJPG", 1, 30, len(frames), 0, 160, 120))
    f.chunk(b"strf", bitmap_info(160, 120, b"MJPG"))
    f.close(strl)
    strl = f.open(b"LIST", b"strl")
    f.chunk(b"strh", strh(b"auds", b"\0\0\0\0", 1, rate, len(pcm), 1))
    f.chunk(b"strf", wave_format(1, 1, rate, rate, 1, 8))
    f.close(strl)
    f.close(hdrl)

    index = []
    movi = f.open(b"LIST", b"movi")
    for n, frame in enumerate(frames):
        index.append((b"00dc", 0x10, f.chunk(b"00dc", frame), len(frame)))
        audio = bytes(pcm[round(n * per_frame):round((n + 1) * per_frame)])
        index.append((b"01wb", 0x10, f.chunk(b"01wb", audio), len(audio)))
    f.close(movi)
    # Absolute offsets of each chunk header, as some camera firmware writes.
    f.chunk(b"idx1", b"".join(struct.pack("<4sIII", *entry) for entry in index))
    f.close(riff)
    Path(out, "camera-mjpeg.avi").write_bytes(f.b)


# MARK: opendml-cbr.avi and opendml-vbr.avi

def opendml_pair(out):
    xvid_streams, xvid_chunks = read_avi(Path(out, "xvid-mp3.avi"))
    ima_streams, ima_chunks = read_avi(Path(out, "mjpeg-ima.avi"))
    ac3_streams, ac3_chunks = read_avi(Path(out, "xvid-ac3.avi"))
    video_strh, video_strf = xvid_streams[0]
    _, mp3_strf = xvid_streams[1]
    _, ima_strf = ima_streams[1]
    _, ac3_strf = ac3_streams[1]
    video = [(data, key) for cid, data, key in xvid_chunks if cid == b"00dc"]
    mp3_frames = [data for cid, data, _ in xvid_chunks if cid == b"01wb"]
    ima_blocks = [data for cid, data, _ in ima_chunks if cid == b"01wb"]
    ac3_frames = [data for cid, data, _ in ac3_chunks if cid == b"01wb"]
    mp3_rate = struct.unpack_from("<I", mp3_strf, 4)[0]
    ima_block_align = struct.unpack_from("<H", ima_strf, 12)[0]
    ima_samples = struct.unpack_from("<H", ima_strf, 18)[0]
    assert all(len(b) == ima_block_align for b in ima_blocks)

    # Every packet as (seconds, stream, payload) in each layout.
    def timeline(cbr):
        items = [(n / 30, 0, data, key) for n, (data, key) in enumerate(video)]
        if cbr:
            mp3 = b"".join(mp3_frames)
            byte_rate = 8000  # 64 kbit/s
            items += [(at / byte_rate, 1, mp3[at:at + 500], True) for at in range(0, len(mp3), 500)]
            ima = b"".join(ima_blocks)
            items += [(at / ima_block_align * ima_samples / 11025, 2, ima[at:at + 700], True)
                      for at in range(0, len(ima), 700)]
            ac3 = b"".join(ac3_frames)
            items += [(at / 12000, 3, ac3[at:at + 600], True) for at in range(0, len(ac3), 600)]  # 96 kbit/s
        else:
            items += [(n * 1152 / mp3_rate, 1, data, True) for n, data in enumerate(mp3_frames)]
            items += [(n * ima_samples / 11025, 2, data, True) for n, data in enumerate(ima_blocks)]
            items += [(n * 1536 / 48000, 3, data, True) for n, data in enumerate(ac3_frames)]
        return sorted(items, key=lambda item: (item[0], item[1]))

    def headers(f, cbr, super_entries):
        """Writes hdrl; returns where each stream's indx entries start."""
        hdrl = f.open(b"LIST", b"hdrl")
        f.chunk(b"avih", avih(len(video), 4, 160, 120))
        mp3_len = sum(map(len, mp3_frames))
        ima_len = sum(map(len, ima_blocks))
        ac3_len = sum(map(len, ac3_frames))
        specs = [
            (video_strh, video_strf),
            (strh(b"auds", b"\0\0\0\0", 1, 8000, mp3_len, 1) if cbr
             else strh(b"auds", b"\0\0\0\0", 1152, mp3_rate, len(mp3_frames), 0), mp3_strf),
            (strh(b"auds", b"\0\0\0\0", ima_samples, 11025, ima_len // ima_block_align, ima_block_align), ima_strf),
            (strh(b"auds", b"\0\0\0\0", 1, 12000, ac3_len, 1) if cbr
             else strh(b"auds", b"\0\0\0\0", 1536, 48000, len(ac3_frames), 0), ac3_strf),
        ]
        slots = []
        for number, (header, fmt) in enumerate(specs):
            strl = f.open(b"LIST", b"strl")
            f.chunk(b"strh", header)
            f.chunk(b"strf", fmt)
            if super_entries:
                chunk_id = b"%02d" % number + (b"dc" if number == 0 else b"wb")
                body = struct.pack("<HBBI4s3I", 4, 0, 0, super_entries, chunk_id, 0, 0, 0)
                at = f.chunk(b"indx", body + b"\0" * 16 * super_entries)
                slots.append(at + 8 + 24)
            f.close(strl)
        if super_entries:
            odml = f.open(b"LIST", b"odml")
            f.chunk(b"dmlh", struct.pack("<I", len(video)) + b"\0" * 244)
            f.close(odml)
        f.close(hdrl)
        return slots

    # opendml-cbr.avi: two RIFFs, standard indexes after each movie list.
    items = timeline(cbr=True)
    halves = [items[:len(items) // 2], items[len(items) // 2:]]
    f = RIFF()
    slots = None
    super_index = [[] for _ in range(4)]
    for part, packets in enumerate(halves):
        riff = f.open(b"RIFF", b"AVI " if part == 0 else b"AVIX")
        if part == 0:
            slots = headers(f, cbr=True, super_entries=2)
        movi = f.open(b"LIST", b"movi")
        placed = [[] for _ in range(4)]
        for _, stream, payload, key in packets:
            chunk_id = b"%02d" % stream + (b"dc" if stream == 0 else b"wb")
            placed[stream].append((f.chunk(chunk_id, payload) + 8, len(payload), key))
        f.close(movi)
        for stream in range(4):
            base = placed[stream][0][0] - 8
            chunk_id = b"%02d" % stream + (b"dc" if stream == 0 else b"wb")
            body = struct.pack("<HBBI4sQI", 2, 0, 1, len(placed[stream]), chunk_id, base, 0)
            for offset, size, key in placed[stream]:
                body += struct.pack("<II", offset - base, size | (0 if key else 0x80000000))
            at = f.chunk(b"ix%02d" % stream, body)
            super_index[stream].append((at, len(body) + 8))
        f.close(riff)
    for stream in range(4):
        for k, (at, size) in enumerate(super_index[stream]):
            struct.pack_into("<QII", f.b, slots[stream] + 16 * k, at, size, 0)
    Path(out, "opendml-cbr.avi").write_bytes(f.b)

    # opendml-vbr.avi: one RIFF, idx1 relative to the movie list.
    f = RIFF()
    riff = f.open(b"RIFF", b"AVI ")
    headers(f, cbr=False, super_entries=0)
    movi = f.open(b"LIST", b"movi")
    index = []
    for _, stream, payload, key in timeline(cbr=False):
        chunk_id = b"%02d" % stream + (b"dc" if stream == 0 else b"wb")
        index.append((chunk_id, 0x10 if key else 0, f.chunk(chunk_id, payload) - (movi + 8), len(payload)))
    f.close(movi)
    f.chunk(b"idx1", b"".join(struct.pack("<4sIII", *entry) for entry in index))
    f.close(riff)
    Path(out, "opendml-vbr.avi").write_bytes(f.b)


# MARK: mp3-packed.avi and aac-adts.avi

def audio_only(out, name, header, fmt, chunks):
    """An audio-only AVI, one chunk per payload, with idx1."""
    f = RIFF()
    riff = f.open(b"RIFF", b"AVI ")
    hdrl = f.open(b"LIST", b"hdrl")
    f.chunk(b"avih", avih(0, 1, 0, 0))
    strl = f.open(b"LIST", b"strl")
    f.chunk(b"strh", header)
    f.chunk(b"strf", fmt)
    f.close(strl)
    f.close(hdrl)
    movi = f.open(b"LIST", b"movi")
    index = [(b"00wb", 0x10, f.chunk(b"00wb", payload) - (movi + 8), len(payload)) for payload in chunks]
    f.close(movi)
    f.chunk(b"idx1", b"".join(struct.pack("<4sIII", *entry) for entry in index))
    f.close(riff)
    Path(out, name).write_bytes(f.b)


def packed_and_adts(out):
    xvid_streams, xvid_chunks = read_avi(Path(out, "xvid-mp3.avi"))
    _, mp3_strf = xvid_streams[1]
    mp3_rate = struct.unpack_from("<I", mp3_strf, 4)[0]
    mp3_frames = [data for cid, data, _ in xvid_chunks if cid == b"01wb"]
    pairs = [b"".join(mp3_frames[n:n + 2]) for n in range(0, len(mp3_frames), 2)]
    audio_only(out, "mp3-packed.avi", strh(b"auds", b"\0\0\0\0", 1152, mp3_rate, len(pairs), 0), mp3_strf, pairs)

    aac_streams, aac_chunks = read_avi(Path(out, "h264-aac.avi"))
    aac_strh, aac_strf = aac_streams[1]
    config = aac_strf[18:]
    object_type = config[0] >> 3
    rate_index = (config[0] & 0x07) << 1 | config[1] >> 7
    channels = config[1] >> 3 & 0x0F

    def adts(packet):
        length = len(packet) + 7
        return bytes([
            0xFF, 0xF1,  # sync, MPEG-4, layer 0, no CRC
            (object_type - 1) << 6 | rate_index << 2 | channels >> 2,
            (channels & 3) << 6 | length >> 11,
            length >> 3 & 0xFF,
            (length & 7) << 5 | 0x1F,
            0xFC,  # buffer fullness 0x7FF, one raw data block
        ]) + packet

    packets = [adts(data) for cid, data, _ in aac_chunks if cid == b"01wb"]
    bare = aac_strf[:16] + struct.pack("<H", 0)
    audio_only(out, "aac-adts.avi", aac_strh, bare, packets)


if __name__ == "__main__":
    target = sys.argv[1]
    camera_mjpeg(target)
    opendml_pair(target)
    packed_and_adts(target)
