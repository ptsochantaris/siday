#!/bin/zsh
# Builds the web player's two WebAssembly modules into Web/generated. The rest of this folder is the
# site as it is served: nothing else is generated, bundled or installed.
#
#   ./build.sh          then serve this folder, for instance:  python3 -m http.server --directory Web 8000
set -e
cd ${0:h}
package=${PWD:h}

# Embedded Swift for both: small modules, and no Swift runtime to download.
sdk=${SIDAY_WASM_SDK:-$(swift sdk list | grep '_wasm-embedded$' | tail -1)}
[ -n "$sdk" ] || { echo "No Embedded Swift SDK for WebAssembly is installed (see: swift sdk list)." >&2; exit 1 }
common=(--package-path $package --swift-sdk $sdk --toolset $PWD/toolset.json)

mkdir -p generated

# The audio half: SidayKit alone, for the audio worklet.
swift build $common -c release --product SidayWebAudio
cp "$(swift build $common -c release --product SidayWebAudio --show-bin-path)/SidayWebAudio.wasm" generated/

# The page. JavaScriptKit's packaging command writes the module and the JavaScript that connects it to
# the browser; siday.js loads them. It makes the module smaller still if wasm-opt (from Binaryen) is installed.
output=$package/.build/plugins/PackageToJS/outputs/siday-web
optimise=()
command -v wasm-opt > /dev/null || optimise=(--no-optimize)
swift package $common js --configuration release --product SidayWeb --output $output $optimise
cp $output/SidayWeb.wasm $output/instantiate.js $output/runtime.js $output/bridge-js.js generated/

ls -l generated | awk 'NR > 1 { printf "%9d  generated/%s\n", $5, $NF }'
