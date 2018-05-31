//
//  AnimatedImage.swift
//  AnimatedImageKit
//
//  Created by 陆俊杰 on 2018/5/18.
//

import UIKit
import ImageIO
import MobileCoreServices

public class AnimatedImage {
    public enum FrameCacheCountPolicy: Int {
        // 0 means no specific limit
        case noLimit = 0
        // The minimum frame cache size; this will produce frames on-demand.
        case lowMemory = 1
        // If we can produce the frames faster than we consume, one frame ahead will already result in a stutter-free playback.
        case growAfterMemoryWarning = 2
        // Build up a comfy buffer window to cope with CPU hiccups etc.
        case `default` = 5
    }
    
    public enum ImageDataSizeCategory: CGFloat {
        // All frames permanently in memory (be nice to the CPU)
        case all = 10
        // A frame cache of default size in memory (usually real-time performance and keeping low memory profile)
        case `default` = 75
        // Only keep one frame at the time in memory (easier on memory, slowest performance)
        case onDemand = 250
        // Even for one frame too large, computer says no.
        case unsupported
    }
    
    static private let serialQueue = DispatchQueue(label: "com.animatedkit.framecachingqueue")
    
    
    /// The initialized image data.
    public let data: Data
    
    /// The first frame image, usually equivalent to ```imageLazilyCached(at :0)```.
    public var posterImage: UIImage?
    /// Index of poster image.
    public var posterImageFrameIndex: Int?
    
    /// The animation loop count, 0 means repeating the animation indefinitely.
    public var loopCount: Int
    /// Number of valid image frames.
    public var frameCount: Int
    /// In animated image animation, each frame will be presented with a display duration.
    public var delayTimes = [Int: CGFloat]()
    
    /// The optimal count of frames to cache based on image size and number of frames.
    public let optimalFrameCacheCount: Int
    /// The max frame cache count, 0 means no specific limit (default)
    public var frameCacheCountMax: FrameCacheCountPolicy = .noLimit {
        didSet {
            if frameCacheCountMax != oldValue {
                // If the new cap will cause the current cache size to shrink, then we'll make sure to purge from the cache if needed.
                if frameCacheCountMax.rawValue < self.currentFrameCacheCount {
                    self.cleanFrameCacheIfNeeded()
                }
            }
        }
    }
    
    private var cachedFrames = [Int: UIImage]()
    private var cachedFrameIndexes: IndexSet {
        return IndexSet(cachedFrames.keys)
    }
    private var cachingFrameIndexes = IndexSet()
    
    private let predrawingEnabled: Bool
    private let imageSource: CGImageSource
    
    private let minimumDelayTimeInterval = 0.02
    
    // MARK: Life Cycle
    public init?(animatedImageData: Data,
                 optimalFrameCacheCount: FrameCacheCountPolicy = .noLimit,
                 predrawingEnabled: Bool = true) {
        guard animatedImageData.count > 0,
            let rawImageSource = CGImageSourceCreateWithData(animatedImageData as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let imageSourceContainerType = CGImageSourceGetType(rawImageSource),
            UTTypeConformsTo(imageSourceContainerType, kUTTypeGIF) else {
            return nil
        }
        
        self.data = animatedImageData
        self.predrawingEnabled = predrawingEnabled
        self.imageSource = rawImageSource
        
        let imageProperties = CGImageSourceCopyProperties(rawImageSource, nil) as? [String: Any]
        let gifPropertyKey = kCGImagePropertyGIFDictionary as String
        let loopCountPropertyKey = kCGImagePropertyGIFLoopCount as String
        
        self.loopCount = (imageProperties?[gifPropertyKey] as? [String: Any])?[loopCountPropertyKey] as? Int ?? 0
        
        self.frameCount = CGImageSourceGetCount(rawImageSource)
        
        var skippedFrameCount = 0
        
        // Loop to initialize poster and delayTimes.
        for index in 0..<frameCount {
            if let frameCGImage = CGImageSourceCreateImageAtIndex(rawImageSource, index, nil) {
                let frameImage = UIImage(cgImage: frameCGImage)
                // Check for valid `frameImage` before parsing its properties as frames can be corrupted (and `frameImage` even `nil` when `frameImageRef` was valid).
                // Set poster image
                if self.posterImage == nil {
                    self.posterImage = frameImage
                    // Remember index of poster image so we never purge it; also add it to the cache.
                    self.posterImageFrameIndex = index
                    // We need to cache poster image since it will certainly display.
                    self.cachedFrames[index] = frameImage
                }
                
                // Get `DelayTime`
                // Note: It's not in (1/100) of a second like still falsely described in the documentation as per iOS 8 (rdar://19507384) but in seconds stored as `kCFNumberFloat32Type`.
                // Frame properties example:
                // {
                //     ColorModel = RGB;
                //     Depth = 8;
                //     PixelHeight = 960;
                //     PixelWidth = 640;
                //     "{GIF}" = {
                //         DelayTime = "0.4";
                //         UnclampedDelayTime = "0.4";
                //     };
                // }
                let frameProperties = CGImageSourceCopyPropertiesAtIndex(rawImageSource, index, nil) as? [String: Any]
                let gifFrameProperties = frameProperties?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
                
                // If we don't get a delay time from the properties, fall back to defaultDelayInterval or carry over the preceding frame's value.
                let defaultDelayInterval = index == 0 ? 0.1 : (delayTimes[index - 1] ?? 0.1)
                // Try to use the unclamped delay time; fall back to the normal delay time.
                var delayTime = gifFrameProperties?[kCGImagePropertyGIFUnclampedDelayTime as String] as? CGFloat ?? gifFrameProperties?[kCGImagePropertyGIFDelayTime as String] as? CGFloat ?? defaultDelayInterval
                
                // Support frame delays as low as `minimumDelayTimeInterval`, with anything below being rounded up to `minimumDelayTimeInterval` for legacy compatibility.
                // To support the minimum even when rounding errors occur, use an epsilon when comparing. We downcast to float because that's what we get for delayTime from ImageIO.
                let minimumDelayTimeInterval: CGFloat = 0.02
                if delayTime < minimumDelayTimeInterval - CGFloat(Float.ulpOfOne) {
                    delayTime = defaultDelayInterval
                }
                delayTimes[index] = delayTime
            } else {
                skippedFrameCount += 1
            }
        }
        
        guard frameCount > 0, let poster = self.posterImage else {
            return nil
        }
        
        let frameCacheCount: Int
        // If no value is provided, select a default based on the GIF.
        if optimalFrameCacheCount == .noLimit {
            // Calculate the optimal frame cache count: try choosing a larger buffer window depending on the predicted image size.
            // It's only dependent on the image size & number of frames and never changes.
            let megaByte: CGFloat = (1024 * 1024)
            let posterBytesPerRow = CGFloat(poster.cgImage?.bytesPerRow ?? 0)
            let posterHeight = poster.size.height
            let realFrameCount = CGFloat(self.frameCount - skippedFrameCount)
            let animatedImageDataSize = posterBytesPerRow * posterHeight * realFrameCount / megaByte
            
            if animatedImageDataSize <= ImageDataSizeCategory.all.rawValue {
                frameCacheCount = self.frameCount
            } else if animatedImageDataSize <= ImageDataSizeCategory.default.rawValue {
                // This value doesn't depend on device memory much because if we're not keeping all frames in memory we will always be decoding 1 frame up ahead per 1 frame that gets played and at this point we might as well just keep a small buffer just large enough to keep from running out of frames.
                frameCacheCount = FrameCacheCountPolicy.default.rawValue
            } else {
                // The predicted size exceeds the limits to build up a cache and we go into low memory mode from the beginning.
                frameCacheCount = FrameCacheCountPolicy.lowMemory.rawValue
            }
        } else {
            // Use the provided value.
            frameCacheCount = optimalFrameCacheCount.rawValue
        }
        // In any case, cap the optimal cache count at the frame count.
        self.optimalFrameCacheCount = min(frameCacheCount, frameCount)
        
        // Call memory warning handler if received memory warning.
        NotificationCenter.default.addObserver(self, selector: #selector(didReceiveMemoryWarning(_:)), name: Notification.Name.UIApplicationDidReceiveMemoryWarning, object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    private var requestedFrameIndex: Int = 0
    
    /// Intended to be called from main thread synchronously and will return immediately.
    ///
    /// If the result isn't cached, will return `nil`, the caller should then pause playback, not increment frame counter and keep polling.
    ///
    /// After an initial loading time, depending on `frameCacheSize`, frames should be available immediately from the cache.
    ///
    /// - Parameter index: The frame index to cache.
    /// - Returns: Cached image frame.
    public func imageLazilyCached(at index: Int) -> UIImage? {
        // Early return if the requested index is beyond bounds.
        if index >= self.frameCount {
            return nil
        }
        
        // Remember requested frame index, this influences what we should cache next.
        self.requestedFrameIndex = index
        
        // Quick check to avoid doing any work if we already have all possible frames cached, a common case.
        if self.cachedFrames.count < self.frameCount {
            // If we have frames that should be cached but aren't and aren't requested yet, request them.
            // Exclude existing cached frames, frames already requested, and specially cached poster image.
            var frameIndexesToAddToCache = self.frameIndexesToCache()
            // Poster frame is always cached.
            if let posterImageFrameIndex = self.posterImageFrameIndex {
                frameIndexesToAddToCache.remove(posterImageFrameIndex)
            }
            // Filter already cached frames and caching frames.
            frameIndexesToAddToCache = frameIndexesToAddToCache.filteredIndexSet { [weak self] index in
                guard let strongSelf = self else { return false }
                return !strongSelf.cachedFrameIndexes.contains(index) && !strongSelf.cachingFrameIndexes.contains(index)
            }
            
            if frameIndexesToAddToCache.count > 0 {
                // Asynchronously add frames to our cache.
                self.addFrameIndexesToCache(frameIndexesToAddToCache)
            }
        }
        
        // Get the specified image.
        let image = self.cachedFrames[index]
        
        // Purge if needed based on the current playhead position.
        self.cleanFrameCacheIfNeeded()
        
        return image
    }
    
    private func addFrameIndexesToCache(_ indexSet: IndexSet) {
        // Order matters. First, iterate over the indexes starting from the requested frame index.
        // Then, if there are any indexes before the requested frame index, do those.
        let subIndexes = indexSet.split(separator: requestedFrameIndex)
        let prefixIndexes = subIndexes.first
        let suffixIndexes = subIndexes.last
        // Add to the caching list before we actually kick them off, so they don't get into the queue twice.
        self.cachingFrameIndexes = self.cachingFrameIndexes.union(indexSet)
        
        let indexHandler: (IndexSet.Element) -> Void = { [weak self] element in
            guard let strongSelf = self else { return }
            if let image = strongSelf.loadImage(at: element) {
                DispatchQueue.main.async {
                    strongSelf.cachedFrames[element] = image
                    strongSelf.cachingFrameIndexes.remove(element)
                }
            }
        }
        AnimatedImage.serialQueue.async {
            guard let prefix = prefixIndexes, let suffix = suffixIndexes else {
                return
            }
            suffix.forEach(indexHandler)
            if !prefix.elementsEqual(suffix) {
                prefix.forEach(indexHandler)
            }
        }
    }
    
    // MARK: Frame Loading
    private func loadImage(at index: Int) -> UIImage? {
        guard let cgImage = CGImageSourceCreateImageAtIndex(self.imageSource, index, nil) else {
            return nil
        }
        
        // Loading in the image object is only half the work, the displaying image view would still have to synchronosly wait and decode the image, so we go ahead and do that here on the background thread.
        let image = UIImage(cgImage: cgImage)
        if predrawingEnabled {
            return self.predrawnImage(from: image)
        } else {
            return image
        }
    }
    
    // MARK: Frame Caching
    private var currentFrameCacheCount: Int {
        var currentFrameCacheSize = self.optimalFrameCacheCount
        
        // Respect max frame cache count limit.
        if self.frameCacheCountMax.rawValue > FrameCacheCountPolicy.noLimit.rawValue {
            currentFrameCacheSize = min(currentFrameCacheSize, frameCacheCountMax.rawValue)
        }
        
        return currentFrameCacheSize
    }
    
    private func frameIndexesToCache() -> IndexSet {
        var indexesToCache = IndexSet()
        // Quick check to avoid building the index set if the number of frames to cache equals the total frame count.
        if self.currentFrameCacheCount == self.frameCount {
            indexesToCache = IndexSet.init(integersIn: 0..<frameCount)
        } else {
            // Add indexes to the set in two separate ranges:
            // 1. starting from the requested frame index, up to the limit or the end.
            // 2. if needed, the remaining number of frames beginning at index zero.
            let firstLength = min(currentFrameCacheCount, frameCount - requestedFrameIndex)
            let firstRange = requestedFrameIndex..<(requestedFrameIndex + firstLength)
            indexesToCache.insert(integersIn: firstRange)
            
            let secondLength = currentFrameCacheCount - firstLength
            
            if secondLength > 0 {
                let secondRange = 0..<secondLength
                indexesToCache.insert(integersIn: secondRange)
            }
            
            if let posterImageFrameIndex = self.posterImageFrameIndex {
                indexesToCache.insert(posterImageFrameIndex)
            }
        }
        
        return indexesToCache
    }
    
    /// Clean frames that are currently cached but don't need to be, if cached frames is upon `currentFrameCacheCount`.
    private func cleanFrameCacheIfNeeded() {
        guard self.cachedFrameIndexes.count > self.currentFrameCacheCount else {
            return
        }
        var frameIndexesToRemove = self.cachedFrameIndexes
        let frameIndexesToCache = self.frameIndexesToCache()
        // Filter indexes which need to cache.
        frameIndexesToRemove = frameIndexesToRemove.filteredIndexSet { element in
            return !frameIndexesToCache.contains(element)
        }
        
        frameIndexesToRemove.forEach { [weak self] index in
            self?.cachedFrames[index] = nil
        }
    }
    
    // MARK: System Memory Warnings Notification Handler
    private var memoryWarningCount: Int = 0
    private var growFrameCacheSizeAfterMemoryWarningWork: DispatchWorkItem?
    private var resetFrameCacheCountMaxWork: DispatchWorkItem?
    @objc func didReceiveMemoryWarning(_ notification: Notification) {
        self.memoryWarningCount += 1
        
        // If we were about to grow larger, but got rapped on our knuckles by the system again, cancel.
        growFrameCacheSizeAfterMemoryWarningWork?.cancel()
        growFrameCacheSizeAfterMemoryWarningWork = nil
        
        resetFrameCacheCountMaxWork?.cancel()
        resetFrameCacheCountMaxWork = nil
        
        // Go down to the minimum and by that implicitly immediately purge from the cache if needed to not get jettisoned by the system and start producing frames on-demand.
        
        let currentFrameCacheCountMax = self.frameCacheCountMax
        self.frameCacheCountMax = FrameCacheCountPolicy.lowMemory
        
        // Schedule growing larger again after a while, but cap our attempts to prevent a periodic sawtooth wave (ramps upward and then sharply drops) of memory usage.
        //
        // [mem]^     (2)   (5)  (6)        1) Loading frames for the first time
        //   (*)|      ,     ,    ,         2) Mem warning #1; purge cache
        //      |     /| (4)/|   /|         3) Grow cache size a bit after a while, if no mem warning occurs
        //      |    / |  _/ | _/ |         4) Try to grow cache size back to optimum after a while, if no mem warning occurs
        //      |(1)/  |_/   |/   |__(7)    5) Mem warning #2; purge cache
        //      |__/   (3)                  6) After repetition of (3) and (4), mem warning #3; purge cache
        //      +---------------------->    7) After 3 mem warnings, stay at minimum cache size
        //                            [t]
        //                                  *) The mem high water mark before we get warned might change for every cycle.
        //
        let growAttempsMax: Int = 2
        let growDelay: TimeInterval = 2.0
        
        if self.memoryWarningCount - 1 <= growAttempsMax {
            self.growFrameCacheSizeAfterMemoryWarningWork = DispatchWorkItem { [weak self] in
                self?.frameCacheCountMax = FrameCacheCountPolicy.growAfterMemoryWarning
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self?.resetFrameCacheCountMaxWork?.perform()
                }
            }
            self.resetFrameCacheCountMaxWork = DispatchWorkItem { [weak self] in
                self?.frameCacheCountMax = currentFrameCacheCountMax
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + growDelay) {
                self.growFrameCacheSizeAfterMemoryWarningWork?.perform()
            }
        }
    }
    
    // MARK: Image decoding
    private func predrawnImage(from image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else {
            return image
        }
        let colorSpaceDeviceRGBRef = CGColorSpaceCreateDeviceRGB()
        
        let numberOfComponents = colorSpaceDeviceRGBRef.numberOfComponents + 1 // 4: RGB + A
        
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        let bitsPerComponent = Int(CHAR_BIT)
        
        let bitsPerPixel = bitsPerComponent * numberOfComponents
        let bytesPerPixel = bitsPerPixel / 8
        let bytesPerRow = bytesPerPixel * width
        
        var bitmapInfo = CGBitmapInfo(rawValue: 0)
        
        var alphaInfo = cgImage.alphaInfo
        // If the alpha info doesn't match to one of the supported formats (see above), pick a reasonable supported one.
        // "For bitmaps created in iOS 3.2 and later, the drawing environment uses the premultiplied ARGB format to store the bitmap data." (source: docs)
        if (alphaInfo == .none || alphaInfo == .alphaOnly) {
            alphaInfo = .noneSkipFirst
        } else if (alphaInfo == .first) {
            alphaInfo = .premultipliedFirst;
        } else if (alphaInfo == .last) {
            alphaInfo = .premultipliedLast;
        }
        // "The constants for specifying the alpha channel information are declared with the `CGImageAlphaInfo` type but can be passed to this parameter safely." (source: docs)
        bitmapInfo = CGBitmapInfo.init(rawValue: alphaInfo.rawValue)
        
        // Create our own graphics context to draw to; `UIGraphicsGetCurrentContext`/`UIGraphicsBeginImageContextWithOptions` doesn't create a new context but returns the current one which isn't thread-safe (e.g. main thread could use it at the same time).
        // Note: It's not worth caching the bitmap context for multiple frames ("unique key" would be `width`, `height` and `hasAlpha`), it's ~50% slower. Time spent in libRIP's `CGSBlendBGRA8888toARGB8888` suddenly shoots up -- not sure why.
        guard let bitmapContextRef = CGContext(data: nil, width: width, height: height, bitsPerComponent: bitsPerComponent, bytesPerRow: bytesPerRow, space: colorSpaceDeviceRGBRef, bitmapInfo: bitmapInfo.rawValue) else {
            return image
        }
        
        // Draw image in bitmap context and create image by preserving receiver's properties.
        bitmapContextRef.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let predrawnCGImage = bitmapContextRef.makeImage() else {
            return image
        }
        return UIImage(cgImage: predrawnCGImage, scale: image.scale, orientation: image.imageOrientation)
    }
}

extension AnimatedImage: Equatable {
    public static func == (lhs: AnimatedImage, rhs: AnimatedImage) -> Bool {
        return lhs.data == rhs.data
    }
}
