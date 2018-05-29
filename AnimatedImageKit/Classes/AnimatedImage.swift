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
    public enum AnimatedImageFrameCacheSize: Int {
        case noLimit = 0
        case lowMemory = 1
        case growAfterMemoryWarning = 2
        case `default` = 5
    }
    
    public enum AnimatedImageDataSizeCategory: CGFloat {
        case all = 10       // All frames permanently in memory (be nice to the CPU)
        case `default` = 75  // A frame cache of default size in memory (usually real-time performance and keeping low memory profile)
        case onDemand = 250 // Only keep one frame at the time in memory (easier on memory, slowest performance)
        case unsupported     // Even for one frame too large, computer says no.
    }
    
    static let serialQueue = DispatchQueue(label: "com.animatedkit.framecachingqueue")
    
    public let data: Data
    
    public var posterImage: UIImage?
    public var posterImageSize: CGSize?
    public var posterImageFrameIndex: Int?
    
    public var loopCount: Int
    public var frameCount: Int
    public var delayTimes = [Int: CGFloat]()
    
    public let frameCacheSizeOptimal: Int
    public var frameCacheSizeMax: Int = 0 {
        didSet {
            if frameCacheSizeMax != oldValue {
                // Remember whether the new cap will cause the current cache size to shrink; then we'll make sure to purge from the cache if needed.
                let willFrameCacheSizeShrink = frameCacheSizeMax < self.currentFrameCacheSize
                
                if willFrameCacheSizeShrink {
                    self.purgeFrameCacheIfNeeded()
                }
            }
        }
    }
    
    private var frameCacheSizeMaxInternal: Int = 0 {
        didSet {
            if frameCacheSizeMaxInternal != oldValue {
                
                // Remember whether the new cap will cause the current cache size to shrink; then we'll make sure to purge from the cache if needed.
                let willFrameCacheSizeShrink = frameCacheSizeMaxInternal < self.currentFrameCacheSize
                
                if willFrameCacheSizeShrink {
                    self.purgeFrameCacheIfNeeded()
                }
            }
        }
    }
    
    var cachedFrames = [Int: UIImage]()
    var cachedFrameIndexes: IndexSet {
        return IndexSet(cachedFrames.keys)
    }
    var requestedFrameIndexes = IndexSet()
    
    private let predrawingEnabled: Bool
    private let imageSource: CGImageSource
    
    private let minimumDelayTimeInterval = 0.02
    
    // MARK: Life Cycle
    public init?(animatedImageData: Data, optimalFrameCacheSize: Int = 0, predrawingEnabled: Bool = true) {
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
        var loopCount = (imageProperties?[kCGImagePropertyGIFDictionary as String] as? [String: Any])?[kCGImagePropertyGIFLoopCount as String] as? Int ?? 1
        if loopCount > 0 {
            loopCount += 1
        }
        self.loopCount = loopCount
        
        self.frameCount = CGImageSourceGetCount(rawImageSource)
        
        var skippedFrameCount = 0
        
        for index in 0..<frameCount {
            if let frameCGImage = CGImageSourceCreateImageAtIndex(rawImageSource, index, nil) {
                let frameImage = UIImage(cgImage: frameCGImage)
                // Check for valid `frameImage` before parsing its properties as frames can be corrupted (and `frameImage` even `nil` when `frameImageRef` was valid).
                // Set poster image
                if self.posterImage == nil {
                    self.posterImage = frameImage
                    // Set its size to proxy our size.
                    self.posterImageSize = frameImage.size
                    // Remember index of poster image so we never purge it; also add it to the cache.
                    self.posterImageFrameIndex = index
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
                
                // Try to use the unclamped delay time; fall back to the normal delay time.
                // If we don't get a delay time from the properties, fall back to `kDelayTimeIntervalDefault` or carry over the preceding frame's value.
                let defaultDelayInterval = index == 0 ? 0.1 : (delayTimes[index - 1] ?? 0.1)
                var delayTime = gifFrameProperties?[kCGImagePropertyGIFUnclampedDelayTime as String] as? CGFloat ?? gifFrameProperties?[kCGImagePropertyGIFDelayTime as String] as? CGFloat ?? defaultDelayInterval
                
                // Support frame delays as low as `minimumDelayTimeInterval`, with anything below being rounded up to `minimumDelayTimeInterval` for legacy compatibility.
                // To support the minimum even when rounding errors occur, use an epsilon when comparing. We downcast to float because that's what we get for delayTime from ImageIO.
                if delayTime < 0.02 - CGFloat(Float.ulpOfOne) {
                    delayTime = defaultDelayInterval
                }
                delayTimes[index] = delayTime
            } else {
                skippedFrameCount += 1
            }
        }
        
        guard frameCount > 0, let poster = self.posterImage, let posterSize = self.posterImageSize else {
            return nil
        }
        
        // If no value is provided, select a default based on the GIF.
        let frameCacheSize: Int
        if optimalFrameCacheSize == 0 {
            // Calculate the optimal frame cache size: try choosing a larger buffer window depending on the predicted image size.
            // It's only dependent on the image size & number of frames and never changes.
            let megaByte: CGFloat = (1024 * 1024)
            let posterBytesPerRow = CGFloat(poster.cgImage?.bytesPerRow ?? 0)
            let posterHeight = posterSize.height
            let realFrameCount = CGFloat(self.frameCount - skippedFrameCount)
            let animatedImageDataSize = posterBytesPerRow * posterHeight * realFrameCount / megaByte
            
            if animatedImageDataSize <= AnimatedImageDataSizeCategory.all.rawValue {
                frameCacheSize = self.frameCount
            } else if animatedImageDataSize <= AnimatedImageDataSizeCategory.default.rawValue {
                // This value doesn't depend on device memory much because if we're not keeping all frames in memory we will always be decoding 1 frame up ahead per 1 frame that gets played and at this point we might as well just keep a small buffer just large enough to keep from running out of frames.
                frameCacheSize = AnimatedImageFrameCacheSize.default.rawValue
            } else {
                // The predicted size exceeds the limits to build up a cache and we go into low memory mode from the beginning.
                frameCacheSize = AnimatedImageFrameCacheSize.lowMemory.rawValue
            }
        } else {
            // Use the provided value.
            frameCacheSize = optimalFrameCacheSize
        }
        // In any case, cap the optimal cache size at the frame count.
        self.frameCacheSizeOptimal = min(frameCacheSize, frameCount)
        
        NotificationCenter.default.addObserver(forName: Notification.Name.UIApplicationDidReceiveMemoryWarning, object: nil, queue: OperationQueue.main) { [weak self] notification in
            self?.didReceiveMemoryWarning(notification)
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    var requestedFrameIndex: Int = 0
    public func imageLazilyCached(at index: Int) -> UIImage? {
        // Early return if the requested index is beyond bounds.
        // Note: We're comparing an index with a count and need to bail on greater than or equal to.
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
            if let posterImageFrameIndex = self.posterImageFrameIndex {
                frameIndexesToAddToCache.remove(posterImageFrameIndex)
            }
            frameIndexesToAddToCache = frameIndexesToAddToCache.filteredIndexSet { [weak self] index in
                guard let strongSelf = self else { return false }
                return !strongSelf.cachedFrameIndexes.contains(index) && !strongSelf.requestedFrameIndexes.contains(index)
            }
            
            // Asynchronously add frames to our cache.
            if frameIndexesToAddToCache.count > 0 {
                
                self.addFrameIndexesToCache(frameIndexesToAddToCache)
            }
        }
        
        // Get the specified image.
        let image = self.cachedFrames[index]
        
        // Purge if needed based on the current playhead position.
        self.purgeFrameCacheIfNeeded()
        
        return image
    }
    
    func addFrameIndexesToCache(_ indexSet: IndexSet) {
        // Order matters. First, iterate over the indexes starting from the requested frame index.
        // Then, if there are any indexes before the requested frame index, do those.
        let subIndexes = indexSet.split(separator: requestedFrameIndex)
        let prefixIndexes = subIndexes.first
        let suffixIndexes = subIndexes.last
        // Add to the requested list before we actually kick them off, so they don't get into the queue twice.
        self.requestedFrameIndexes = self.requestedFrameIndexes.union(indexSet)
        
        let indexHandler: (IndexSet.Element) -> Void = { [weak self] element in
            guard let strongSelf = self else { return }
            if let image = strongSelf.loadImage(at: element) {
                DispatchQueue.main.async {
                    strongSelf.cachedFrames[element] = image
                    strongSelf.requestedFrameIndexes.remove(element)
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
    func loadImage(at index: Int) -> UIImage? {
        // It's very important to use the cached `_imageSource` since the random access to a frame with `CGImageSourceCreateImageAtIndex` turns from an O(1) into an O(n) operation when re-initializing the image source every time.
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
    var currentFrameCacheSize: Int {
        var currentFrameCacheSize = self.frameCacheSizeOptimal
        
        // If set, respect the caps.
        if self.frameCacheSizeMax > AnimatedImageFrameCacheSize.noLimit.rawValue {
            currentFrameCacheSize = min(currentFrameCacheSize, frameCacheSizeMax)
        }
        
        if self.frameCacheSizeMaxInternal > AnimatedImageFrameCacheSize.noLimit.rawValue {
            currentFrameCacheSize = min(currentFrameCacheSize, self.frameCacheSizeMaxInternal);
        }
        
        return currentFrameCacheSize
    }
    
    func frameIndexesToCache() -> IndexSet {
        var indexesToCache = IndexSet()
        // Quick check to avoid building the index set if the number of frames to cache equals the total frame count.
        if self.currentFrameCacheSize == self.frameCount {
            indexesToCache = IndexSet.init(integersIn: 0..<frameCount)
        } else {
            // Add indexes to the set in two separate blocks- the first starting from the requested frame index, up to the limit or the end.
            // The second, if needed, the remaining number of frames beginning at index zero.
            let firstLength = min(currentFrameCacheSize, frameCount - requestedFrameIndex)
            let firstRange = requestedFrameIndex..<(requestedFrameIndex + firstLength)
            indexesToCache.insert(integersIn: firstRange)
            
            let secondLength = currentFrameCacheSize - firstLength
            
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
    
    func purgeFrameCacheIfNeeded() {
        // Purge frames that are currently cached but don't need to be.
        // But not if we're still under the number of frames to cache.
        // This way, if all frames are allowed to be cached (the common case), we can skip all the `NSIndexSet` math below.
        if self.cachedFrameIndexes.count > self.currentFrameCacheSize {
            var indexesToPurge = self.cachedFrameIndexes
            let frameIndexesToCache = self.frameIndexesToCache()
            indexesToPurge = indexesToPurge.filteredIndexSet { element in
                return !frameIndexesToCache.contains(element)
            }
            
            indexesToPurge.forEach { [weak self] element in
                self?.cachedFrames[element] = nil
            }
        }
    }
    
    private var resetFrameCacheSizeMaxInternalWork: DispatchWorkItem?
    func growFrameCacheSizeAfterMemoryWarning() {
        self.frameCacheSizeMaxInternal = AnimatedImageFrameCacheSize.growAfterMemoryWarning.rawValue
        
        // Schedule resetting the frame cache size max completely after a while.
        self.resetFrameCacheSizeMaxInternalWork = DispatchWorkItem { [weak self] in
            self?.resetFrameCacheSizeMaxInternal()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.resetFrameCacheSizeMaxInternalWork?.perform()
        }
    }
    
    func resetFrameCacheSizeMaxInternal() {
        self.frameCacheSizeMaxInternal = AnimatedImageFrameCacheSize.noLimit.rawValue
    }
    
    // MARK: System Memory Warnings Notification Handler
    private var memoryWarningCount: Int = 0
    private var growFrameCacheSizeAfterMemoryWarningWork: DispatchWorkItem?
    func didReceiveMemoryWarning(_ notification: Notification) {
        self.memoryWarningCount += 1
        
        // If we were about to grow larger, but got rapped on our knuckles by the system again, cancel.
        growFrameCacheSizeAfterMemoryWarningWork?.cancel()
        growFrameCacheSizeAfterMemoryWarningWork = nil
        
        resetFrameCacheSizeMaxInternalWork?.cancel()
        resetFrameCacheSizeMaxInternalWork = nil
        
        // Go down to the minimum and by that implicitly immediately purge from the cache if needed to not get jettisoned by the system and start producing frames on-demand.
        
        self.frameCacheSizeMaxInternal = AnimatedImageFrameCacheSize.lowMemory.rawValue
        
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
            self.growFrameCacheSizeAfterMemoryWarningWork = DispatchWorkItem {
                self.growFrameCacheSizeAfterMemoryWarning()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + growDelay) {
                self.growFrameCacheSizeAfterMemoryWarningWork?.perform()
            }
        }
        
        // Note: It's not possible to get the level of a memory warning with a public API: http://stackoverflow.com/questions/2915247/iphone-os-memory-warnings-what-do-the-different-levels-mean/2915477#2915477
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
