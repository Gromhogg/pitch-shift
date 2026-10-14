#!/bin/zsh
# Makes Rubber Band 4.0.0 and libsamplerate 0.2.2 for both Apple silicon and Intel Macs, into build/libs
# (lib/ and include/). Apple silicon uses Homebrew's own Rubber Band library, unchanged (brew install rubberband),
# so the sound stays exactly the same. The rest is built here from the same source with the same options as
# Homebrew's builds. The source is downloaded once into build/libs/download and checked against fixed SHA-256 sums.
# Needs only the Command Line Tools (no Xcode).
set -e
cd "${0:A:h}/.."
out=build/libs
rb=rubberband-4.0.0
sr=libsamplerate-0.2.2
brew_rb=/opt/homebrew/opt/rubberband
brew_sr=/opt/homebrew/opt/libsamplerate
if [[ ! -f $brew_rb/lib/librubberband.a || ${brew_rb:A:t} != 4.0.0 || ${brew_sr:A:t} != 0.2.2 ]]; then
  echo "Needs Rubber Band 4.0.0 and libsamplerate 0.2.2 from Homebrew first: brew install rubberband"
  exit 1
fi
done_file=$out/lib/done-$rb-$sr-2
if [[ -f $done_file ]] && cmp -s $brew_rb/lib/librubberband.a $out/arm64/librubberband.a; then exit 0; fi

# Download (or reuse) a source file and check it.
fetch() {
  local url=$1 sum=$2 file=$out/download/${1:t}
  mkdir -p $out/download
  if [[ -f $file ]] && echo "$sum  $file" | shasum -a 256 -c --status; then return; fi
  echo "Downloading ${url:t}"
  curl -fsSL --retry 3 "$url" -o "$file.part"
  if ! echo "$sum  $file.part" | shasum -a 256 -c --status; then echo "${url:t} doesn't match its checksum"; exit 1; fi
  mv "$file.part" "$file"
}
fetch https://breakfastquay.com/files/releases/$rb.tar.bz2 \
  af050313ee63bc18b35b2e064e5dce05b276aaf6d1aa2b8a82ced1fe2f8028e9
fetch https://github.com/libsndfile/libsamplerate/releases/download/0.2.2/$sr.tar.xz \
  3258da280511d24b49d6b08615bbe824d0cacc9842b0e4caf11c52cf2b043893

rm -rf $out/src $out/arm64 $out/x86_64 $out/lib $out/include
mkdir -p $out/src $out/arm64/sr $out/x86_64/rb $out/x86_64/sr $out/lib $out/include
tar -xjf $out/download/$rb.tar.bz2 -C $out/src
tar -xJf $out/download/$sr.tar.xz -C $out/src
RB=$out/src/$rb
SR=$out/src/$sr

# libsamplerate's settings (what its CMake build finds on a Mac).
mkdir -p $out/src/samplerate-config
cat > $out/src/samplerate-config/config.h <<'EOF'
#define PACKAGE "libsamplerate"
#define VERSION "0.2.2"
#define CPU_CLIPS_NEGATIVE 0
#define CPU_CLIPS_POSITIVE 0
#define CPU_IS_BIG_ENDIAN 0
#define CPU_IS_LITTLE_ENDIAN 1
#define HAVE_STDBOOL_H 1
#define HAVE_UNISTD_H 1
#define HAVE_VISIBILITY 1
#define ENABLE_SINC_FAST_CONVERTER 1
#define ENABLE_SINC_MEDIUM_CONVERTER 1
#define ENABLE_SINC_BEST_CONVERTER 1
#define SIZEOF_INT 4
#define SIZEOF_LONG 8
EOF

# Homebrew's options: Rubber Band's Meson release build (-Dresampler=libsamplerate, vDSP FFT, lowest macOS 10.13
# on Intel) and libsamplerate's CMake release build, both with Homebrew's -Os. Checked on arm64: libsamplerate
# comes out as the same machine code as Homebrew's (only marked for macOS 14.4 instead of 26), and Rubber Band
# nearly the same (small changes from the newer macOS SDK, so Homebrew's own is used there).
rb_files=(rubberband-c RubberBandStretcher RubberBandLiveShifter
  faster/AudioCurveCalculator faster/CompoundAudioCurve faster/HighFrequencyAudioCurve faster/SilentAudioCurve
  faster/PercussiveAudioCurve faster/R2Stretcher faster/StretcherChannelData faster/StretcherProcess
  common/Allocators common/FFT common/Log common/Profiler common/Resampler common/StretchCalculator
  common/sysutils common/mathmisc common/Thread finer/R3Stretcher finer/R3LiveShifter)
sr_files=(samplerate src_linear src_sinc src_zoh)
echo "Building Rubber Band and libsamplerate"
for f in $rb_files; do
  clang++ -arch x86_64 -mmacosx-version-min=10.13 -Os -std=c++11 -include stddef.h -D_FILE_OFFSET_BITS=64 \
    -DHAVE_VDSP -DHAVE_LIBSAMPLERATE -DLACK_SINCOS -DNO_THREAD_CHECKS -DNO_TIMING -DNDEBUG \
    -DUSE_PTHREADS -DMALLOC_IS_ALIGNED -I$RB/rubberband -I$RB/src -I$SR/include \
    -c $RB/src/$f.cpp -o $out/x86_64/rb/${f:t}.o &
done
for arch in arm64 x86_64; do
  for f in $sr_files; do
    clang -arch $arch -mmacosx-version-min=14.4 -Os -DNDEBUG -std=gnu99 -DHAVE_CONFIG_H \
      -I$out/src/samplerate-config -I$SR/include -c $SR/src/$f.c -o $out/$arch/sr/$f.o &
  done
done
wait
for f in $rb_files; do [[ -f $out/x86_64/rb/${f:t}.o ]] || { echo "Rubber Band: $f didn't build"; exit 1 }; done
for f in $sr_files; do
  [[ -f $out/arm64/sr/$f.o && -f $out/x86_64/sr/$f.o ]] || { echo "libsamplerate: $f didn't build"; exit 1 }
done
libtool -static -no_warning_for_no_symbols -o $out/x86_64/librubberband.a $out/x86_64/rb/*.o
libtool -static -o $out/x86_64/libsamplerate.a $out/x86_64/sr/*.o
libtool -static -o $out/arm64/libsamplerate.a $out/arm64/sr/*.o

cp $brew_rb/lib/librubberband.a $out/arm64/
for name in librubberband libsamplerate; do
  lipo -create $out/arm64/$name.a $out/x86_64/$name.a -output $out/lib/$name.a
done
cp -R $RB/rubberband $out/include/
cp $SR/COPYING $out/lib/libsamplerate-COPYING
touch $done_file
echo "Built $out/lib (Apple silicon and Intel)"
