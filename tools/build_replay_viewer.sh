#!/usr/bin/env bash
# Coworld replay-viewer build hook: invoked by `coworld build` with one
# argument, the absolute path of the static bundle directory to produce
# (<manifest-dir>/static-replay-viewer, must end up containing index.html).
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 /absolute/path/to/static-replay-viewer" >&2
  exit 1
fi

output_dir="$1"
if [[ "${output_dir}" != /* ]]; then
  echo "output dir must be absolute: ${output_dir}" >&2
  exit 1
fi

export PATH="$HOME/.nimby/nim/bin:$PATH"

if command -v emcc >/dev/null && command -v nim >/dev/null; then
  # Local toolchain: build the wasm module directly.
  (cd "${repo_dir}" && nim c --hints:off -d:emscripten \
    replay-viewer/gridwars_replay.nim)
else
  # Fall back to the pinned emsdk container.
  image_tag="gridwars-replay-viewer-build:$$"
  docker build --platform linux/amd64 \
    --file "${repo_dir}/Dockerfile.replay-viewer" \
    --tag "${image_tag}" "${repo_dir}"
  container_id="$(docker create "${image_tag}")"
  rm -rf "${repo_dir}/replay-viewer/dist"
  docker cp "${container_id}:/workspace/gridwars/replay-viewer/dist" \
    "${repo_dir}/replay-viewer/dist"
  docker rm "${container_id}" >/dev/null
  docker image rm "${image_tag}" >/dev/null
fi

dist="${repo_dir}/replay-viewer/dist"
test -s "${dist}/gridwars_replay.wasm"
test -s "${dist}/gridwars_replay.js"

# `coworld build` pre-creates the bundle's parent directory; a plain CI
# checkout does not, and every fork of this hook that resolves the output
# path without creating it exits 1 there (ecos, 2026-08-23).
mkdir -p "$(dirname "${output_dir}")"
parent="$(cd "$(dirname "${output_dir}")" && pwd)"
if [[ "${parent}" != /* ]]; then
  echo "output parent did not resolve: ${output_dir}" >&2
  exit 1
fi
rm -rf "${output_dir}"
mkdir -p "${output_dir}/assets"
cp "${dist}/gridwars_replay.js" "${dist}/gridwars_replay.wasm" "${output_dir}/"
cp "${repo_dir}/replay-viewer/index.html" \
  "${repo_dir}/replay-viewer/static_replay.js" \
  "${repo_dir}/client/renderer.js" \
  "${repo_dir}/client/chrome.css" \
  "${output_dir}/"
for asset in soldier_red_front.png soldier_blue_front.png \
  soldier_green_front.png soldier_yellow_front.png \
  arena_floor.png font.ttf; do
  cp "${repo_dir}/data/${asset}" "${output_dir}/assets/"
done

test -f "${output_dir}/index.html"
grep -q 'data-replay' "${output_dir}/static_replay.js"
echo "grid-wars replay viewer bundle: ${output_dir}"
