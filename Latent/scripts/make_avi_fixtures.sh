#!/bin/sh
# Regenerates VerificationSupport/Resources/AVI. Needs an ffmpeg built with
# libx264 and libmp3lame, and python3 with Pillow for the files ffmpeg
# can't write (make_avi_synthetic.py).
#
# The sync files flash white on video frame 30 (exactly 1.000 s at 30 fps)
# and click at exactly 1.000 s in the audio, like the Matroska fixtures.
# AVI has no timestamps, so where each one lands is a convention: the
# verification holds Latent to ffmpeg's reading of these exact files, so
# regenerate them with stock ffmpeg encoders and re-measure with
# `ffmpeg -vf signalstats` and `-af silencedetect` if the encoders change.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/../VerificationSupport/Resources/AVI}"
mkdir -p "$out"
ff="ffmpeg -hide_banner -loglevel error -y"

flash='color=black:s=160x120:r=30:d=1.5,drawbox=x=0:y=0:w=160:h=120:color=white:t=fill:enable=eq(n\,30)'
click() { echo "aevalsrc=if(between(t\,1\,1.004)\,0.9*sin(2*PI*1000*t)\,0):s=$1:d=1.5"; }
xvid='-c:v mpeg4 -vtag XVID -bf 0 -q:v 5'

# MPEG-4 Simple Profile (Xvid without B-frames) with the common AVI audio.
$ff -f lavfi -i "$flash" -f lavfi -i "$(click 44100)" $xvid -c:a libmp3lame -b:a 64k "$out/xvid-mp3.avi"
$ff -f lavfi -i "$flash" -f lavfi -i "$(click 48000)" $xvid -c:a ac3 -b:a 96k "$out/xvid-ac3.avi"
$ff -f lavfi -i "$flash" -f lavfi -i "$(click 48000)" $xvid -c:a mp2 -b:a 64k "$out/xvid-mp2.avi"

# H.264 in AVI is an Annex B stream in decode order: B-frames exercise the
# picture-order recovery, baseline the plain path.
$ff -f lavfi -i "$flash" -f lavfi -i "$(click 48000)" -c:v libx264 -bf 3 -g 15 -pix_fmt yuv420p \
    -c:a libmp3lame -b:a 64k "$out/h264-mp3.avi"
$ff -f lavfi -i "$flash" -f lavfi -i "$(click 48000)" -c:v libx264 -profile:v baseline -g 15 -pix_fmt yuv420p \
    -c:a aac -b:a 48k "$out/h264-aac.avi"

# Motion JPEG with IMA ADPCM, whose chunks hold whole blocks.
$ff -f lavfi -i "$flash" -f lavfi -i "$(click 11025)" -c:v mjpeg -q:v 6 -pix_fmt yuvj420p \
    -c:a adpcm_ima_wav "$out/mjpeg-ima.avi"

# One 16:9 DV frame (a DV frame is 120 kB whatever it shows).
$ff -f lavfi -i 'testsrc=s=720x480:r=30000/1001' -f lavfi -i "$(click 48000)" -frames:v 1 -t 0.0334 \
    -aspect 16:9 -c:v dvvideo -pix_fmt yuv411p -c:a pcm_s16le "$out/dv-pcm.avi"

# Audio-only files in the Windows codecs AVI carries.
$ff -f lavfi -i "$(click 8000)" -c:a adpcm_ms "$out/ms-adpcm.avi"
$ff -f lavfi -i "$(click 8000)" -c:a pcm_alaw "$out/alaw.avi"
$ff -f lavfi -i "$(click 8000)" -c:a pcm_mulaw "$out/ulaw.avi"

# Files macOS can't decode, which must say so: Xvid with B-frames (MPEG-4
# Advanced Simple), DivX 3 (Microsoft's pre-standard MPEG-4) and 4:2:2
# Motion JPEG as ffmpeg lays it out (camera 4:2:2 decodes; see
# camera-mjpeg.avi).
short='color=gray:s=160x120:r=30:d=0.5'
$ff -f lavfi -i "$short" -f lavfi -i 'sine=f=440:sample_rate=44100:d=0.5' -c:v mpeg4 -vtag XVID -bf 2 -q:v 5 \
    -c:a libmp3lame -b:a 64k "$out/xvid-bframes.avi"
$ff -f lavfi -i "$short" -f lavfi -i 'sine=f=440:sample_rate=44100:d=0.5' -c:v msmpeg4v3 -vtag DIV3 -q:v 5 \
    -c:a libmp3lame -b:a 64k "$out/divx3.avi"
$ff -f lavfi -i 'color=gray:s=160x120:r=30:d=0.1' -f lavfi -i 'sine=f=440:sample_rate=11025:d=0.1' \
    -c:v mjpeg -q:v 6 -pix_fmt yuvj422p -c:a pcm_u8 "$out/mjpeg-422.avi"

python3 "$here/make_avi_synthetic.py" "$out"
