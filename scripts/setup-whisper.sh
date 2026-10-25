#!/bin/bash
# First install requires network. Recording itself never accesses the network.
set -euo pipefail
model="${1:-base}"
case "$model" in base|small) ;; *) echo 'Usage: setup-whisper.sh [base|small]' >&2; exit 2;; esac
for tool in git cmake; do
    command -v "$tool" >/dev/null || { echo "Missing $tool. Install it before continuing." >&2; exit 1; }
done
install_dir="${LOCALPROMPTER_WHISPER_DIR:-$HOME/Library/Application Support/LocalPrompter/whisper.cpp}"
if [ ! -d "$install_dir/.git" ]; then
    git clone --depth 1 --branch v1.8.2 https://github.com/ggml-org/whisper.cpp.git "$install_dir"
fi
cmake -S "$install_dir" -B "$install_dir/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_SYSROOT="$(xcrun --sdk macosx --show-sdk-path)" -DGGML_METAL=ON -DBUILD_SHARED_LIBS=OFF
cmake --build "$install_dir/build" --config Release -j 4 --target whisper-cli
(cd "$install_dir" && bash models/download-ggml-model.sh "$model")
echo "Executable: $install_dir/build/bin/whisper-cli"
echo "Model: $install_dir/models/ggml-$model.bin"
