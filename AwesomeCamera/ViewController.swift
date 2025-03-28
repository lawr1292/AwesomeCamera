//
//  ViewController.swift
//  AwesomeCamera
//
//  Created by Ryan Law on 3/25/25.
//
import UIKit
import AVFoundation
import Vision
import Foundation
import CoreML

enum CameraConfigurationStatus {
    case success
    case permissionDenied
    case failed
}

public struct Box {
    public let conf: Float
    public let xywh: CGRect
    public let xywhn: CGRect
}

public struct Keypoints {
    public var xyn: [(x:Float, y:Float)]
    public var xy: [(x:Float, y:Float)]
    public let conf: [Float]
}

class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    var bufferSize: CGSize = .zero
    private var camera: AVCaptureDevice?
    private var requests = [VNRequest]()
    private let session = AVCaptureSession()
    private lazy var videoDataOutput = AVCaptureVideoDataOutput()
    var isSessionRunning: Bool = false
    private var previewLayer: AVCaptureVideoPreviewLayer! = nil
    private let sessionQueue = DispatchQueue(label: "VideoDataOutput", qos: .userInitiated, attributes: [], autoreleaseFrequency: .workItem)
    private var cameraConfigurationStatus: CameraConfigurationStatus = .failed
    var highestSupportedFrameRate = 0.0
    var highestFrameRate: CMTime? = nil
    var highestQualityFormat: AVCaptureDevice.Format? = nil
    var modelInputSize = CGSize(width: 640, height: 640)
    var ourOrientation: CGImagePropertyOrientation = {
        switch UIDevice.current.orientation {
        case .unknown:
                .up
        case .portrait:
                .up
        case .portraitUpsideDown:
                .down
        case .landscapeLeft:
                .left
        case .landscapeRight:
                .right
        case .faceUp:
                .up
        case .faceDown:
                .up
        @unknown default:
            fatalError("uknown UIDevice orientation value at init")
        }
    }()
    private var detectionOverlay: CALayer! = nil
    
    
    override func viewDidLoad() {
        super.viewDidLoad()
        attemptToStartCaptureSession()
        //listAppBundleContents()
    }
    
    //    func listAppBundleContents() {
    //        let fileManager = FileManager.default
    //        let bundleURL = Bundle.main.bundleURL
    //        do {
    //            let contents = try fileManager.contentsOfDirectory(at: bundleURL, includingPropertiesForKeys: nil, options: [])
    //            for content in contents {
    //                print("App Bundle Content: \(content.lastPathComponent)")
    //            }
    //        } catch {
    //            print("Error listing app bundle contents: \(error)")
    //        }
    //    }
    
    private func getPermissions(completion: @escaping (Bool) -> ()) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            if !granted {
                self.cameraConfigurationStatus = .permissionDenied
            } else {
                self.cameraConfigurationStatus = .success
            }
            completion(granted)
        }
    }
    
    private func attemptToStartCaptureSession() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            self.cameraConfigurationStatus = .success
        case .notDetermined:
            self.sessionQueue.suspend()
            self.getPermissions { granted in
                self.sessionQueue.resume()
            }
        case .denied:
            self.cameraConfigurationStatus = .permissionDenied
        default:
            break
        }
        
        self.sessionQueue.async {
            self.setupCaptureSession()
        }
    }
    
    private func setupCaptureSession() {
        session.beginConfiguration()
        setupInput()
        setupOutput()
        session.commitConfiguration()
        setupVision()
        setupPreviewLayer()
    }
    
    private func startCaptureSession() {
        sessionQueue.async {
            if self.cameraConfigurationStatus == .success {
                self.startSession()
            }
        }
    }
    
    private func startSession() {
        self.session.startRunning()
        self.isSessionRunning = self.session.isRunning
    }
    
    private func stopSession() {
        sessionQueue.async {
            if self.isSessionRunning {
                self.session.stopRunning()
                self.isSessionRunning = false
            }
        }
        DispatchQueue.main.async {
            self.previewLayer.removeFromSuperlayer()
            self.previewLayer = nil
        }
    }
    
    func setupLayers() {
        detectionOverlay = CALayer() // container layer that has all the renderings of the observations
        detectionOverlay.name = "DetectionOverlay"
        detectionOverlay.bounds = CGRect(x: 0.0,
                                         y: 0.0,
                                         width: bufferSize.width,
                                         height: bufferSize.height)
        detectionOverlay.position = CGPoint(x: previewLayer.bounds.midX, y: previewLayer.bounds.midY)
        previewLayer.addSublayer(detectionOverlay)
    }
    
    private func setupInput() {
        var deviceInput: AVCaptureDeviceInput!
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .front)
        
        var highestQualityDevice: AVCaptureDevice?
        
        for device in discoverySession.devices {
            for format in device.formats {
                for range in format.videoSupportedFrameRateRanges {
                    if range.maxFrameRate > highestSupportedFrameRate {
                        highestSupportedFrameRate = range.maxFrameRate
                        highestQualityDevice = device
                        highestQualityFormat = format
                        highestFrameRate = CMTime(value: 1, timescale: CMTimeScale(range.maxFrameRate))
                    }
                }
            }
        }
        
        camera = highestQualityDevice
        
        guard let camera = camera else {
            print("No camera available")
            return
        }
        
        session.sessionPreset = .high
        
        do {
            deviceInput = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(deviceInput) {
                session.addInput(deviceInput)
            } else {
                print("Could not add input")
                return
            }
        } catch {
            fatalError("Cannot create video device input")
        }
    }
    
    private func setupOutput() {
        let sampleBufferQueue = DispatchQueue(label: "SampleBufferQueue")
        videoDataOutput.setSampleBufferDelegate(self, queue: sampleBufferQueue)
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.videoSettings = [ String(kCVPixelBufferPixelFormatTypeKey) : kCVPixelFormatType_32BGRA]
        
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
        } else {
            print("Output setup error")
        }
        
        
        guard let captureConnection = videoDataOutput.connection(with: .video) else
        {
            fatalError("Capture connection failed")
        }
        captureConnection.videoRotationAngle = 0
        captureConnection.isEnabled = true

        do {
            try camera?.lockForConfiguration()
            if let format = highestQualityFormat {
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                bufferSize.width = CGFloat(dimensions.width)
                bufferSize.height = CGFloat(dimensions.height)
                camera?.activeFormat = format
                camera?.activeVideoMinFrameDuration = highestFrameRate!
                camera?.activeVideoMaxFrameDuration = highestFrameRate!
            }
            camera?.unlockForConfiguration()
        } catch {
            print("Error setting format or dimensions")
        }
    }
    
    private func setupPreviewLayer() {
        DispatchQueue.main.async {
            self.previewLayer = AVCaptureVideoPreviewLayer(session: self.session)
            self.previewLayer.frame = self.view.bounds
            self.previewLayer.videoGravity = .resizeAspectFill
            self.previewLayer.connection?.videoRotationAngle = 0
            self.view.layer.addSublayer(self.previewLayer)
            self.setupLayers()
            self.startCaptureSession()
        }
    }
    
    //    override func viewWillTransition(to size:CGSize, with coordinator:        ) {
    //        let orientation = UIDevice.current.orientation
    //
    //        switch orientation {
    //        case UIDeviceOrientation.portraitUpsideDown:
    //            self.previewLayer.connection?.videoRotationAngle = 270
    //            ourOrientation = .down
    //        case UIDeviceOrientation.landscapeLeft:
    //            self.previewLayer.connection?.videoRotationAngle = 180
    //            ourOrientation = .left
    //        case UIDeviceOrientation.landscapeRight:
    //            self.previewLayer.connection?.videoRotationAngle = 0
    //            ourOrientation = .right
    //        case UIDeviceOrientation.portrait:
    //            self.previewLayer.connection?.videoRotationAngle = 90
    //            ourOrientation = .up
    //        default:
    //            self.previewLayer.connection?.videoRotationAngle = 90
    //            ourOrientation = .up
    //
    //        }
    //
    //        self.previewLayer.frame = CGRect(x:0, y:0, width: size.width, height: size.height)
    //        setupLayers()
    //    }
    
    @discardableResult
    func setupVision() -> NSError? {
        print("Setting up vision")
        // Setup Vision parts
        let error: NSError! = nil
        
        guard let modelURL = Bundle.main.url(forResource: "best_total", withExtension: "mlmodelc") else {
            print("Model file is missing1")
            return NSError(domain: "VisionObjectRecognitionViewController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Model file is missing"])
        }
        do {
            let visionModel = try VNCoreMLModel(for: MLModel(contentsOf: modelURL))
            let objectRecognition = VNCoreMLRequest(model: visionModel) { (request, error) in
                if let results = request.results as? [VNCoreMLFeatureValueObservation], let featureValue = results.first?.featureValue {
                    if let multiArray = featureValue.multiArrayValue {
                        // multiArray is your 1 x 21 x 8400 array
                        // Call your post-processing function with the extracted array
                        let poses = self.postProcessPose(prediction: multiArray)
                        print(poses)
                        if !(poses.count == 0) {
                            self.drawVisionRequestResult(poses[0].box)
                        } else {
                            CATransaction.begin()
                            CATransaction.setValue(kCFBooleanTrue, forKey: kCATransactionDisableActions)
                            self.detectionOverlay?.sublayers = nil
                            CATransaction.commit()
                        }
                    } else {
                        print("Failed to extract MLMultiArray from featureValue")
                    }
                } else {
                    print("No results or results are not of expected type")
                }
            }
            self.requests = [objectRecognition]
            print("Vision request setup successfully")
        } catch let error as NSError {
            print("Model loading went wrong: \(error)")
        }
        
        return error
    }
    
    func postProcessPose( prediction: MLMultiArray )
    -> [(box: Box, keypoints: Keypoints)]   {
        let numAnchors = prediction.shape[2].intValue
        let featureCount = prediction.shape[1].intValue - 5
        
        var boxes = [CGRect]()
        var scores = [Float]()
        var features = [[Float]]()
        
        let featurePointer = UnsafeMutablePointer<Float>(OpaquePointer(prediction.dataPointer))
        let lock = DispatchQueue(label: "com.example.lock")
        
        DispatchQueue.concurrentPerform(iterations: numAnchors) { j in
            let confIndex = 4 * numAnchors + j
            let confidence = featurePointer[confIndex]
            
            if confidence > 0.35 {
                let x = featurePointer[j]
                let y = featurePointer[numAnchors + j]
                let width = featurePointer[2 * numAnchors + j]
                let height = featurePointer[3 * numAnchors + j]
                
                let boxWidth = CGFloat(width)
                let boxHeight = CGFloat(height)
                let boxX = CGFloat(x - width / 2.0)
                let boxY = CGFloat(y - height / 2.0)
                let boundingBox = CGRect(
                    x: boxX, y: boxY,
                    width: boxWidth, height: boxHeight)
                
                var boxFeatures = [Float](repeating: 0, count: featureCount)
                for k in 0..<featureCount {
                    let key = (5 + k) * numAnchors + j
                    boxFeatures[k] = featurePointer[key]
                }
                
                lock.sync {
                    boxes.append(boundingBox)
                    scores.append(confidence)
                    features.append(boxFeatures)
                }
            }
        }
        
        let selectedIndices = nonMaxSuppression(boxes: boxes, scores: scores, threshold: 0.5)
        
        let filteredBoxes = selectedIndices.map { boxes[$0] }
        let filteredScores = selectedIndices.map { scores[$0] }
        let filteredFeatures = selectedIndices.map { features[$0] }
        
        let boxScorePairs = zip(filteredBoxes, filteredScores)
        let results: [(Box, Keypoints)] = zip(boxScorePairs, filteredFeatures).map {
            (pair, boxFeatures) in
            let (box, score) = pair
            let Nx = box.origin.x / CGFloat(modelInputSize.width)
            let Ny = box.origin.y / CGFloat(modelInputSize.height)
            let Nw = box.size.width / CGFloat(modelInputSize.width)
            let Nh = box.size.height / CGFloat(modelInputSize.height)
            let ix = Nx * bufferSize.width
            let iy = Ny * bufferSize.height
            let iw = Nw * bufferSize.width
            let ih = Nh * bufferSize.height
            let normalizedBox = CGRect(x: Nx, y: Ny, width: Nw, height: Nh)
            let imageSizeBox = CGRect(x: ix, y: iy, width: iw, height: ih)
            let boxResult = Box(
                conf: score, xywh: imageSizeBox, xywhn: normalizedBox)
            let numKeypoints = boxFeatures.count / 3
            
            var xynArray = [(x: Float, y: Float)]()
            var xyArray = [(x: Float, y: Float)]()
            var confArray = [Float]()
            
            for i in 0..<numKeypoints {
                let kx = boxFeatures[3 * i]
                let ky = boxFeatures[3 * i + 1]
                let kc = boxFeatures[3 * i + 2]
                
                let nX = kx / Float(modelInputSize.width)
                let nY = ky / Float(modelInputSize.height)
                xynArray.append((x: nX, y: nY))
                
                let x = nX * Float(bufferSize.width)
                let y = nY * Float(bufferSize.height)
                xyArray.append((x: x, y: y))
                
                confArray.append(kc)
            }
            
            let keypoints = Keypoints(xyn: xynArray, xy: xyArray, conf: confArray)
            return (boxResult, keypoints)
        }
        
        return results
    }
    
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("Failed to get pixel buffer")
            return
        }
        
        var requestOptions: [VNImageOption: Any] = [:]
        
        if let cameraData = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil) {
            requestOptions = [.cameraIntrinsics: cameraData]
        }
        
        let imageRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .left, options: [:])
        
        do {
            try imageRequestHandler.perform(self.requests)
        } catch {
            print("Failed to perform vision request: \(error)")
        }
    }
    
    public func nonMaxSuppression(boxes: [CGRect], scores: [Float], threshold:Float) -> [Int] {
        let sortedIndicies = scores.enumerated().sorted { $0.element > $1.element }.map { $0.offset }
        
        var selectedIndicies = [Int]()
        var activeIndicies = [Bool](repeating: true, count: boxes.count)
        
        for i in 0..<sortedIndicies.count {
            let idx = sortedIndicies[i]
            if activeIndicies[idx] {
                selectedIndicies.append(idx)
                for j in i + 1..<sortedIndicies.count {
                    let otherIdx = sortedIndicies[j]
                    if activeIndicies[otherIdx] {
                        let intersection = boxes[idx].intersection(boxes[otherIdx])
                        if intersection.area > CGFloat(threshold) * min(boxes[idx].area, boxes[otherIdx].area) { activeIndicies[otherIdx] = false }
                    }
                }
            }
        }
        return selectedIndicies
    }
    
    func updateLayerGeometry() {
        let bounds = previewLayer.bounds
        var scale: CGFloat
        
        let xScale: CGFloat = bounds.size.width / bufferSize.height
        let yScale: CGFloat = bounds.size.height / bufferSize.width
        
        scale = fmax(xScale, yScale)
        if scale.isInfinite {
            scale = 1.0
        }
//        CATransaction.begin()
//        CATransaction.setValue(kCFBooleanTrue, forKey: kCATransactionDisableActions)
        
        detectionOverlay.setAffineTransform(CGAffineTransform(rotationAngle: 0.0).scaledBy(x: scale, y: scale))
        detectionOverlay.position = CGPoint(x: bounds.midX, y: bounds.midY)
        
        CATransaction.commit()
    }
    
    public func drawVisionRequestResult(_ result: Box) {
        //let drawing = CGRect(x: result.xywh.midX-result.xywh.width/2, y: result.xywh.midY-result.xywh.height/2, width: result.xywh.width, height: result.xywh.height) // Static rectangle for demonstration
        let drawing = CGRect(x: detectionOverlay.bounds.midX-75, y: detectionOverlay.bounds.midY-37, width: 150, height: 75) // Static rectangle for demonstration
        
        CATransaction.begin()
        CATransaction.setValue(kCFBooleanTrue, forKey: kCATransactionDisableActions)
        detectionOverlay?.sublayers = nil
        let shapeLayer = createRoundedRectLayerWithBounds(drawing)
        
        detectionOverlay?.addSublayer(shapeLayer)
        self.updateLayerGeometry()
        
        CATransaction.commit()
    }
    
    func createRoundedRectLayerWithBounds(_ bounds: CGRect) -> CALayer {
        let shapeLayer = CALayer()
        shapeLayer.bounds = bounds
        shapeLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        shapeLayer.name = "Found Object"
        shapeLayer.backgroundColor = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [1.0, 0.5, 0.2, 0.4])
        shapeLayer.cornerRadius = 3
        return shapeLayer
    }
    
}

extension CGRect {
    var area: CGFloat { return width * height }
}


