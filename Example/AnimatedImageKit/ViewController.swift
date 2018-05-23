//
//  ViewController.swift
//  AnimatedImageKit
//
//  Created by junjielu on 05/18/2018.
//  Copyright (c) 2018 junjielu. All rights reserved.
//

import UIKit
import AnimatedImageKit

class ViewController: UIViewController {
    let imageView = AnimatedImageView()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.imageView.contentMode = .scaleAspectFit
        self.imageView.clipsToBounds = true
        self.imageView.frame = CGRect(x: 0, y: 0, width: self.view.bounds.width, height: self.view.bounds.height)
        self.view.addSubview(imageView)
        
        let url = Bundle.main.url(forResource: "rock", withExtension: "gif")!
        if let data = try? Data(contentsOf: url), let animatedImage = AnimatedImage(animatedImageData: data) {
            self.imageView.animatedImage = animatedImage
        }
    }
    
    func loadAnimatedImage(with url: URL, completion: @escaping (AnimatedImage) -> Void) {
        let filename = url.lastPathComponent
        let diskPath = (NSHomeDirectory() as NSString).appendingPathComponent(filename)
        
        if let animatedImageData = FileManager.default.contents(atPath: diskPath), let animatedImage = AnimatedImage(animatedImageData: animatedImageData) {
            completion(animatedImage)
        } else {
            let task = URLSession.shared.dataTask(with: url) { data, response, error in
                if let imageData = data, let image = AnimatedImage(animatedImageData: imageData) {
                    DispatchQueue.main.async {
                        completion(image)
                    }
                    (imageData as NSData).write(toFile: diskPath, atomically: true)
                }
            }
            task.resume()
        }
    }
}

