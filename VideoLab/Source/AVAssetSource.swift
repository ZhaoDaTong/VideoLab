//
//  AVAssetSource.swift
//  VideoLab
//
//  Created by Bear on 2020/8/29.
//

import AVFoundation

public class AVAssetSource: Source {
    private var asset: AVAsset?
    
    public init(asset: AVAsset) {
        self.asset = asset
        selectedTimeRange = CMTimeRange.zero
        duration = CMTime.zero
        size = CGSize.zero
    }
    
    // MARK: - Source
    public var selectedTimeRange: CMTimeRange
    
    public var duration: CMTime
    
    public var size: CGSize
    
    public var isLoaded: Bool = false
    
    public func copy() -> Source {
        let source = AVAssetSource.init(asset: self.asset!)
        source.selectedTimeRange = CMTimeRange.zero
        source.duration = CMTime.zero
        source.isLoaded = false
        source.size = self.size
        return source
    }
    
    public func load(completion: @escaping (NSError?) -> Void) {
        guard let asset = asset else {
            let error = NSError(domain: "com.source.load",
                                code: 0,
                                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Asset is nil", comment: "")])
            completion(error)
            return
        }

        asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) { [weak self] in
            guard let self = self else { return }
            
            defer {
                self.isLoaded = true
            }
            
            var error: NSError?
            let tracksStatus = asset.statusOfValue(forKey: "tracks", error: &error)
            if tracksStatus != .loaded {
                DispatchQueue.main.async {
                    completion(error)
                }
            }
            
            let durationStatus = asset.statusOfValue(forKey: "duration", error: &error)
            if durationStatus != .loaded {
                DispatchQueue.main.async {
                    completion(error)
                }
            }
            
            if let videoTrack = self.tracks(for: .video).first {
                // Make sure source's duration not beyond video track's duration
                self.duration = videoTrack.timeRange.duration
                self.size = videoTrack.naturalSize
            } else {
                self.duration = asset.duration
            }
            self.selectedTimeRange = CMTimeRangeMake(start: CMTime.zero, duration: self.duration)
            DispatchQueue.main.async {
                completion(nil)
            }
        }
    }
    
    public func tracks(for type: AVMediaType) -> [AVAssetTrack] {
        guard let asset = asset else { return [] }
        return asset.tracks(withMediaType: type)
    }
}
