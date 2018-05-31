//
//  AnimatedImageView.swift
//  AnimatedImageKit
//
//  Created by 陆俊杰 on 2018/5/18.
//

import UIKit

public class AnimatedImageView: UIImageView {
    public var animatedImage: AnimatedImage? {
        didSet {
            self.didSet(animatedImage, oldValue: oldValue)
        }
    }
    public var currentFrame: UIImage?
    public var currentFrameIndex: Int = 0
    
    public let runLoopMode: RunLoopMode = {
        return ProcessInfo.processInfo.activeProcessorCount > 1 ? RunLoopMode.commonModes : RunLoopMode.defaultRunLoopMode
    }()
    public var loopCompletionBlock: ((Int) -> Void)?
    
    var loopCountdown: Int = 0
    var accumulator: TimeInterval = 0
    var displayLink: CADisplayLink?
    
    var shouldAnimate: Bool = false
    var needsDisplayWhenImageBecomesAvailable: Bool = false
    
    deinit {
        displayLink?.invalidate()
    }
    
    // MARK: Handle setter
    func didSet(_ animatedImage: AnimatedImage?, oldValue: AnimatedImage?) {
        if animatedImage != oldValue {
            if animatedImage != nil {
                // Clear out the image.
                super.image = nil
                // Ensure disabled highlighting; it's not supported (see `-setHighlighted:`).
                super.isHighlighted = false
                // UIImageView seems to bypass some accessors when calculating its intrinsic content size, so this ensures its intrinsic content size comes from the animated image.
                self.invalidateIntrinsicContentSize()
            } else {
                // Stop animating before the animated image gets cleared out.
                self.stopAnimating()
            }
            
            self.currentFrame = animatedImage?.posterImage
            self.currentFrameIndex = 0;
            if let image = animatedImage, image.loopCount > 0 {
                self.loopCountdown = image.loopCount
            } else {
                self.loopCountdown = Int.max
            }
            self.accumulator = 0.0
            
            // Start animating after the new animated image has been set.
            self.updateShouldAnimate()
            if self.shouldAnimate {
                self.startAnimating()
            }
            
            self.layer.setNeedsDisplay()
        }
    }
    
    // MARK: Observing View-Related Changes
    public override func didMoveToSuperview() {
        super.didMoveToSuperview()
        
        self.updateAnimatingState()
    }
    
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        
        self.updateAnimatingState()
    }
    
    public override var alpha: CGFloat {
        didSet {
            self.updateAnimatingState()
        }
    }
    
    public override var isHidden: Bool {
        didSet {
            self.updateAnimatingState()
        }
    }
    
    private func updateAnimatingState() {
        self.updateShouldAnimate()
        if self.shouldAnimate {
            self.startAnimating()
        } else {
            self.stopAnimating()
        }
    }
    
    // MARK: Auto Layout
    public override var intrinsicContentSize: CGSize {
        // Default to let UIImageView handle the sizing of its image, and anything else it might consider.
        var intrinsicContentSize = super.intrinsicContentSize
        
        // If we have have an animated image, use its image size.
        // UIImageView's intrinsic content size seems to be the size of its image. The obvious approach, simply calling `-invalidateIntrinsicContentSize` when setting an animated image, results in UIImageView steadfastly returning `{UIViewNoIntrinsicMetric, UIViewNoIntrinsicMetric}` for its intrinsicContentSize.
        // (Perhaps UIImageView bypasses its `-image` getter in its implementation of `-intrinsicContentSize`, as `-image` is not called after calling `-invalidateIntrinsicContentSize`.)
        if self.animatedImage != nil, let image = self.image {
            intrinsicContentSize = image.size
        }
        
        return intrinsicContentSize
    }
    
    // MARK: Image Data
    public override var image: UIImage? {
        get {
            if self.animatedImage != nil {
                // Initially set to the poster image.
                return self.currentFrame
            } else {
                return super.image
            }
        }
        set {
            if newValue != nil {
                self.animatedImage = nil
            }
            super.image = newValue
        }
    }
    
    // MARK: Animating Images
    func frameDelayGreatestCommonDivisor() -> TimeInterval {
        let greatestCommonDivisorPrecision: TimeInterval = 2.0 / 0.02
        
        if let delays = self.animatedImage?.delayTimes.values {
            // Scales the frame delays by `greatestCommonDivisorPrecision`
            // then converts it to an Int for in order to calculate the GCD.
            var scaledGCD = lrint(Double(delays.first ?? 0) * greatestCommonDivisorPrecision)
            for delay in delays {
                scaledGCD = greatestCommonDivisor(lrint(Double(delay) * greatestCommonDivisorPrecision), with: scaledGCD)
            }
            
            // Reverse to scale to get the value back into seconds.
            return Double(scaledGCD) / greatestCommonDivisorPrecision
        } else {
            return 0
        }
    }
    
    private func greatestCommonDivisor(_ intA: Int, with intB: Int) -> Int {
        // https://github.com/raywenderlich/swift-algorithm-club/tree/master/GCD
        let intR = intA % intB
        if intR != 0 {
            return greatestCommonDivisor(intB, with: intR)
        } else {
            return intB
        }
    }
    
    public override func startAnimating() {
        if self.animatedImage != nil {
            // Lazily create the display link.
            if self.displayLink == nil {
                // It is important to note the use of a weak proxy here to avoid a retain cycle. `-displayLinkWithTarget:selector:`
                // will retain its target until it is invalidated. We use a weak proxy so that the image view will get deallocated
                // independent of the display link's lifetime. Upon image view deallocation, we invalidate the display
                // link which will lead to the deallocation of both the display link and the weak proxy.
                self.displayLink = CADisplayLink(target: self, selector: #selector(displayDidRefresh(_:)))
                
                self.displayLink?.add(to: .main, forMode: self.runLoopMode)
            }
            
            // Note: The display link's `.frameInterval` value of 1 (default) means getting callbacks at the refresh rate of the display (~60Hz).
            // Setting it to 2 divides the frame rate by 2 and hence calls back at every other display refresh.
            let displayRefreshRate: TimeInterval = 60.0 // 60Hz
            self.displayLink?.frameInterval = max(Int(self.frameDelayGreatestCommonDivisor() * displayRefreshRate), 1)
            
            self.displayLink?.isPaused = false
        } else {
            super.startAnimating()
        }
    }
    
    public override func stopAnimating() {
        if self.animatedImage != nil {
            self.displayLink?.isPaused = true
        } else {
            super.stopAnimating()
        }
    }
    
    public override var isAnimating: Bool {
        if self.animatedImage != nil {
            return self.displayLink != nil && self.displayLink?.isPaused == false
        } else {
            return super.isAnimating
        }
    }
    
    // Mark: Highlighted Image Unsupport
    public override var isHighlighted: Bool {
        set {
            if self.animatedImage == nil {
                super.isHighlighted = newValue
            }
        }
        get {
            return super.isHighlighted
        }
    }
    
    // MARK: Animation
    private func updateShouldAnimate() {
        let isVisible = self.window != nil && self.superview != nil && self.isHidden == false && self.alpha > 0.0
        self.shouldAnimate = self.animatedImage != nil && isVisible
    }
    
    @objc func displayDidRefresh(_ displayLink: CADisplayLink) {
        // If for some reason a wild call makes it through when we shouldn't be animating, bail.
        // Early return!
        guard self.shouldAnimate, let animatedImage = self.animatedImage else {
            return
        }
        
        // If we don't have a frame delay (e.g. corrupt frame), don't update the view but skip the playhead to the next frame (in else-block).
        // If we have a nil image (e.g. waiting for frame), don't update the view nor playhead.
        if let delayTime = animatedImage.delayTimes[currentFrameIndex], let image = animatedImage.imageLazilyCached(at: currentFrameIndex) {
            self.currentFrame = image
            if self.needsDisplayWhenImageBecomesAvailable {
                self.layer.setNeedsDisplay()
                self.needsDisplayWhenImageBecomesAvailable = false
            }
            
            self.accumulator += displayLink.duration * Double(displayLink.frameInterval)
            
            // While-loop first inspired by & good Karma to: https://github.com/ondalabs/OLImageView/blob/master/OLImageView.m
            while self.accumulator >= Double(delayTime) {
                self.accumulator -= Double(delayTime)
                self.currentFrameIndex += 1
                if self.currentFrameIndex >= animatedImage.frameCount {
                    // If we've looped the number of times that this animated image describes, stop looping.
                    self.loopCountdown -= 1
                    self.loopCompletionBlock?(self.loopCountdown)
                    
                    if self.loopCountdown == 0 {
                        self.stopAnimating()
                        return
                    }
                    self.currentFrameIndex = 0
                }
                // Calling `-setNeedsDisplay` will just paint the current frame, not the new frame that we may have moved to.
                // Instead, set `needsDisplayWhenImageBecomesAvailable` to `YES` -- this will paint the new image once loaded.
                self.needsDisplayWhenImageBecomesAvailable = true
            }
        } else {
            self.currentFrameIndex = currentFrameIndex + 1
        }
    }
    
    // MARK: Providing the Layer's Content
    public override func display(_ layer: CALayer) {
        layer.contents = self.image?.cgImage
    }
}
