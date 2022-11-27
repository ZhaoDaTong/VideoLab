//
//  RenderLayer.swift
//  VideoLab
//
//  Created by Bear on 2020/8/29.
//  Copyright © 2020 Chocolate. All rights reserved.
//

import AVFoundation

public class RenderLayer: Animatable {
    public var timeRange: CMTimeRange

    public var layerLevel: Int = 0
    public var transform: Transform = Transform.identity
    public var blendMode: BlendMode = BlendModeNormal
    public var blendOpacity: Float = 1.0
    public var operations: [BasicOperation] = []
    
    public var audioConfiguration: AudioConfiguration = AudioConfiguration()
    
    let source: Source?

    public init(timeRange: CMTimeRange, source: Source? = nil) {
        self.timeRange = timeRange
        self.source = source
    }
    
    // MARK: - Animatable
    public var animations: [KeyframeAnimation]?
    public func updateAnimationValues(at time: CMTime) {
        // 更新blendOpacity 参数
        if let blendOpacity = KeyframeAnimation.value(for: "blendOpacity", at: time, animations: animations) {
            self.blendOpacity = blendOpacity
        }
        // 更新trasfrom动画
        transform.updateAnimationValues(at: time)
        
        // 更新operation 参数
        for operation in operations {
            let operationStartTime = operation.timeRange?.start ?? CMTime.zero
            let operationInternalTime = time - operationStartTime
            operation.updateAnimationValues(at: operationInternalTime)
        }
    }
}
