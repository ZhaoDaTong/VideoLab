//
//  VideoLab.swift
//  VideoLab
//
//  Created by Bear on 2020/8/22.
//  Copyright (c) 2020 Chocolate. All rights reserved.
//

import AVFoundation

public class VideoLab {
    public private(set) var renderComposition: RenderComposition
    
    private var videoRenderLayers: [VideoRenderLayer] = []
    private var audioRenderLayersInTimeline: [AudioRenderLayer] = []
    
    private var composition: AVComposition?
    private var videoComposition: AVMutableVideoComposition?
    private var audioMix: AVAudioMix?

    // MARK: - Public
    public init(renderComposition: RenderComposition) {
        self.renderComposition = renderComposition
    }
    
    public func makePlayerItem() -> AVPlayerItem {
        let composition = makeComposition()
        let playerItem = AVPlayerItem(asset: composition)
        playerItem.videoComposition = makeVideoComposition()
        playerItem.audioMix = makeAudioMix()
        return playerItem
    }
    
    public func makeImageGenerator() -> AVAssetImageGenerator {
        let composition = makeComposition()
        let imageGenerator = AVAssetImageGenerator(asset: composition)
        imageGenerator.videoComposition = makeVideoComposition()
        return imageGenerator
    }
    
    public func makeExportSession(presetName: String, outputURL: URL) -> AVAssetExportSession? {
        let composition = makeComposition()
        let exportSession = AVAssetExportSession(asset: composition, presetName: presetName)
        let videoComposition = makeVideoComposition()
        videoComposition.animationTool = makeAnimationTool()
        exportSession?.videoComposition = videoComposition
        exportSession?.audioMix = makeAudioMix()
        exportSession?.outputURL = outputURL
        exportSession?.outputFileType = AVFileType.mp4
        return exportSession
    }
    
    // MARK: - Private
    private func makeComposition() -> AVComposition {
        // TODO: optimize make performance, like return when exist
        let composition = AVMutableComposition()
        self.composition = composition
        
        // Increase track ID
        var increasementTrackID: CMPersistentTrackID = 0
        func increaseTrackID() -> Int32 {
            let trackID = increasementTrackID + 1
            increasementTrackID = trackID
            return trackID
        }

        // Step 1: Add video tracks 增加视频track数组
        
        // Substep 1: Generate videoRenderLayers sorted by start time. 为所有的视频renderLayer根据开始时间进行排序
        // A videoRenderLayer can contain video tracks or the source of the layer is ImageSource. 根据renderLayer 创建 VideoRenderLayer
        videoRenderLayers = renderComposition.layers.filter {
            $0.canBeConvertedToVideoRenderLayer()
        }.sorted {
            CMTimeCompare($0.timeRange.start, $1.timeRange.start) < 0
        }.compactMap {
            VideoRenderLayer.makeVideoRenderLayer(renderLayer: $0)
        }

        // Generate video track ID. This inline method is used in substep 2.
        // You can reuse the track ID if there is no intersection with some of the previous, otherwise increase an ID.
        var videoTrackIDInfo: [CMPersistentTrackID: CMTimeRange] = [:]
        func generateVideoTrackID(for layer: VideoRenderLayer) -> CMPersistentTrackID {
            var videoTrackID: CMPersistentTrackID?
            for (trackID, timeRange) in videoTrackIDInfo {
                if layer.timeRangeInTimeline.start > timeRange.end {
                    videoTrackID = trackID
                    videoTrackIDInfo[trackID] = layer.timeRangeInTimeline
                    break
                }
            }
            
            if let videoTrackID = videoTrackID {
                return videoTrackID
            } else {
                let videoTrackID = increaseTrackID()
                videoTrackIDInfo[videoTrackID] = layer.timeRangeInTimeline
                return videoTrackID
            }
        }
        
        // Substep 2: Add all VideoRenderLayer tracks from the timeline to the composition. 将所有videoRenderLayer增加到视频时间线数组中
        // Calculate minimum start time and maximum end time for substep 3. 计算开始时间及结束时间
        var videoRenderLayersInTimeline: [VideoRenderLayer] = []
        videoRenderLayers.forEach { videoRenderLayer in
            if let videoRenderLayerGroup = videoRenderLayer as? VideoRenderLayerGroup {
                videoRenderLayersInTimeline += videoRenderLayerGroup.recursiveVideoRenderLayers()
            } else {
                videoRenderLayersInTimeline.append(videoRenderLayer)
            }
        }
        
        // 计算开始时间及结束时间
        let minimumStartTime = videoRenderLayersInTimeline.first?.timeRangeInTimeline.start
        var maximumEndTime = videoRenderLayersInTimeline.first?.timeRangeInTimeline.end
        
        // 将视频时间线数组中所有的videoRenderLayer中的视频track增加到 composition 中
        videoRenderLayersInTimeline.forEach { videoRenderLayer in
            if videoRenderLayer.renderLayer.source?.tracks(for: .video).first != nil {
                // 初始化trackID
                let trackID = generateVideoTrackID(for: videoRenderLayer)
                // 视频track增加到 composition 中
                videoRenderLayer.addVideoTrack(to: composition, preferredTrackID: trackID)
            }
            // 更新最大时间
            if maximumEndTime! < videoRenderLayer.timeRangeInTimeline.end {
                maximumEndTime = videoRenderLayer.timeRangeInTimeline.end
            }
        }
        
        // Substep 3: Add a blank video track for image or effect layers. 为图片或者effect layer增加空的视频track，时长为时间线长度，需要一个视频文件
        // The track's duration is the same as timeline's duration.
        if let minimumStartTime = minimumStartTime, let maximumEndTime = maximumEndTime {
            let timeRange = CMTimeRange(start: minimumStartTime, end: maximumEndTime)
            let videoTrackID = increaseTrackID()
            VideoRenderLayer.addBlankVideoTrack(to: composition, in: timeRange, preferredTrackID: videoTrackID)
        }

        // Step 2: Add audio tracks 增加音频track数组
        
        // Substep 1: Generate audioRenderLayers sorted by start time. 根据RenderLayers初始化AudioRenderLayer数组
        // A audioRenderLayer must contain audio tracks.
        let audioRenderLayers = renderComposition.layers.filter {
            $0.canBeConvertedToAudioRenderLayer()
        }.sorted {
            CMTimeCompare($0.timeRange.start, $1.timeRange.start) < 0
        }.compactMap {
            AudioRenderLayer.makeAudioRenderLayer(renderLayer: $0)
        }
        
        // Substep 2: Add tracks from the timeline to the composition. 将所有AudioRenderLayer增加到音频时间线数组中
        // Since AVAudioMixInputParameters only corresponds to one track ID, the audio track ID is not reused. One audio layer corresponds to one track ID.
        audioRenderLayersInTimeline = []
        audioRenderLayers.forEach { audioRenderLayer in
            if let audioRenderLayerGroup = audioRenderLayer as? AudioRenderLayerGroup {
                audioRenderLayersInTimeline += audioRenderLayerGroup.recursiveAudioRenderLayers()
            } else {
                audioRenderLayersInTimeline.append(audioRenderLayer)
            }
        }
        // 将音频时间线数组中所有的AudioRenderLayer中的音频track增加到 composition 中
        audioRenderLayersInTimeline.forEach { audioRenderLayer in
            if audioRenderLayer.renderLayer.source?.tracks(for: .audio).first != nil {
                let trackID = increaseTrackID()
                audioRenderLayer.trackID = trackID
                audioRenderLayer.addAudioTrack(to: composition, preferredTrackID: trackID)
            }
        }
        
        return composition
    }
    
    private func makeVideoComposition() -> AVMutableVideoComposition {
        // TODO: optimize make performance, like return when exist
        
        // Convert videoRenderLayers to videoCompositionInstructions
        
        // Step 1: Put the layer start time and end time on the timeline, each interval is an instruction. Then sort by time
        // Make sure times contain zero
        var times: [CMTime] = [CMTime.zero]
        videoRenderLayers.forEach { videoRenderLayer in
            let startTime = videoRenderLayer.timeRangeInTimeline.start
            let endTime = videoRenderLayer.timeRangeInTimeline.end
            if !times.contains(startTime) {
                times.append(startTime)
            }
            if !times.contains(endTime) {
                times.append(endTime)
            }
        }
        times.sort { $0 < $1 }
        
        // Step 2: Create instructions for each interval
        var instructions: [VideoCompositionInstruction] = []
        for index in 0..<times.count - 1 {
            let startTime = times[index]
            let endTime = times[index + 1]
            let timeRange = CMTimeRange(start: startTime, end: endTime)
            var intersectingVideoRenderLayers: [VideoRenderLayer] = []
            videoRenderLayers.forEach { videoRenderLayer in
                if !videoRenderLayer.timeRangeInTimeline.intersection(timeRange).isEmpty {
                    intersectingVideoRenderLayers.append(videoRenderLayer)
                }
            }
            
            intersectingVideoRenderLayers.sort { $0.renderLayer.layerLevel < $1.renderLayer.layerLevel }
            let instruction = VideoCompositionInstruction(videoRenderLayers: intersectingVideoRenderLayers, timeRange: timeRange)
            instructions.append(instruction)
        }

        // Create videoComposition. Specify frameDuration, renderSize, instructions, and customVideoCompositorClass.
        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = renderComposition.frameDuration
        videoComposition.renderSize = renderComposition.renderSize
        videoComposition.instructions = instructions
        videoComposition.customVideoCompositorClass = VideoCompositor.self
        self.videoComposition = videoComposition
        
        return videoComposition
    }
    
    private func makeAudioMix() -> AVAudioMix? {
        // TODO: optimize make performance, like return when exist
        
        // Convert audioRenderLayers to inputParameters
        var inputParameters: [AVMutableAudioMixInputParameters] = []
        audioRenderLayersInTimeline.forEach { audioRenderLayer in
            let audioMixInputParameters = AVMutableAudioMixInputParameters()
            audioMixInputParameters.trackID = audioRenderLayer.trackID
            audioMixInputParameters.audioTimePitchAlgorithm = audioRenderLayer.pitchAlgorithm
            audioMixInputParameters.audioTapProcessor = audioRenderLayer.makeAudioTapProcessor()
            inputParameters.append(audioMixInputParameters)
        }

        // Create audioMix. Specify inputParameters.
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = inputParameters
        self.audioMix = audioMix
        
        return audioMix
    }
    
    private func makeAnimationTool() -> AVVideoCompositionCoreAnimationTool? {
        guard let animationLayer = renderComposition.animationLayer else {
            return nil
        }
        
        let parentLayer = CALayer()
        parentLayer.isGeometryFlipped = true
        let videoLayer = CALayer()
        parentLayer.frame = CGRect(origin: CGPoint.zero, size: renderComposition.renderSize)
        videoLayer.frame = CGRect(origin: CGPoint.zero, size: renderComposition.renderSize)
        parentLayer.addSublayer(videoLayer)
        parentLayer.addSublayer(animationLayer)
        
        let animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parentLayer)
        return animationTool
    }
}
