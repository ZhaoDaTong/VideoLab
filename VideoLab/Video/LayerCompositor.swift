//
//  LayerCompositor.swift
//  VideoLab
//
//  Created by Bear on 2020/8/15.
//  Copyright (c) 2020 Chocolate. All rights reserved.
//

import AVFoundation

class LayerCompositor {
    let passthrough = Passthrough()
    let yuvToRGBConversion = YUVToRGBConversion()
    let blendOperation = BlendOperation()

    // MARK: - Public
    func renderPixelBuffer(_ pixelBuffer: CVPixelBuffer, for request: AVAsynchronousVideoCompositionRequest) {
        // 提取出request中videoCompositionInstruction信息
        guard let instruction = request.videoCompositionInstruction as? VideoCompositionInstruction else {
            return
        }
        // 使用pixelBuffer生成一个metal 纹理
        guard let outputTexture = Texture.makeTexture(pixelBuffer: pixelBuffer) else {
            return
        }
        // 异常时清除纹理
        guard instruction.videoRenderLayers.count > 0 else {
            Texture.clearTexture(outputTexture)
            return
        }

        // 遍历instruction中所有的layers，并进行绘制
        for (index, videoRenderLayer) in instruction.videoRenderLayers.enumerated() {
            autoreleasepool {
                // The first output must be disabled for reading, because newPixelBuffer is taken from the buffer pool, it may be the previous pixelBuffer 第一个输出必须被禁止读取，因为newPixelBuffer是从缓冲池中取出的，它可能是前一个pixelBuffer
                let enableOutputTextureRead = (index != 0)
                renderLayer(videoRenderLayer, outputTexture: outputTexture, enableOutputTextureRead: enableOutputTextureRead, for: request)
            }
        }
    }
    
    // MARK: - Private
    private func renderLayer(_ videoRenderLayer: VideoRenderLayer,
                     outputTexture: Texture?,
                     enableOutputTextureRead: Bool,
                     for request: AVAsynchronousVideoCompositionRequest) {
        guard let outputTexture = outputTexture else {
            return
        }

        // Convert composite time to internal layer time 当前帧时间减去layer的开始时间，得到animation的当前时间（animation的时间都是基于layer的）
        let layerInternalTime = request.compositionTime - videoRenderLayer.timeRangeInTimeline.start
        
        // Update keyframe animation values 更新动画时间
        videoRenderLayer.renderLayer.updateAnimationValues(at: layerInternalTime)
        
        // Texture layer: layer source contains video track, layer source is image, layer group
        // The steps to render the texture layer
        // Step 1: Handle its own operations
        // Step 2: Blend with the previous output texture. The previous output texture is a read back renderbuffer
        func renderTextureLayer(_ sourceTexture: Texture) {
            // 在sourceTexture上应用效果
            for operation in videoRenderLayer.renderLayer.operations {
                autoreleasepool {
                    if operation.shouldInputSourceTexture, let clonedSourceTexture = cloneTexture(from: sourceTexture) {
                        operation.addTexture(clonedSourceTexture, at: 0)
                        operation.renderTexture(sourceTexture)
                        clonedSourceTexture.unlock()
                    } else {
                        operation.renderTexture(sourceTexture)
                    }
                }
            }
            
            // 把sourceTexture叠加到outputTexture上，会传入配置信息（叠加模式，叠加intensity，transform）
            blendOutputText(outputTexture,
                            with: sourceTexture,
                            blendMode: videoRenderLayer.renderLayer.blendMode,
                            blendOpacity: videoRenderLayer.renderLayer.blendOpacity,
                            transform: videoRenderLayer.renderLayer.transform,
                            enableOutputTextureRead: enableOutputTextureRead)
        }
        
        // 判断当前layer是否为layerGroup
        if let videoRenderLayerGroup = videoRenderLayer as? VideoRenderLayerGroup {
            // Layer group
            let textureWidth = outputTexture.width
            let textureHeight = outputTexture.height
            // 根据纹理宽高创建纹理
            guard let groupTexture = sharedMetalRenderingDevice.textureCache.requestTexture(width: textureWidth, height: textureHeight) else {
                return
            }
            // 纹理锁定
            groupTexture.lock()
            
            // Filter layers that intersect with the composite time. Iterate through intersecting layers to render each layer
            // 根据当前时间，得到包含此时间的所有layer
            let intersectingVideoRenderLayers = videoRenderLayerGroup.videoRenderLayers.filter { $0.timeRangeInTimeline.containsTime(request.compositionTime) }
            // 遍历layer数组，在groupTexture上进行绘制，最终layerGroup所有layer信息都绘制到了groupTexture上
            for (index, subVideoRenderLayer) in intersectingVideoRenderLayers.enumerated() {
                autoreleasepool {
                    // The first output must be disabled for reading, because groupTexture is taken from the texture cache, it may be the previous texture
                    let enableOutputTextureRead = (index != 0)
                    renderLayer(subVideoRenderLayer, outputTexture: groupTexture, enableOutputTextureRead: enableOutputTextureRead, for: request)
                }
            }
            // 绘制groupTexture到outputTexture上
            renderTextureLayer(groupTexture)
            // 纹理解锁
            groupTexture.unlock()
        } else if videoRenderLayer.trackID != kCMPersistentTrackID_Invalid {
            // Texture layer source contains a video track
            // 当前layer为videoLayer
            // 得到当前视频track此时的pixelBuffer
            guard let pixelBuffer = request.sourceFrame(byTrackID: videoRenderLayer.trackID) else {
                return
            }
            // pixelBuffer转换为纹理（YUV转为bgra）
            guard let videoTexture = bgraVideoTexture(from: pixelBuffer,
                                                      preferredTransform: videoRenderLayer.preferredTransform) else {
                return
            }
            // 绘制videoTexture到outputTexture上
            renderTextureLayer(videoTexture)
            if videoTexture.textureRetainCount > 0 {
                // Lock is invoked in the bgraVideoTexture method
                videoTexture.unlock()
            }
        } else if let sourceTexture = videoRenderLayer.renderLayer.source?.texture(at: layerInternalTime) {
            // Texture layer source is a image
            // 当前layer为image Layer
            // 拷贝当前图片texture
            guard let imageTexture = cloneTexture(from: sourceTexture) else {
                return
            }
            
            // 绘制imageTexture到outputTexture上
            renderTextureLayer(imageTexture)
            // Lock is invoked in the imageTexture method
            imageTexture.unlock()
        } else {
            // Layer without texture. All operations of the layer are applied to the previous output texture
            // layer不存在texture，layer为其他操作layer（处理效果）
            for operation in videoRenderLayer.renderLayer.operations {
                autoreleasepool {
                    if operation.shouldInputSourceTexture, let clonedOutputTexture = cloneTexture(from: outputTexture) {
                        operation.addTexture(clonedOutputTexture, at: 0)
                        operation.renderTexture(outputTexture)
                        clonedOutputTexture.unlock()
                    } else {
                        operation.renderTexture(outputTexture)
                    }
                }
            }
        }
    }

    
    /// PixelBuffer转为纹理，涉及YUV转RGBA
    /// - Parameters:
    ///   - pixelBuffer: 输入源
    ///   - preferredTransform: transform
    /// - Returns: 纹理对象
    private func bgraVideoTexture(from pixelBuffer: CVPixelBuffer, preferredTransform: CGAffineTransform) -> Texture? {
        var videoTexture: Texture?
        // 得到输入源宽高
        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        
        // 得到输入源数据类型
        let pixelFormatType = CVPixelBufferGetPixelFormatType(pixelBuffer);
        // 格式为YUV时，需进行YUV转RGBA纹理
        if pixelFormatType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || pixelFormatType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            // 根据输入源数据，创建亮度纹理及色度纹理
            let luminanceTexture = Texture.makeTexture(pixelBuffer: pixelBuffer, pixelFormat: .r8Unorm, width:bufferWidth, height: bufferHeight, plane: 0)
            let chrominanceTexture = Texture.makeTexture(pixelBuffer: pixelBuffer, pixelFormat: .rg8Unorm, width: bufferWidth / 2, height: bufferHeight / 2, plane: 1)
            if let luminanceTexture = luminanceTexture, let chrominanceTexture = chrominanceTexture {
                let videoTextureSize = CGSize(width: bufferWidth, height: bufferHeight).applying(preferredTransform)
                let videoTextureWidth = abs(Int(videoTextureSize.width))
                let videoTextureHeight = abs(Int(videoTextureSize.height))
                // 创建最终的视频纹理
                videoTexture = sharedMetalRenderingDevice.textureCache.requestTexture(width: videoTextureWidth, height: videoTextureHeight)
                if let videoTexture = videoTexture {
                    videoTexture.lock()
                    // 根据视频格式得到转换矩阵
                    let colorConversionMatrix = pixelFormatType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? YUVToRGBConversion.colorConversionMatrixVideoRange : YUVToRGBConversion.colorConversionMatrixFullRange
                    yuvToRGBConversion.colorConversionMatrix = colorConversionMatrix
                    let orientationMatrix = preferredTransform.normalizeOrientationMatrix()
                    // 绑定纹理并进行绘制
                    yuvToRGBConversion.orientation = orientationMatrix
                    yuvToRGBConversion.addTexture(luminanceTexture, at: 0)
                    yuvToRGBConversion.addTexture(chrominanceTexture, at: 1)
                    yuvToRGBConversion.renderTexture(videoTexture)
                }
            }
        } else {
            videoTexture = Texture.makeTexture(pixelBuffer: pixelBuffer)
        }
        return videoTexture
    }
    
    
    /// 拷贝纹理
    /// - Parameter sourceTexture: 输入的纹理
    /// - Returns: 拷贝的纹理
    private func cloneTexture(from sourceTexture: Texture) -> Texture? {
        let textureWidth = sourceTexture.width
        let textureHeight = sourceTexture.height
    
        guard let cloneTexture = sharedMetalRenderingDevice.textureCache.requestTexture(width: textureWidth, height: textureHeight) else {
            return nil
        }
        cloneTexture.lock()
        
        passthrough.addTexture(sourceTexture, at: 0)
        passthrough.renderTexture(cloneTexture)
        return cloneTexture
    }
    
    /// 进行纹理叠加
    private func blendOutputText(_ outputTexture: Texture,
                                 with texture: Texture,
                                 blendMode: BlendMode,
                                 blendOpacity: Float,
                                 transform: Transform,
                                 enableOutputTextureRead: Bool) {
        // Generate model, view, projection matrix
        let renderSize = CGSize(width: outputTexture.width, height: outputTexture.height)
        let textureSize = CGSize(width: texture.width, height: texture.height)
        // 配置transfrom转换矩阵及原始矩阵
        let modelViewMatrix = transform.modelViewMatrix(textureSize: textureSize, renderSize: renderSize)
        let projectionMatrix = transform.projectionMatrix(renderSize: renderSize)
        
        // Update blend parameters
        blendOperation.modelView = modelViewMatrix
        blendOperation.projection = projectionMatrix
        blendOperation.blendMode = blendMode
        blendOperation.blendOpacity = blendOpacity
        
        // Render
        blendOperation.enableOutputTextureRead = enableOutputTextureRead
        blendOperation.addTexture(texture, at: 0)
        blendOperation.renderTexture(outputTexture)
    }
}

