# Recognition on the Mac (step 6)

`PhotoHubAnalyzer` is a separate tool in the same Swift package (`App/Sources/PhotoHubAnalyzer`). Everything is computed on this Mac, offline, with Apple frameworks: Vision, ImageIO, Accelerate, Core ML. We do not train a large model: we take ready-made Vision fingerprints and the ready-made SFace face model in Core ML, and put small classifiers on top of them, trained on the people and pet tags from Photos.

## Where the images come from

Archive originals are never read: they live in iCloud Drive, and reading would download them.

| Source | What is read | `source_id` |
|---|---|---|
| Archive | the existing preview `~/Library/Application Support/PhotoHub/previews/<sha1(member.path)>.jpg` (2048 px), or if it is missing, the thumbnail `thumbs/<same>.jpg` (640 px) | `a:<member.path>` |
| Photos | the library's own derivatives in `~/Pictures/Photos Library.photoslibrary/resources/derivatives/` | `p:<ZUUID>` |

- The list of shots comes from the catalog: the `member` table, for the archive the roles `photo`, `edit`, `raw`, for Photos `photo`, `raw`. Videos are not analysed yet.
- Photos derivatives are named `<ZUUID>_<…>.jpeg` and live in `derivatives/<first character of the UUID>/` and `derivatives/masters/<first character>/`. The tool walks the folder once and for each UUID takes the largest image no bigger than 2048 px. Derivatives are already rotated as on screen. In this library most shots have only small derivatives: 557 × 782 px on average, often 360 × 480. Only 949 files have their originals in the library, the rest are in iCloud.
- PhotoKit is not used: from a command-line tool it would bring up an access request window. The terminal the tool is run from needs "Full Disk Access".
- `Photos.sqlite` is opened only as a copy: the file together with `-wal` and `-shm` is copied to a temporary folder, and the copy is deleted after the check.
- A shot is identified by `source_id`, not by catalog ids: the ids change on a rebuild.

Verified: before and after a full run, 16,385 of 16,492 archive files have the `dataless` flag. Eight sampled files show `compressed,dataless` in `ls -lO` before and after.

## What is stored

A separate database `~/Library/Application Support/PhotoHub/vision.sqlite`. Nothing is written to `catalog.sqlite`: the catalog gets rebuilt.

| Table | What it holds |
|---|---|
| `image` | a shot: `source_id`, which file was read, its size and modification time (the tool uses them to tell that a shot is already done), image size, analysis time, the shot fingerprint (`print`, `print_type`, `print_count`, `print_rev`), number of labels, faces, animals, error |
| `label` | `VNClassifyImageRequest` labels with confidence ≥ 0.15: `source_id`, `identifier`, `confidence` |
| `face` | `VNDetectFaceRectanglesRequest` faces: box, confidence, `VNDetectFaceCaptureQualityRequest` quality, head roll and yaw, crop side in pixels, crop fingerprint |
| `animal` | `VNRecognizeAnimalsRequest` cats and dogs: species, confidence, box, crop fingerprint |
| `run` | every run: arguments, macOS version, revisions of all Vision requests, how much was done, errors, seconds, shots per second, peak memory, state |
| `meta` | conventions: coordinate system, thresholds, how crops are cut |
| `face_embedding` | a face embedding from a Core ML model: `face_id` (= `face.id`), `model`, `source_id`, `idx`, `dim`, `vector` and `vector_flip` (float32, as the model returned them, not normalised; the second one is from the mirrored crop), `points` (5 Vision points, float32 x, y in pixels, origin at the top left), point confidence, alignment error |
| `face_embedding_fail` | faces for which no points were found or the file could not be read |
| `face_suggestion` | `faces-label` suggestions: `source_id`, `face_id`, `idx`, `name`, `score`, model, classifier, threshold |

- Boxes are stored as in Vision: fractions from 0 to 1, origin at the bottom left, on the rotated image.
- A face crop is a square with side max(w, h) × 1.3, an animal crop is a square × 1.1, shifted inside the frame.
- Revisions on macOS 15.7: classification 2, fingerprint 2, faces 3, face quality 3, animals 2.
- A revision 2 fingerprint is 768 float32 numbers, vector length 1. Vision's `computeDistance` matches the plain Euclidean distance between these vectors; checked on three previews: 1.155815 and 1.155815.
- Size: 220 MB for 26,496 shots, 8.5 KB per shot. By table: `image` 104 MB (mostly fingerprints of 3 KB each), `face` 68 MB, `label` 38 MB, `animal` 9 MB.

## Commands

Built separately from the app build:

```
swift build -c release --package-path App --product PhotoHubAnalyzer --scratch-path /tmp/photohub-analyzer-build
B=/tmp/photohub-analyzer-build/release/PhotoHubAnalyzer
```

| Command | What it does |
|---|---|
| `$B run` | analyses all shots; Photos first, then the archive |
| `$B run --limit 300` | only 300 shots that are not done yet |
| `$B run --only archive` / `--only photos` | only one source |
| `$B run --source 'a:2021/IMG_1.jpg'` | one shot, again |
| `$B run --workers 6` | number of threads, 4 by default |
| `$B stats` | what is in the database, size, recent runs |
| `$B similar <source_id> [--top 30]` | nearest shots by fingerprint |
| `$B search <words> [--top 20] [--min 0.3]` | search by labels, in Russian, in English and mixed |
| `$B faces-eval [--min-faces 10] [--seed 42]` | checks whether the fingerprints recognise people and pets from Photos |
| `$B faces-embed [--model sface-fp16] [--only archive\|photos] [--limit N] [--redo] [--dump folder]` | Vision face points, alignment, face model embeddings for all faces without an embedding |
| `$B faces-eval --model sface-fp16 [--flip]` | the same people check on the embeddings, next to the Vision fingerprints on the same faces; `--flip` — the sum with the mirrored crop |
| `$B faces-label [--classifier centroid\|1nn\|5nn\|linear] [--target 0.95] [--strangers 0.05] [--dry-run]` | picks a threshold on the by-day split, predicts names for unnamed faces and writes `face_suggestion` |

- `run` continues where it stopped. A shot is skipped if its file has not changed (same size and modification time) and the fingerprint revision is the same. Shots with an error are retried.
- Ctrl-C stops cleanly: shots in progress are finished and written to the database. A second Ctrl-C exits at once. Verified: stopped at shot 1,047, the restart continued from 1,647 done.
- Progress is printed every 200 shots: `analysis: N/M · X photos/s · ~… left · memory … MB`.
- A full run in the background, logging to `vision.log`:

```
nohup caffeinate -i "$B" run >> ~/Library/Application\ Support/PhotoHub/vision.log 2>&1 &
```

## Speed

MacBook with Apple M3, 16 GB, macOS 15.7, 4 threads.

| Run | Shots | Time | Shots per second | Peak memory |
|---|---|---|---|---|
| `run --limit 300`, Photos, first run | 300 | 5 s | 62.6 | 179 MB |
| `run --only archive --limit 300` | 300 | 9 s | 33.5 | 253 MB |
| full run, Photos | 10,334 | 78 s | 132 | — |
| full run, archive (2048 previews) | 14,515 | 215 s | 67.5 | — |
| full run, everything together | 24,849 | 4 min 54 s | 84.6 | 566 MB |

- Before the analysis the tool spends 16–26 s building the list of shots: it reads the sizes of all Photos derivatives.
- Average per shot in one thread: Photos 29 ms, archive 58 ms.
- Errors: 0 of 26,496.
- Found: 280,000 labels (885 distinct), 17,049 faces, 2,279 animals.

## Search by labels

- The table `Resources/labels.json` covers all 1,303 labels of `VNClassifyImageRequest().supportedIdentifiers()`. Each label has English names with plural forms and synonyms, and Russian names with synonyms and diminutives. Example: `dog` — "dog, dogs, puppy, puppies, doggy, canine" plus six Russian words for dog, dogs, hound, puppy and doggy.
- The reserved key `_search` in the same file holds the matching rules for queries: stop words, the Russian endings stripped to get a stem, a few Russian suffix pairs, and letter folds. Search reads them from there, so the Swift code has no language data of its own.
- Dog breeds also answer to "dog", cat breeds to "cat", birds to "bird", fish to "fish", dishes to "food" (the Russian words for these).
- The query is compared case-insensitively, and the Russian letter "yo" counts as "ye". English plurals are reduced to the singular: cats → cat, puppies → puppy. Russian words lose their common endings, and the fleeting vowel is handled: the plural and genitive plural of "dog" reduce to "dog", "kitties" to "kitty", and "puppies" (whose stem drops a vowel) to "puppy".
- The longest match is searched first: the Russian two-word phrase for "screen shot" is one label. Each word of the query is an AND condition: the Russian for "sunset at the sea" = (sunset_sunrise) and (beach or ocean). Prepositions are skipped.
- By default labels with confidence ≥ 0.3 count (`--min`).

| Query | Labels | Found | Archive | Photos |
|---|---|---|---|---|
| `dog` and the Russian for "dog" and "dogs" | 40 dog and breed labels | 133 | 82 | 51 |
| `cats` and the Russian for "cat" and "kitties" | adult_cat, cat, feline, kitten | 2,009 | 923 | 1,086 |
| the Russian for "sea" | beach, ocean | 96 | 85 | 11 |
| `sea` | ocean | 96 | 85 | 11 |
| the Russian for "sunset at the sea" | sunset_sunrise + beach/ocean | 3 | 3 | 0 |
| the Russian for "screenshot" | screenshot | 598 | 64 | 534 |
| the Russian for "documents" | document, passport, printed_page | 1,461 | 317 | 1,144 |

Examples of the first results:

- "sea" (Russian query): `2026-10 Trip/DSCF5724.JPG`, `2021/20210725_181050.jpg`.
- "dog" (Russian query): `2026-08 Trip/DSCF4495.JPG`, `2026-08 Trip/DSCF4535.JPG`.

## Similar shots

- All fingerprints (26,496 × 768) load into memory in 0.07–0.6 s and take 78 MB.
- Distances to all shots are computed with one matrix-vector multiplication (`cblas_sgemv` from Accelerate) in 5–7 ms.

An edit from Photoshop and Lightroom → its original and the other edits:

```
$B similar 'a:Personal/2021/2021-07-08 Shoot/DSCF6288_PS_LR.jpg' --top 8
  1  0.000  Personal/2021/2021-07-08 Shoot/New Folder (4)/New Folder (5)/DSCF6288_PS_LR.jpg  [edit]  ← same stack
  2  0.188  Personal/2021/2021-07-08 Shoot/DSCF6288_psYJHF.jpg  [edit]  ← same stack
  3  0.189  Personal/2021/2021-07-08 Shoot/DSCF6288_PS.jpg  [edit]  ← same stack
  4  0.231  Personal/2021/2021-07-08 Shoot/DSCF6288.JPG  [photo]  ← same stack
  5  0.504  Personal/2021/2021-07-08 Shoot/DSCF6285.JPG  [photo]
```

An edit with curves → the original in another folder, which is not in the stack. Exactly what "Find Similar" needs:

```
$B similar 'a:Personal/2026/DSCF6382_curves.png' --top 6
  1  0.021  Personal/2026/DSCF6382_curves.jpeg  [photo]  ← same stack
  2  0.145  Personal/2026/DSCF6382.jpeg  [edit]  ← same stack
  3  0.148  Personal/2026/DSCF6382.png  [photo]  ← same stack
  4  0.264  2026-10 Trip/DSCF6382.JPG  [photo]
  5  0.332  p:3A9D…  Photos: DSCF6382.JPG · 2026-10-15
```

A shot from Photos → its copy in the archive and the neighbouring shots of the burst:

```
$B similar p:8C1F4E2A-0B7D-4F3E-9A61-2D5C7B0E9F14 --top 6
  1  0.105  Pets/2022/IMG_0779.HEIC  [photo]  ← same stack
  2  0.121  Pets/2022/8C1F4E2A-0B7D-4F3E-9A61-2D5C7B0E9F14_1_105_c.jpeg  [photo]
  3  0.246  p:B47E…  Photos: IMG_0777.HEIC · 2022-10-18
```

From these examples: the same scene after editing is at distance 0.1–0.35, a neighbouring shot of the same shoot from 0.25, a different shot 0.5 and more. The suggestion "this looks like an edit of this shot" is worth showing at distance < 0.3 if the shot is in another stack. The threshold needs to be checked on more pairs.

## Check on people and pets from Photos (`faces-eval`)

### How it is done

1. From the copy of `Photos.sqlite` all `ZDETECTEDFACE` faces are taken with `ZCENTERX > 0`, not hidden, on shots not in the trash. The person is `ZPERSONFORFACE`. Merged people are unfolded along the `ZMERGETARGETPERSON` chain, the name comes from `ZDISPLAYNAME` (or `ZFULLNAME`). `ZDETECTIONTYPE` 1 is a person, 3 a dog, 4 a cat.
2. The Photos coordinate system was found by experiment: the tool tries 8 variants (mirrorings and swaps of x and y) separately for each EXIF orientation. In all orientations "as is" wins: `ZCENTERX`, `ZCENTERY` are fractions of the rotated image with the origin at the bottom left, as in Vision. 96.9 % of faces matched; the next best variant gives 22–65 %. `ZSIZE` ≈ 0.82 of the side of our box (as a fraction of the shot's long side).
3. A Photos face and a Vision face are a pair if their centres are closer than half the side of our box. Pairs are matched greedily, nearest first. A pet's face in Photos is attached to the smallest Vision animal box that contains its centre.
4. The feature is the Vision fingerprint of the crop, normalised to length 1. Classes are people and pets with ≥ 10 examples. "Strangers" for the rejection check are unnamed faces and people with < 10 faces.
5. Classifiers:
   - 1-NN and 5-NN by cosine similarity, 5-NN votes weighted by similarity;
   - centroid: one mean vector per person;
   - linear model: softmax regression with class weights, 300 Adam steps.
   Confidence score: similarity to the nearest neighbour or to the centroid, probability for the linear model.
6. Two splits, 20 % of each class into the test set:
   - **random** — by individual faces;
   - **by day** — all of a person's shots from one day go entirely either into training or into the test set. This is the honest estimate: with a random split the test set gets neighbouring shots of a burst that are almost identical to shots in training.

### Data

- 11,681 Photos shots. On them Photos has 4,641 people's faces and 920 pet faces. Vision found 4,820 faces and 1,256 animals.
- 4,498 faces matched (96.9 %): 3,423 named, 1,075 unnamed. Pets matched: 735 of 920 (79.9 %).
- 19 people with ≥ 10 faces, 3,403 faces in total. The most frequent class is Person 1, 69.7 % of faces: that is what the answer "always Person 1" gets.
- 4 pets with ≥ 10 faces: Pet 1, Pet 2, Pet 3, Pet 4, 636 in total. The most frequent class is 52.7 %.

### People: Vision fingerprint of the face crop

| Classifier | Random: accuracy | Random: mean recall per person | By day: accuracy | By day: mean recall | By day: coverage at accuracy ≥ 95 % | By day: strangers accepted at that point |
|---|---|---|---|---|---|---|
| 1-NN | 94.7 % | 80.7 % | 77.3 % | 48.0 % | 2.9 % | 1.2 % |
| 5-NN | 93.0 % | 71.7 % | 78.7 % | 45.0 % | 2.9 % | 1.2 % |
| centroid | 49.3 % | 75.0 % | 42.6 % | 50.7 % | unreachable | — |
| linear | 91.6 % | 89.1 % | 78.5 % | 68.3 % | 56.5 % | 25.4 % |

- With the by-day split the result is only slightly better than the answer "always Person 1" (68.6 % of test faces).
- Recall per person with the by-day split (linear model):

  | Person | Recall |
  |---|---|
  | Person 1 | 79 % |
  | Person 3 | 93 % |
  | Person 19 | 100 % |
  | Person 14 | 100 % |
  | Person 8 | 65 % |
  | Person 4 | 39 % |
  | Person 5 | 21 % |
  | Person 6 | 0 % |

- Crop size matters little. Random split, 1-NN: < 64 px — 93.7 %, ≥ 256 px — 96.8 %.

### Pets: Vision fingerprint of the animal crop

| Classifier | Random: accuracy | By day: accuracy | By day: mean recall | By day: coverage at accuracy ≥ 90 % | By day: strangers accepted at that point |
|---|---|---|---|---|---|
| 1-NN | 94.5 % | 77.4 % | 62.6 % | 8.9 % | 1.0 % |
| 5-NN | 91.3 % | 84.7 % | 67.2 % | 58.9 % | 8.1 % |
| centroid | 89.8 % | 73.4 % | 61.4 % | 25.0 % | 3.0 % |
| linear | 97.6 % | 92.7 % | 95.7 % | 100 % | 100 % |

- The fingerprint of the whole shot instead of the crop is worse: by day, linear 87.1 %, 5-NN 81.5 %.
- "Strangers" for pets are 99 unnamed faces. Most likely they are the same cats without a tag, so the share of accepted "strangers" is unreliable here.

### Conclusion and recommendation

**People: Vision fingerprints of the face crop are not enough, a separate face model in Core ML is needed.** Done, see "SFace face model in Core ML" below.

- The Vision fingerprint describes the scene and the overall look of the image, not facial features. That is why it finds neighbouring shots of the same shoot well (random split, 1-NN 94.7 %), but recognises a person on another day poorly: 77–79 % against a baseline of 69.7 %.
- At the level where suggestions can be trusted (95 % accuracy) it recognises only 3–56 % of faces, and the linear model then accepts every fourth stranger's face.
- The centroid is the worst for people: one averaged vector does not cover different poses and lighting.
- What to do:
  1. Take a ready-made compact face fingerprint model like ArcFace / MobileFaceNet (input 112 × 112, output 128–512 numbers, 4–20 MB), convert it to Core ML and run it on crops aligned by Vision face points (`VNDetectFaceLandmarksRequest`: eyes, nose, mouth). The licence of the weights must be checked: some InsightFace weights are allowed for research only.
  2. On top of it — not training from scratch, but k-NN over all confirmed faces of a person (many "samples" per person) and a threshold for "unknown". Add the linear model as a second vote once a person has more than 30–50 confirmed faces.
  3. Repeat `faces-eval` with the new fingerprint, with the same by-day split. Goal: coverage ≥ 80 % at accuracy ≥ 95 % and ≤ 5 % strangers accepted.
- For Photos shots, people are already labelled by the library itself. Our own model is needed for the archive, where there are no tags; there the previews are 2048 px and faces are larger than in Photos derivatives.

**Pets: the Vision fingerprint of the animal crop works as a basis.**

- The linear model by day — 92.7 % on four pets, 5-NN — 84.7 %.
- Recommendation: the linear model to choose who it is, plus 5-NN by similarity as the check "is this our pet at all", threshold around 0.84.
- An honest set of "strangers" (cats and dogs not from the family) is needed to tune rejection.

## SFace face model in Core ML

### Which models were compared

| Model | Code | Weights | Trained on | Source size | Core ML FP16 | Vector |
|---|---|---|---|---|---|---|
| **SFace** (MobileFaceNet + SFace loss), OpenCV Zoo `face_recognition_sface_2021dec.onnx` | Apache 2.0 | **Apache 2.0**: "All files in this directory are licensed under Apache 2.0 License" | OpenCV does not say. The SFace paper uses MS1MV2 (cleaned MS-Celeb-1M) and CASIA-WebFace; not verified for this file | 37 MB ONNX | **18.4 MB** | 128 |
| InsightFace `buffalo_s` → `w600k_mbf.onnx` (MobileFaceNet, ArcFace) | MIT | **non-commercial research only**: "The pretrained models provided with this library are for non-commercial research only" | WebFace600K | 13 MB ONNX | 6.6 MB | 512 |
| facenet-pytorch `InceptionResnetV1` VGGFace2 | MIT | no separate licence for the weights; ported from davidsandberg/facenet (MIT) | VGGFace2, dataset terms not checked | 107 MB `.pt` | 45 MB | 512 |
| InsightFace `buffalo_l` → `w600k_r50.onnx` | MIT | non-commercial research only | WebFace600K | 166 MB ONNX | not tried: over 30 MB and the same licence | 512 |
| dlib `dlib_face_recognition_resnet_model_v1` | Boost | CC0 | ~3 million faces (FaceScrub, VGG and others) | 22 MB | not tried: would need porting the dlib network to PyTorch | 128 |

**SFace FP16** was chosen: a free licence for the weights, 18.4 MB, and on these people it trails `w600k_mbf` in accuracy by 0.5 percentage points (4 faces out of 860). `w600k_mbf` is acceptable for a personal non-commercial app too, but its licence forbids any commercial use; it is not worth keeping as the main one.

### How it works

- Conversion happens only during development: `tools/faces/fetch.sh` downloads the source and checks its SHA-256, creates `tools/faces/.venv` (Python 3.12, torch 2.7, coremltools 9). `tools/faces/convert.py sface` — ONNX → PyTorch (`onnx2torch`) → `mlprogram`, image input 112 × 112 RGB, FP16. Check after conversion: the cosine between the Core ML output and ONNX Runtime ≥ 0.99999.
- The model file is in the repository: `App/Sources/PhotoHubAnalyzer/Resources/sface-fp16.mlpackage`, 18.4 MB, a target resource in `Package.swift`. No download is needed: the model is under 30 MB, works offline and always matches the code. On first run it is compiled into `~/Library/Application Support/PhotoHub/models/compiled/sface-fp16-<hash>.mlmodelc`, about 0.5 s. At run time only this file is needed, no Python.
- Other models: `--model name` looks for `name.mlpackage` or `.mlmodelc` in `PHOTOHUB_MODELS`, in the resources and in `~/Library/Application Support/PhotoHub/models/`; `--model path` takes the file directly.
- Alignment: the image is read the same way as in `run` (archive preview or Photos derivative, ≤ 2048 px), face boxes come from the `face` table. `VNDetectFaceLandmarksRequest` on these boxes gives the points. Five of them are used: the pupils, the middle of the nose (the mean of the lowest point of the nose contour and its centre), the corners of the mouth (the extreme points of the outer lip contour along the eye line). A similarity transform (rotation, scale, shift, least squares) maps them onto the ArcFace 112 × 112 template; the crop is drawn through Core Graphics straight into a `CVPixelBuffer`.
- Two vectors are computed for each face: from the crop and from the mirrored crop. Mirroring does not change accuracy (by day 1-NN 98.6 % instead of 98.5 %), so `faces-eval` and `faces-label` use the direct vector by default.
- Points were found for all 17,049 faces, 0 failures. Crops were checked by eye on 35 faces: the eyes and mouth land on the template points.
- FP16 and FP32 give the same `faces-eval` results to a tenth of a percent; FP32 weighs 36.8 MB and is slower (102 faces/s against 140–197), because it does not run on the Neural Engine.

### Speed and space

| Run | Faces | Shots | Time | Faces per second | Shots per second | Peak memory |
|---|---|---|---|---|---|---|
| `faces-embed`, SFace FP16, 4 threads | 17,049 | 12,936 | 1 min 27 s – 2 min 2 s | 140–197 | 106–149 | 208–235 MB |
| the same, SFace FP32 | 17,049 | 12,936 | 2 min 48 s | 102 | 77 | 266 MB |
| `w600k_mbf` FP16 | 17,049 | 12,936 | 1 min 50 s | 156 | 118 | 246 MB |
| facenet FP16 (160 × 160) | 17,049 | 12,936 | 2 min 16 s | 126 | 95 | 200 MB |

- The speed includes reading the image, Vision points, two crops and two model passes per face. The SFace spread is from different runs on the same Mac (M3, 16 GB, macOS 15.7).
- `face_embedding` for SFace is 23 MB for 17,049 faces.

### Comparison on people from Photos

The same 4,498 matched faces, the same splits (seed 42), the same 19 people with ≥ 10 faces, "strangers" are 1,095 unnamed faces and faces of people with < 10 faces. The Vision numbers match the table above.

By-day split:

| Fingerprint | Classifier | Accuracy | Mean recall | Coverage at accuracy ≥ 95 % | Strangers accepted at that point | Coverage at ≤ 5 % strangers | Correct among accepted at that point |
|---|---|---|---|---|---|---|---|
| Vision | 1-NN | 77.3 % | 48.0 % | 2.9 % | 1.2 % | 12.4 % | 84.1 % |
| Vision | 5-NN | 78.7 % | 45.0 % | 2.9 % | 1.2 % | 12.4 % | 82.2 % |
| Vision | centroid | 42.6 % | 50.7 % | unreachable | — | 15.7 % | 54.1 % |
| Vision | linear | 78.5 % | 68.3 % | 56.5 % | 25.4 % | 17.8 % | 98.7 % |
| **SFace** | 1-NN | **98.5 %** | 95.2 % | 100 % | 100 % (no threshold needed) | 66.3 % | 100 % |
| **SFace** | 5-NN | **98.7 %** | 95.3 % | 100 % | 100 % | 66.3 % | 100 % |
| **SFace** | centroid | 95.5 % | 96.6 % | 100 % | 100 % | **81.2 %** | 100 % |
| **SFace** | linear | 95.7 % | 97.0 % | 100 % | 100 % | 55.5 % | 100 % |
| w600k_mbf | 1-NN | 99.0 % | 96.5 % | 100 % | 100 % | 66.3 % | 100 % |
| w600k_mbf | 5-NN | 99.1 % | 96.5 % | 100 % | 100 % | 68.0 % | 100 % |
| w600k_mbf | centroid | 97.2 % | 97.9 % | 100 % | 100 % | 82.8 % | 100 % |
| w600k_mbf | linear | 95.7 % | 97.1 % | 100 % | 100 % | 51.6 % | 99.5 % |
| facenet | 1-NN | 98.6 % | 97.7 % | 100 % | 100 % | 56.5 % | 100 % |
| facenet | 5-NN | 98.5 % | 97.6 % | 100 % | 100 % | 56.5 % | 100 % |
| facenet | centroid | 94.4 % | 98.0 % | 99.3 % | 87.9 % | 68.8 % | 100 % |
| facenet | linear | 92.7 % | 97.0 % | 96.4 % | 81.0 % | 38.3 % | 99.7 % |

Random split, accuracy / mean recall: Vision 1-NN 94.7 / 80.7 %, linear 91.6 / 89.1 %; SFace 1-NN 99.1 / 97.6 %, 5-NN 99.3 / 98.0 %, centroid 96.9 / 97.8 %, linear 95.5 / 97.7 %; w600k_mbf 1-NN 99.4 / 98.1 %; facenet 1-NN 99.3 / 97.6 %.

- With SFace 95 % accuracy is reached already without a threshold, so the column "coverage at accuracy ≥ 95 %" no longer tells anything. The threshold is now needed against strangers' faces, and the main measure is coverage under a limit on the share of accepted strangers.
- Stricter limits, SFace by day: ≤ 2 % strangers — centroid 30.1 %, 1-NN 21.9 %, linear 36.2 %; ≤ 1 % strangers — centroid 20.0 %, 1-NN 10.2 %, linear 26.0 %. Accuracy among the accepted is 100 % everywhere.
- The share of "strangers" is most likely overstated. Unnamed faces in Photos are not necessarily strangers. Of the 48 such faces with the highest SFace score, 38 are named Person 1 by SFace, and on the crops they look like one and the same person (among them stage make-up, a drawing and a photo of a document); the other 10 are different people. It looks like Photos simply did not tag Person 1 in these shots. There are only 20 real named strangers (people with < 10 faces).
- Accuracy barely depends on face size (SFace, random split, 1-NN): < 64 px 98.7 %, 64–127 px 99.5 %, 128–255 px 98.4 %, ≥ 256 px 99.5 %.

Recall per person, by-day split, the 10 people with the most faces (SFace — accuracy / recall):

| Person | Faces in test | Vision, linear: recall | SFace 1-NN | SFace centroid |
|---|---|---|---|---|
| Person 1 | 590 | 79 % | 99 / 100 % | 100 / 95 % |
| Person 3 | 107 | 93 % | 99 / 98 % | 99 / 98 % |
| Person 8 | 20 | 65 % | 100 / 100 % | 83 / 100 % |
| Person 7 | 14 | 79 % | 100 / 100 % | 64 / 100 % |
| Person 10 | 24 | 88 % | 100 / 96 % | 96 / 96 % |
| Person 5 | 14 | 21 % | 100 / 100 % | 100 / 100 % |
| Person 11 | 12 | 100 % | 73 / 92 % | 80 / 100 % |
| Person 14 | 14 | 100 % | 100 / 100 % | 93 / 100 % |
| Person 19 | 15 | 100 % | 100 / 100 % | 79 / 100 % |
| Person 4 | 18 | 39 % | 100 / 78 % | 100 / 83 % |

- The worst are Person 4 (78–83 %) and Person 6 (70 % for 1-NN, 80 % for the centroid, 10 faces in test). For three people (Person 12, Person 16, Person 13) all faces went into training: too few days, nothing to test.

### Name suggestions (`faces-label`)

1. Training uses all faces of the 19 people with ≥ 10 faces from Photos. The threshold is picked on the by-day split: the lowest one at which accuracy among the accepted is ≥ 95 % (`--target`) and ≤ 5 % strangers are accepted (`--strangers`).
2. The default classifier is the centroid: at ≤ 5 % strangers it has the largest coverage (81 % against 66 % for k-NN).
3. A suggestion is given to unnamed faces: all archive faces and Photos faces without a person (unnamed or without a pair in Photos). Suggestions with a score below the threshold are not written.
4. Nothing is written to `catalog.sqlite`; the catalog is opened read-only, to map archive files to shots.

Result, SFace FP16, centroid:

- Threshold 0.600. On the by-day test: coverage 81.2 %, correct among the accepted 100 % (860 faces), strangers accepted 4.9 %.
- Unnamed faces: 13,626: 12,229 in the archive, 1,397 in Photos. 7,035 have a suggestion: 6,963 in the archive (57 %), 72 in Photos, of which 55 are Person 1.

Archive, how many suggestions per person:

| Person | Faces | Archive files | Catalog shots |
|---|---|---|---|
| Person 1 | 4,215 | 4,208 | 3,954 |
| Person 2 | 1,056 | 1,049 | 971 |
| Person 3 | 304 | 304 | 302 |
| Person 4 | 201 | 201 | 196 |
| Person 5 | 185 | 185 | 185 |
| Person 6 | 151 | 151 | 151 |
| Person 7 | 131 | 131 | 131 |
| Person 8 | 126 | 126 | 125 |
| Person 9 | 109 | 109 | 76 |
| Person 10 | 103 | 103 | 103 |
| Person 11 | 81 | 81 | 81 |
| Person 12 | 76 | 76 | 56 |
| Person 13 | 63 | 63 | 63 |
| Person 14 | 60 | 60 | 56 |
| Person 15 | 50 | 50 | 32 |
| Person 16 | 22 | 22 | 22 |
| Person 17 | 19 | 19 | 19 |
| Person 18 | 7 | 7 | 6 |
| Person 19 | 4 | 4 | 4 |

Examples for a human check, one from each fifth by score:

| Person | Score | `source_id` |
|---|---|---|
| Person 1 | 0.668 | `a:2021/2021-04-20 Trip/photo_2021-06-23_11-08-11.jpg` (face #1) |
| Person 1 | 0.679 | `a:Personal/2024/2024-10-11 Event/IMG_1512.HEIC` |
| Person 1 | 0.713 | `a:Personal/2021/2021-07-08 Shoot/DSCF5890_PS_LR.jpg` |
| Person 1 | 0.754 | `a:2020/20200823_165436.jpg` (face #1) |
| Person 1 | 0.808 | `a:Personal/2026/2026-07 Trip/DSC05402.JPG` |
| Person 2 | 0.604 | `a:Personal/2021/2021-07-08 Shoot/S0025575.JPG` |
| Person 2 | 0.667 | `a:2021/2021-04-20 Trip/DSCF3947.JPG` (face #1) |
| Person 2 | 0.716 | `a:2019/20190723_193101.jpg` |
| Person 2 | 0.730 | `a:Personal/2021/2021-07-08 Shoot/DSCF5664.JPG` |
| Person 2 | 0.801 | `a:2026-02 Trip/DSCF2465.jpg` |
| Person 3 | 0.739 | `a:2025 Trip/DSCF0759.JPG` |
| Person 3 | 0.786 | `a:2025 Trip/DSCF0424.JPG` |
| Person 3 | 0.825 | `a:2025 Trip/DSCF0970.JPG` |
| Person 3 | 0.846 | `a:2025 Trip/DSCF0986.JPG` |
| Person 3 | 0.911 | `a:2025 Trip/DSCF0434.JPG` |

- A quick look at the crops: 48 random "Person 2" suggestions in the archive are one and the same face; 40 random borderline suggestions (0.60–0.64) for the other people look like one person within each name. Only the owner can check that they match the real people.
- Person 2 has 32 tagged faces in Photos, but 1,056 suggestions in the archive: by the crops it is one person who was photographed a lot with a camera. This is worth checking first.

### Conclusion and recommendation

**The face model solves the task: SFace FP16 by day — 98.5 % (1-NN) against 77.3 % for the Vision fingerprint, accuracy among the accepted suggestions 100 % at 81 % coverage and ≤ 5 % strangers accepted.** The goal from the previous section (coverage ≥ 80 % at accuracy ≥ 95 % and ≤ 5 % strangers) is reached by the centroid.

- For the app: SFace FP16 from the resources, the embedding computed right after `run` for new faces; the centroid over confirmed faces with a threshold around 0.60 for the suggestion, and 5-NN as a second vote (if 5-NN names another person, do not show the suggestion).
- Recompute the threshold on every training the same way as in `faces-label`: on the by-day split, with a limit on the share of strangers.
- Store "This is her" / "This is not him" confirmations separately by `source_id` and `idx` and add them to training: for people with 10–30 faces the centroid is still weaker than k-NN in accuracy (Person 7 64 %, Person 19 79 %).
- `w600k_mbf` is slightly more accurate (99.0 % by day), and it can be plugged in through `--model`. It should not be the main one: the weights are for non-commercial research only.

## How to bring this into the app

- **Search bar.** Words are first looked up in the label table (like `search`), together with the existing filters by year, place and people: "sea 2021", "Alex in Vienna". Later a MobileCLIP layer will be added for queries without labels ("dog on the beach").
- **"Find Similar"** on the shot page. The fingerprint matrix is kept in memory, the result is a grid by increasing distance, similarity percentage = 1 − d/2. Filters: only edits, only other folders, only Photos, threshold. Vision fingerprints will replace the dHash from step 5.
- **Edit suggestions.** At night or after a scan: for each shot, neighbours at distance < 0.3 in another stack → "this looks like an edit of this shot". Confirmations are stored separately from the automatic results, by `source_id`.
- **"Who is in the photo".** Face and animal boxes over the preview (Vision coordinates, origin at the bottom left). Under each box — the suggestion from `face_suggestion` with its confidence and the buttons "This is her" / "This is not him". Answers are written to a separate confirmations table by `source_id` and box number, and right away, on this Mac, recompute the centroids and k-NN over the SFace embeddings.
- **Collapsing bursts.** Shots of one day at distance < 0.25 from each other are one burst with the best shot on top.
- **Analysis in the app.** The same code from `PhotoHubAnalyzer` moves into the app as a background task after scanning. New shots are analysed as their previews appear: about 70 shots per second for archive previews.

## Not verified

- Videos are not analysed.
- `faces-eval` was checked only on Photos shots (tags exist only there). Archive suggestions have not been checked against the real people: only the crops were looked at, and only the owner can confirm a name match.
- The dataset the OpenCV Zoo SFace weights were trained on is not stated in the repository. MS1MV2 from the paper is a guess. The VGGFace2 terms for the facenet weights were not checked.
- `faces-embed` is not built into `run`: after analysing new shots it has to be run separately.
- The speed of the model alone, without reading images and Vision points, was not measured separately.
- The 0.600 threshold was picked on 860 test faces and 1,095 "strangers", many of whom apparently are not strangers.
- Peak memory of 566 MB at the end of the full run: the growth during the archive analysis was not investigated.
- The 0.3 threshold for "looks like an edit" was derived from three examples.
- RAW files from Photos are analysed through their JPEG derivatives; the RAW files themselves were not read.
