#!/bin/zsh
# Builds SidayKit as Embedded Swift, with a small program that renders a tune to a file:
#   build/sidayemb    for this Mac
#   build/siday.wasm  for WebAssembly (WASI)
# An experiment: see README.md beside this script.
set -e
cd ${0:h}

TOOLCHAIN=${TOOLCHAIN:-$(swiftly use --print-location)/usr}
# Only the C library, start-up object and compiler builtins are taken from the WebAssembly SDK.
VERSION=${TOOLCHAIN:h:t:r}
SDK=${WASM_SDK:-$HOME/Library/org.swift.swiftpm/swift-sdks/${VERSION}_wasm.artifactbundle/${VERSION}_wasm/wasm32-unknown-wasip1}
FLAGS=(-enable-experimental-feature Embedded -enable-experimental-feature Extern -wmo -O -parse-as-library)
SOURCES=(../Sources/SidayKit/**/*.swift Files.swift)
mkdir -p build

swiftc $FLAGS $SOURCES main-macos.swift -module-name siday -o build/sidayemb \
  -Xlinker $TOOLCHAIN/lib/swift/embedded/arm64-apple-macos/libswiftUnicodeDataTables.a
echo "build/sidayemb    $(stat -f %z build/sidayemb) bytes"

swiftc -target wasm32-unknown-none-wasm $FLAGS -Xfrontend -disable-stack-protector -c \
  $SOURCES main-wasi.swift -module-name siday -o build/siday.o
$TOOLCHAIN/bin/wasm-ld $SDK/WASI.sdk/lib/wasm32-wasip1/crt1-command.o build/siday.o \
  $SDK/WASI.sdk/lib/wasm32-wasip1/libc.a \
  $SDK/swift.xctoolchain/usr/lib/clang/lib/wasip1/libclang_rt.builtins-wasm32.a \
  $TOOLCHAIN/lib/swift/embedded/wasm32-unknown-none-wasm/libswiftUnicodeDataTables.a \
  -o build/siday.wasm --stack-first -z stack-size=4194304
rm build/siday.o
echo "build/siday.wasm  $(stat -f %z build/siday.wasm) bytes"
