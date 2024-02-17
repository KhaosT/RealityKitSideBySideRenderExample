//
//  VideoPlaybackViewModel.swift
//  SBSVideoExp
//
//  Created by Khaos Tian on 2/15/24.
//

import AVKit
import CoreVideo
import Foundation
import Metal
import RealityFoundation
import RealityKit
import Observation

@Observable
final class VideoPlaybackViewModel {

    private let renderQueue = DispatchQueue(label: "render")

    private var mtlDevice: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var drawableQueue: TextureResource.DrawableQueue?

    private(set) var surfaceMaterial: ShaderGraphMaterial?
    private var textureResource: TextureResource?

    private var player: AVPlayer?
    private var statusObservation: NSKeyValueObservation?
    private var playerVideoOutput: AVPlayerItemVideoOutput?
    private var displayLink: DisplayLink?
    private var textureCache: CVMetalTextureCache?

    init() {
        let device = MTLCreateSystemDefaultDevice()
        self.mtlDevice = device

        if let device {
            commandQueue = device.makeCommandQueue()
        }

        let res = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            mtlDevice!,
            nil,
            &textureCache
        )

        if res != kCVReturnSuccess {
            fatalError("Failed to create texture cache")
        }
    }

    @MainActor
    func loadShaderMaterial() async {
        var material = try! await ShaderGraphMaterial(
            named: "/Root/SBSMaterial",
            from: "SBSMaterial.usda"
        )

        /// Dummy data to create the texture resource
        let data = Data([0x00, 0x00, 0x00, 0xFF])

        let textureResource = try! await TextureResource(
            dimensions: .dimensions(width: 1, height: 1),
            format: .raw(pixelFormat: .bgra8Unorm),
            contents: .init(
                mipmapLevels: [
                    .mip(data: data, bytesPerRow: 4),
                ]
            )
        )

        self.textureResource = textureResource

        try! material.setParameter(
            name: "texture",
            value: .textureResource(textureResource)
        )

        self.surfaceMaterial = material
    }

    func play() {
        guard player == nil else {
            return
        }

        guard let url = Bundle.main.url(forResource: "Demo", withExtension: "mp4") else {
            fatalError("Unable to locate the Demo movie file, make sure you supple it.")
        }

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player

        statusObservation = item.observe(\.status) { [weak self] item, value in
            if item.status == .readyToPlay {
                self?.handleReadyToPlay(item)
            }
        }
    }

    func stop() {
        player?.pause()

        surfaceMaterial = nil
        textureResource = nil
        drawableQueue = nil
        statusObservation = nil
        playerVideoOutput = nil
        displayLink = nil
        player = nil
    }

    private func handleReadyToPlay(_ item: AVPlayerItem) {
        NSLog("Ready")

        let videoOutput = AVPlayerItemVideoOutput(
            pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ]
        )
        self.playerVideoOutput = videoOutput

        item.add(videoOutput)

        guard let videoTrack = item.tracks.first(where: { $0.assetTrack?.mediaType == .video })?.assetTrack else {
            fatalError("Unable to find video track")
        }

        Task { @MainActor in
            let frameRate = try await videoTrack.load(.nominalFrameRate)

            let displayLink = DisplayLink(frameRate: frameRate)
            displayLink.handler = { [weak self] in
                self?.handleDisplayLinkUpdate()
            }
            displayLink.start()

            player?.play()
        }
    }

    private func handleDisplayLinkUpdate() {
        guard let playerVideoOutput else {
            return
        }

        renderQueue.async {
            let itemTime = playerVideoOutput.itemTime(forHostTime: CACurrentMediaTime())
            if playerVideoOutput.hasNewPixelBuffer(forItemTime: itemTime) {
                if let buffer = playerVideoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                    self.processVideoBuffer(buffer)
                }
            }
        }
    }

    private func processVideoBuffer(_ buffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)

        if let drawableQueue, 
            drawableQueue.width == width,
           drawableQueue.height == height {
            renderWithDrawableQueue(drawableQueue, buffer: buffer)
        } else {
            do {
                let drawableQueue = try TextureResource.DrawableQueue(
                    TextureResource.DrawableQueue.Descriptor(
                        pixelFormat: .bgra8Unorm,
                        width: width,
                        height: height,
                        usage: [.renderTarget, .shaderRead, .shaderWrite],
                        mipmapsMode: .none
                    )
                )
                self.drawableQueue = drawableQueue

                DispatchQueue.main.sync {
                    textureResource!.replace(withDrawables: drawableQueue)
                }

                renderWithDrawableQueue(drawableQueue, buffer: buffer)
            } catch {
                NSLog("Failed to create drawable queue")
            }
        }
    }

    private func renderWithDrawableQueue(_ drawableQueue: TextureResource.DrawableQueue, buffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)

        do {
            var textureOut: CVMetalTexture?

            let res = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache!,
                buffer,
                nil,
                .bgra8Unorm,
                width,
                height,
                0,
                &textureOut
            )

            guard res == kCVReturnSuccess,
                  let textureOut,
                  let metalTexture = CVMetalTextureGetTexture(textureOut) else {
                NSLog("Failed to generate texture")
                return
            }

            let drawable = try drawableQueue.nextDrawable()

            guard let commandBuffer = commandQueue?.makeCommandBuffer() else {
                return
            }

            guard let blitCommandEncoder = commandBuffer.makeBlitCommandEncoder() else {
                return
            }

            blitCommandEncoder.copy(from: metalTexture, to: drawable.texture)
            blitCommandEncoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            drawable.present()
        } catch {
            NSLog("Failed: \(error)")
        }
    }

    private class DisplayLink: NSObject {

        private let frameRate: Float

        private var internalDisplayLink: CADisplayLink?
        var handler: (() -> Void)?

        init(frameRate: Float) {
            self.frameRate = frameRate
            super.init()
        }

        deinit {
            stop()
        }

        func start() {
            internalDisplayLink?.invalidate()

            internalDisplayLink = CADisplayLink(
                target: self,
                selector: #selector(displayLinkFired)
            )
            internalDisplayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: frameRate, maximum: frameRate)
            internalDisplayLink?.add(to: .main, forMode: .common)
        }

        func stop() {
            internalDisplayLink?.invalidate()
            internalDisplayLink = nil
        }

        @objc
        private func displayLinkFired() {
            handler?()
        }
    }
}
