#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p downloads

fetch() {
    local name=$1 url=$2 sha=$3
    if [[ ! -f downloads/$name ]] || [[ "$(shasum -a 256 downloads/$name | cut -d' ' -f1)" != "$sha" ]]; then
        echo "downloading $name"
        curl -fL --retry 3 -o downloads/$name.part "$url"
        mv downloads/$name.part downloads/$name
    fi
    local got=$(shasum -a 256 downloads/$name | cut -d' ' -f1)
    if [[ "$got" != "$sha" ]]; then
        echo "checksum mismatch: $name ($got)"
        exit 1
    fi
    echo "ok: $name"
}

fetch sface.onnx https://media.githubusercontent.com/media/opencv/opencv_zoo/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx 0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79

if [[ "${1:-}" == "--all" ]]; then
    fetch buffalo_s.zip https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_s.zip d85a87f503f691807cd8bb97128bdf7a0660326cd9cd02657127fa978bab8b5e
    mkdir -p downloads/buffalo_s
    unzip -o -q downloads/buffalo_s.zip w600k_mbf.onnx -d downloads/buffalo_s
    fetch facenet_vggface2.pt https://github.com/timesler/facenet-pytorch/releases/download/v2.2.9/20180402-114759-vggface2.pt 281cebca8662831adb987a874bdcb36e73f5b1c6dc5ee5878f305e985625d99b
fi

if [[ ! -x .venv/bin/python ]]; then
    uv venv --python 3.12 .venv
    uv pip install --python .venv/bin/python "torch==2.7.0" "torchvision==0.22.0" "coremltools==9.0" onnx onnx2torch onnxruntime numpy pillow requests
    uv pip install --python .venv/bin/python --no-deps facenet-pytorch
fi
