# Third-party notices

PhotoHub's own code is under the MIT License (see [LICENSE](LICENSE)). This file lists the third-party material that is in the repository or that PhotoHub downloads and uses.

## Bundled in the repository

### SFace face recognition model

- File: `App/Sources/PhotoHubAnalyzer/Resources/sface-fp16.mlpackage`
- Source: OpenCV Zoo, `models/face_recognition_sface/face_recognition_sface_2021dec.onnx` — <https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface>
- Paper: Yaoyao Zhong, Weihong Deng, Jiani Hu, Dongyue Zhao, Xian Li, Dongchao Wen. "SFace: Sigmoid-Constrained Hypersphere Loss for Robust Face Recognition." IEEE Transactions on Image Processing, 2021.
- License: Apache License 2.0. The full text is in [LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt).
- Changes: the ONNX model was converted to a Core ML `mlprogram` with FP16 weights by `tools/faces/convert.py` (ONNX → PyTorch with `onnx2torch` → Core ML with `coremltools`). The network and the weights were not retrained or otherwise changed; the conversion was checked against ONNX Runtime (cosine similarity ≥ 0.99999).
- Notice: Copyright the OpenCV Zoo contributors and the SFace authors. Licensed under the Apache License, Version 2.0; you may not use this file except in compliance with the License. Distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND.
- Use in PhotoHub: the model runs only on the user's Mac, offline, to compute face embeddings of the user's own photos and suggest names of people the user has already named. No face data leaves the Mac. The training data of these weights is not stated by OpenCV Zoo; the SFace paper trains on MS1MV2 (a cleaned MS-Celeb-1M) and CASIA-WebFace.

### Search labels

`App/Sources/PhotoHubAnalyzer/Resources/labels.json` maps the identifiers of Apple's `VNClassifyImageRequest` to English and Russian words. It is part of PhotoHub and under its MIT License. The identifiers themselves belong to Apple's Vision framework.

## Installed by `uv sync` (not bundled)

These Python packages are downloaded from PyPI onto the user's Mac. PhotoHub does not redistribute them.

| Package | License | Notes |
|---|---|---|
| [Pillow](https://github.com/python-pillow/Pillow) | MIT-CMU (HPND) | image decoding and resizing |
| [pillow-heif](https://github.com/bigcat88/pillow_heif) | BSD-3-Clause source; the macOS binary wheels are GPL-2.0 because they include libheif (LGPL-3.0), libde265 (LGPL-3.0) and x265 (GPL-2.0) | HEIC support |
| [geonamescache](https://github.com/yaph/geonamescache) | MIT | city names for places and trips |

geonamescache ships data from [GeoNames](https://www.geonames.org/), licensed under [Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/). Place names shown in PhotoHub come from this data.

## External tools (not bundled)

- [ExifTool](https://exiftool.org/) by Phil Harvey (Perl Artistic License or GPL) reads camera data during `photohub scan` and writes dates in the demo library.
- [Claude Code](https://claude.com/claude-code) runs the optional in-app agent under the user's own account and terms.
- `tools/faces/fetch.sh` downloads the source ONNX model above. With `--all` it also downloads two models used only for the comparison in `docs/recognition.md`: InsightFace `buffalo_s` (the weights are for non-commercial research only) and facenet-pytorch VGGFace2 weights. They are never bundled or used by the app.

## Demo images

`scripts/demo.sh` downloads free stock photos from [Unsplash](https://unsplash.com/) through [Lorem Picsum](https://picsum.photos/) at run time; they are not stored in the repository. They are used under the [Unsplash License](https://unsplash.com/license). The screenshots in `docs/images/` show these photos; the authors and source pages are listed in [docs/images/CREDITS.tsv](docs/images/CREDITS.tsv). People in the screenshots are stock models; the names shown next to them are invented for the demo.
