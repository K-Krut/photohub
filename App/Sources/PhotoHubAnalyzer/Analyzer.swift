import CoreGraphics
import Foundation
import ImageIO
import Vision

struct PrintData {
    let data: Data
    let elementType: Int
    let count: Int
    let revision: Int

    init(_ obs: VNFeaturePrintObservation, revision: Int) {
        data = obs.data
        elementType = Int(obs.elementType.rawValue)
        count = obs.elementCount
        self.revision = revision
    }
}

struct FaceResult {
    let box: CGRect
    let confidence: Float
    let quality: Float?
    let roll: Float?
    let yaw: Float?
    let cropPx: Int
    let print: PrintData?
}

struct AnimalResult {
    let label: String
    let confidence: Float
    let box: CGRect
    let cropPx: Int
    let print: PrintData?
}

struct Analysis {
    let input: InputImage
    var width = 0
    var height = 0
    var labels: [(String, Float)] = []
    var print: PrintData?
    var faces: [FaceResult] = []
    var animals: [AnimalResult] = []
    var ms: Double = 0
    var error: String?
}

enum Revisions {
    static let classify = VNClassifyImageRequest.supportedRevisions.last ?? VNClassifyImageRequest.defaultRevision
    static let print = VNGenerateImageFeaturePrintRequest.supportedRevisions.last ?? VNGenerateImageFeaturePrintRequest.defaultRevision
    static let faces = VNDetectFaceRectanglesRequest.supportedRevisions.last ?? VNDetectFaceRectanglesRequest.defaultRevision
    static let quality = VNDetectFaceCaptureQualityRequest.supportedRevisions.last ?? VNDetectFaceCaptureQualityRequest.defaultRevision
    static let animals = VNRecognizeAnimalsRequest.supportedRevisions.last ?? VNRecognizeAnimalsRequest.defaultRevision
}

let labelThreshold: Float = 0.15
let maxSide = 2048

func loadImage(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxSide,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
}

func cropRect(_ box: CGRect, width: Int, height: Int, scale: CGFloat) -> CGRect? {
    let W = CGFloat(width), H = CGFloat(height)
    let px = CGRect(x: box.minX * W, y: (1 - box.maxY) * H, width: box.width * W, height: box.height * H)
    var side = max(px.width, px.height) * scale
    side = min(side, W, H)
    guard side >= 8 else { return nil }
    var x = px.midX - side / 2, y = px.midY - side / 2
    x = min(max(0, x), W - side)
    y = min(max(0, y), H - side)
    return CGRect(x: x, y: y, width: side, height: side).integral
}

func featurePrint(of image: CGImage) -> PrintData? {
    let req = VNGenerateImageFeaturePrintRequest()
    req.revision = Revisions.print
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    guard (try? handler.perform([req])) != nil, let obs = req.results?.first else { return nil }
    return PrintData(obs, revision: Revisions.print)
}

func analyze(_ input: InputImage) -> Analysis {
    var result = Analysis(input: input)
    let start = DispatchTime.now().uptimeNanoseconds
    autoreleasepool {
        guard let image = loadImage(input.url) else {
            result.error = "cannot read file"
            return
        }
        result.width = image.width
        result.height = image.height
        let classify = VNClassifyImageRequest()
        classify.revision = Revisions.classify
        let print = VNGenerateImageFeaturePrintRequest()
        print.revision = Revisions.print
        let faces = VNDetectFaceRectanglesRequest()
        faces.revision = Revisions.faces
        let animals = VNRecognizeAnimalsRequest()
        animals.revision = Revisions.animals
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([classify, print, faces, animals])
        } catch {
            result.error = "vision: \(error.localizedDescription)"
            return
        }
        result.labels = (classify.results ?? []).filter { $0.confidence >= labelThreshold }.map { ($0.identifier, $0.confidence) }
        if let obs = print.results?.first { result.print = PrintData(obs, revision: Revisions.print) }

        let faceObs = faces.results ?? []
        var qualityList: [VNFaceObservation] = []
        if !faceObs.isEmpty {
            let quality = VNDetectFaceCaptureQualityRequest()
            quality.revision = Revisions.quality
            quality.inputFaceObservations = faceObs
            if (try? handler.perform([quality])) != nil { qualityList = quality.results ?? [] }
        }
        for (i, face) in faceObs.enumerated() {
            let match = qualityList.first { $0.uuid == face.uuid }
                ?? qualityList.first { $0.boundingBox == face.boundingBox }
                ?? (qualityList.count == faceObs.count ? qualityList[i] : nil)
            let q = match?.faceCaptureQuality.map { Float(truncating: $0 as NSNumber) }
            var printData: PrintData?
            var cropPx = 0
            if let rect = cropRect(face.boundingBox, width: image.width, height: image.height, scale: 1.3), let crop = image.cropping(to: rect) {
                cropPx = Int(rect.width)
                printData = featurePrint(of: crop)
            }
            result.faces.append(FaceResult(box: face.boundingBox, confidence: face.confidence, quality: q,
                                           roll: face.roll?.floatValue, yaw: face.yaw?.floatValue, cropPx: cropPx, print: printData))
        }
        for animal in animals.results ?? [] {
            guard let top = animal.labels.first else { continue }
            var printData: PrintData?
            var cropPx = 0
            if let rect = cropRect(animal.boundingBox, width: image.width, height: image.height, scale: 1.1), let crop = image.cropping(to: rect) {
                cropPx = Int(rect.width)
                printData = featurePrint(of: crop)
            }
            result.animals.append(AnimalResult(label: top.identifier, confidence: top.confidence, box: animal.boundingBox, cropPx: cropPx, print: printData))
        }
    }
    result.ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    return result
}
