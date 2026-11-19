import argparse
import hashlib
import json
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import onnx
import onnxruntime as ort
import torch

HERE = Path(__file__).resolve().parent

MODELS = {
    "sface": {
        "source": "downloads/sface.onnx",
        "kind": "onnx",
        "size": 112,
        "scale": 1.0,
        "bias": 0.0,
        "license": "Apache-2.0 (opencv_zoo models/face_recognition_sface)",
        "url": "https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface",
    },
    "mbf": {
        "source": "downloads/buffalo_s/w600k_mbf.onnx",
        "kind": "onnx",
        "size": 112,
        "scale": 1 / 127.5,
        "bias": -1.0,
        "license": "insightface pretrained models: non-commercial research only",
        "url": "https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_s.zip",
    },
    "facenet": {
        "source": "downloads/facenet_vggface2.pt",
        "kind": "facenet",
        "size": 160,
        "scale": 1 / 128.0,
        "bias": -127.5 / 128.0,
        "license": "facenet-pytorch MIT; weights ported from davidsandberg/facenet (MIT), trained on VGGFace2",
        "url": "https://github.com/timesler/facenet-pytorch/releases/download/v2.2.9/20180402-114759-vggface2.pt",
    },
}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def onnx_module(path):
    from onnx2torch import convert

    model = onnx.load(path)
    init_names = {i.name for i in model.graph.initializer}
    keep = [i for i in model.graph.input if i.name not in init_names]
    del model.graph.input[:]
    model.graph.input.extend(keep)
    for i in model.graph.input:
        i.type.tensor_type.shape.dim[0].dim_value = 1
    return convert(model).eval(), model


def facenet_module(path):
    from facenet_pytorch import InceptionResnetV1

    net = InceptionResnetV1(pretrained=None, classify=False, num_classes=8631)
    state = torch.load(path, map_location="cpu")
    net.load_state_dict(state, strict=False)
    return FacenetEmbedding(net.eval()).eval(), None


class FacenetEmbedding(torch.nn.Module):
    def __init__(self, net):
        super().__init__()
        self.net = net
        bn = net.last_bn
        k = bn.weight / torch.sqrt(bn.running_var + bn.eps)
        self.head = torch.nn.Linear(net.last_linear.in_features, net.last_linear.out_features)
        with torch.no_grad():
            self.head.weight.copy_(net.last_linear.weight * k[:, None])
            self.head.bias.copy_(bn.bias - bn.running_mean * k)

    def forward(self, x):
        n = self.net
        for layer in [n.conv2d_1a, n.conv2d_2a, n.conv2d_2b, n.maxpool_3a, n.conv2d_3b, n.conv2d_4a, n.conv2d_4b,
                      n.repeat_1, n.mixed_6a, n.repeat_2, n.mixed_7a, n.repeat_3, n.block8]:
            x = layer(x)
        x = x.mean(dim=(2, 3))
        return self.head(x)


def reference(name, cfg, module, onnx_model, raw):
    if cfg["kind"] == "onnx":
        sess = ort.InferenceSession(str(HERE / cfg["source"]), providers=["CPUExecutionProvider"])
        inp = sess.get_inputs()[0].name
        x = raw if name == "sface" else raw * cfg["scale"] + cfg["bias"]
        return sess.run(None, {inp: x.astype(np.float32)})[0]
    with torch.no_grad():
        return module(torch.from_numpy((raw * cfg["scale"] + cfg["bias"]).astype(np.float32))).numpy()


def cosine(a, b):
    a = a.reshape(a.shape[0], -1)
    b = b.reshape(b.shape[0], -1)
    a = a / np.linalg.norm(a, axis=1, keepdims=True)
    b = b / np.linalg.norm(b, axis=1, keepdims=True)
    return (a * b).sum(1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name", choices=sorted(MODELS))
    ap.add_argument("--precision", choices=["fp16", "fp32"], default="fp16")
    ap.add_argument("--out", default=str(HERE / "out"))
    args = ap.parse_args()
    cfg = MODELS[args.name]
    src = HERE / cfg["source"]
    if not src.exists():
        sys.exit(f"source model not found: {src}")
    module, onnx_model = onnx_module(src) if cfg["kind"] == "onnx" else facenet_module(src)
    size = cfg["size"]
    example = torch.rand(1, 3, size, size) * 255
    if args.name != "sface":
        example = example * cfg["scale"] + cfg["bias"]
    traced = torch.jit.trace(module, example)
    image = ct.ImageType(
        name="image",
        shape=(1, 3, size, size),
        color_layout=ct.colorlayout.RGB,
        scale=1.0 if args.name == "sface" else cfg["scale"],
        bias=[0.0, 0.0, 0.0] if args.name == "sface" else [cfg["bias"]] * 3,
    )
    mlmodel = ct.convert(
        traced,
        inputs=[image],
        outputs=[ct.TensorType(name="embedding")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16 if args.precision == "fp16" else ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS13,
    )
    mlmodel.short_description = f"{args.name}: face embedding of a {size}×{size} aligned crop"
    mlmodel.license = cfg["license"]
    mlmodel.user_defined_metadata["source_sha256"] = sha256(src)
    mlmodel.user_defined_metadata["source_url"] = cfg["url"]
    mlmodel.user_defined_metadata["input_size"] = str(size)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    path = out / f"{args.name}-{args.precision}.mlpackage"
    mlmodel.save(str(path))

    from PIL import Image

    rng = np.random.default_rng(0)
    raws = []
    for _ in range(4):
        smooth = rng.random((8, 8, 3)) * 255
        img = Image.fromarray(smooth.astype(np.uint8)).resize((size, size), Image.BILINEAR)
        raws.append(np.asarray(img).astype(np.float32))
    batch = np.stack(raws).transpose(0, 3, 1, 2)
    ref = np.concatenate([reference(args.name, cfg, module, onnx_model, batch[i : i + 1]) for i in range(len(raws))])
    loaded = ct.models.MLModel(str(path))
    got = np.concatenate(
        [np.asarray(loaded.predict({"image": Image.fromarray(raws[i].astype(np.uint8))})["embedding"]) for i in range(len(raws))]
    )
    sims = cosine(ref, got)
    total = sum(f.stat().st_size for f in path.rglob("*") if f.is_file())
    print(json.dumps({"model": str(path), "mb": round(total / 1048576, 2), "dim": int(got.reshape(len(raws), -1).shape[1]),
                      "cosine_vs_reference_min": float(sims.min())}, ensure_ascii=False))


if __name__ == "__main__":
    main()
