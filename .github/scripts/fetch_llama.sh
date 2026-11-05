#!/usr/bin/env bash
# llama.cpp 공식 Apple 빌드(xcframework)를 받아 Vendor/llama.xcframework 에 둔다.
# 기기 안 번역(PLaMo 3 Translate)을 돌리는 엔진이다. 저장소엔 넣지 않고 빌드 때마다 받는다 (76MB).
# 버전을 올릴 때는 VERSION 과 SHA256 을 같이 바꾼다.
set -euo pipefail

VERSION="b12121"
SHA256="00bc6fec00beba802a3912a6afb81e1678da5248a6a92548a9ce66724a3e7638"
URL="https://github.com/ggml-org/llama.cpp/releases/download/${VERSION}/llama-${VERSION}-xcframework.zip"

TMP="${RUNNER_TEMP:-$(mktemp -d)}/llama-${VERSION}"
rm -rf "$TMP" && mkdir -p "$TMP"
curl -fsSL --retry 4 --retry-delay 2 -o "$TMP/llama.zip" "$URL"
echo "${SHA256}  $TMP/llama.zip" | shasum -a 256 -c -
unzip -q "$TMP/llama.zip" -d "$TMP/x"

mkdir -p Vendor
rm -rf Vendor/llama.xcframework
mv "$TMP/x/build-apple/llama.xcframework" Vendor/
echo "llama.cpp ${VERSION} → Vendor/llama.xcframework"
ls Vendor/llama.xcframework
