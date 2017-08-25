//
//  ViewController.h
//  CameraReceiveStream
//
//  Created by Anirban Bhattacharya (Student) on 8/25/17.
//  Copyright © 2017 Anirban Bhattacharya (Student). All rights reserved.
//

#import <UIKit/UIKit.h>
#import "GCDAsyncUdpSocket.h"
#import <VideoToolbox/VideoToolbox.h>
#import <AVFoundation/AVFoundation.h>
@interface ViewController : UIViewController<GCDAsyncUdpSocketDelegate>
@property (nonatomic, assign) CMVideoFormatDescriptionRef formatDesc;
@property (nonatomic, assign) VTDecompressionSessionRef decompressionSession;
@property (nonatomic, assign) int spsSize;
@property (nonatomic, assign) int ppsSize;
@property (weak, nonatomic) IBOutlet UIView *VideoView;

@end

