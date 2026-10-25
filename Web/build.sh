#!/bin/zsh
# Builds the web player's two WebAssembly modules into Web/generated. The rest of this folder is the
# site as it is served: nothing else is generated, bundled or installed.
#
#   ./build.sh          then serve this folder, for instance:  python3 -m http.server --directory Web 8000
set -e
cd ${0:h}
# This folder is a package of its own (Package.swift), built on SidayPlayer in the one above it.
package=$PWD

# Embedded Swift for both: small modules, and no Swift runtime to download.
sdk=${SIDAY_WASM_SDK:-$(swift sdk list | grep '_wasm-embedded$' | tail -1)}
[ -n "$sdk" ] || { echo "No Embedded Swift SDK for WebAssembly is installed (see: swift sdk list)." >&2; exit 1 }
common=(--package-path $package --swift-sdk $sdk --toolset $PWD/toolset.json)

mkdir -p generated

# Both are built by JavaScriptKit's packaging command, the page first. It builds with settings of its
# own, and a build goes on from the one before it only if that was made with the same settings and
# for as much: a module built with `swift build` would be made again, and so would the page after
# the audio half, which needs less than the page does, but not the audio half after the page.
output=$package/.build/plugins/PackageToJS/outputs

# The page. The packaging command writes the module and the JavaScript that connects it to the browser;
# siday.js loads them. It puts the module through wasm-opt too, if it is there, which nearly halves it.
optimise=()
command -v wasm-opt > /dev/null || optimise=(--no-optimize)
swift package $common js --configuration release --product SidayWeb --output $output/siday-web $optimise
cp $output/siday-web/SidayWeb.wasm $output/siday-web/instantiate.js $output/siday-web/runtime.js $output/siday-web/bridge-js.js generated/

# The audio half: SidayPlayer alone, for the audio worklet, which needs none of the JavaScript.
# With wasm-opt (from Binaryen) installed, the module goes through it and comes out a tenth smaller.
# It renders no faster for it, and the sound is the same to the sample; without it, it is used as built.
swift package $common js --configuration release --product SidayWebAudio --output $output/siday-web-audio --no-optimize
built=$output/siday-web-audio/SidayWebAudio.wasm
if command -v wasm-opt > /dev/null; then
  wasm-opt -Os --strip-debug --strip-producers $built -o generated/SidayWebAudio.wasm
else
  cp $built generated/
fi
# And FORMATS.md, of which the page shows the part on a format when the format's name is pressed.
cp ../FORMATS.md generated/

# And the pictures of the chips, drawn as the app draws them (see Scripts/chip-pictures.swift).
drawer=$package/.build/chip-pictures
mkdir -p $package/.build
swiftc -O -parse-as-library ../Sources/SidayFoundation/TuneFormat.swift ../Sources/SidayFoundation/SoundChip.swift \
  ../App/Siday/Views/ChipCard.swift ../Scripts/chip-pictures.swift -o $drawer
rm -rf generated/chips
$drawer generated/chips

ls -l generated | awk 'NR > 1 { printf "%9d  generated/%s\n", $5, $NF }'
