#!/bin/sh
# Regenerates VerificationSupport/Resources/Matroska. Needs an ffmpeg built
# with libx264, libx265, libvpx-vp9, libopus, libmp3lame and libsvtav1.
#
# The sync-* files flash white on video frame 30 (exactly 1.000 s at 30 fps)
# and click at exactly 1.000 s in the audio. Their B-frames, encoder priming
# and codec delays are what the audio-sync verification measures, so
# regenerate them with stock ffmpeg encoders rather than other tools.
set -eu

out="$(cd "$(dirname "$0")/.." && pwd)/VerificationSupport/Resources/Matroska"
mkdir -p "$out"
ff="ffmpeg -hide_banner -loglevel error -y"

flash='color=black:s=320x240:r=30:d=3,drawbox=x=0:y=0:w=320:h=240:color=white:t=fill:enable=eq(n\,30)'
click48='aevalsrc=if(between(t\,1\,1.004)\,0.9*sin(2*PI*1000*t)\,0):s=48000:d=3'
click44='aevalsrc=if(between(t\,1\,1.004)\,0.9*sin(2*PI*1000*t)\,0):s=44100:d=3'
h264='-c:v libx264 -bf 3 -g 15 -pix_fmt yuv420p'

$ff -f lavfi -i "$flash" -f lavfi -i "$click48" $h264 -c:a aac "$out/sync-aac.mkv"
$ff -f lavfi -i "$flash" -f lavfi -i "$click48" $h264 -c:a ac3 "$out/sync-ac3.mkv"
$ff -f lavfi -i "$flash" -f lavfi -i "$click48" $h264 -c:a libopus "$out/sync-opus.mkv"
$ff -f lavfi -i "$flash" -f lavfi -i "$click44" $h264 -c:a libmp3lame "$out/sync-mp3.mkv"
$ff -f lavfi -i "$flash" -f lavfi -i "$click48" $h264 -c:a flac "$out/sync-flac.mkv"
$ff -f lavfi -i "$flash" -f lavfi -i "$click48" -c:v libx265 -x265-params log-level=error \
    -pix_fmt yuv420p -c:a aac "$out/sync-hevc-aac.mkv"

# Apple's VP9 decoder refuses very small frames, so this one stays 320x240.
$ff -f lavfi -i 'color=gray:s=320x240:r=30:d=1,drawbox=x=t*200:y=100:w=40:h=40:color=white:t=fill' \
    -f lavfi -i 'sine=f=440:sample_rate=48000:d=1' -c:v libvpx-vp9 -b:v 40k -c:a libopus -b:a 24k "$out/vp9-opus.mkv"
$ff -f lavfi -i 'testsrc=s=64x64:r=30:d=1' -f lavfi -i 'sine=f=440:sample_rate=48000:d=1' \
    -c:v libsvtav1 -preset 12 -c:a aac -b:a 32k "$out/av1-aac.mkv"
