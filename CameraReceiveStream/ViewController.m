//
//  ViewController.m
//  CameraReceiveStream
//
//  Created by Anirban Bhattacharya (Student) on 8/25/17.
//  Copyright © 2017 Anirban Bhattacharya (Student). All rights reserved.
//

#import "ViewController.h"
#import "NALUTypes.h"



typedef enum {
    NALUTypeSliceNoneIDR = 1,
    NALUTypeSliceIDR = 5,
    NALUTypeSPS = 7,
    NALUTypePPS = 8
} NALUType;

@interface ViewController ()
{
    NSUInteger offset;
    NSFileHandle *fileHandle;
    NSString *h264File;
}


@property (nonatomic) BOOL videoFormatDescriptionAvailable;
@property (nonatomic) CMVideoFormatDescriptionRef videoFormatDescr;
@property (nonatomic, strong) NSData * spsData;
@property (nonatomic, strong) NSData * ppsData;
@property (nonatomic, strong) NSMutableArray * NALBuffer;
@property (nonatomic, strong) NSData * startCode;

@end

@implementation ViewController
GCDAsyncUdpSocket *udpSocket;

dispatch_queue_t receiveDataQueue;
dispatch_queue_t writeToFileQueue;
dispatch_queue_t sendToDecodeQueue;

AVSampleBufferDisplayLayer* displayLayer;
- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    _NALBuffer=[NSMutableArray new];
    _startCode=[NSData dataWithBytes:"\x00\x00\x00\x01" length:(sizeof "\x00\x00\x00\x01") - 1];
    receiveDataQueue = dispatch_queue_create("com.receiveDataQueue.queue", DISPATCH_QUEUE_SERIAL);
    writeToFileQueue = dispatch_queue_create("com.writeToFile.queue", DISPATCH_QUEUE_SERIAL);
    sendToDecodeQueue = dispatch_queue_create("com.sendToDecode.queue", DISPATCH_QUEUE_SERIAL);
    udpSocket = [[GCDAsyncUdpSocket alloc] initWithDelegate:self delegateQueue:receiveDataQueue];
    [self initializeDisplayLayer];
    [self openSocket];
    [self createNewH264File];
    
}

-(void)createNewH264File
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    
    h264File = [documentsDirectory stringByAppendingPathComponent:@"test.h264"];
    [fileManager removeItemAtPath:h264File error:nil];
    [fileManager createFileAtPath:h264File contents:nil attributes:nil];
    

    fileHandle = [NSFileHandle fileHandleForWritingAtPath:h264File];
}

-(void)openSocket
{
    NSError *error;
    
    if (![udpSocket bindToPort:1900 error:&error])
    {
        NSLog(@"Bind error");
    }
    if (![udpSocket beginReceiving:&error])
    {
        [udpSocket close];
        
        NSLog(@"Receiving error");
        return;
    }
}



- (void)udpSocket:(GCDAsyncUdpSocket *)sock didReceiveData:(NSData *)data
      fromAddress:(NSData *)address
withFilterContext:(id)filterContext
{
    
    dispatch_async(writeToFileQueue, ^{
        [self writeDataToBuffer:data];
    });
    
}

-(void)writeDataToBuffer:(NSData*)data
{
    NSMutableData *NALUnit=[[NSMutableData alloc] initWithData:data];
    NSRange range = NSMakeRange(0, 4);
    [NALUnit replaceBytesInRange:range withBytes:NULL length:0];
    dispatch_async(sendToDecodeQueue, ^{
        [self parseNALU:NALUnit];
    });
}

-(void) initializeDisplayLayer
{
    //Initialize display layer
    displayLayer = [[AVSampleBufferDisplayLayer alloc] init];
    //Add the layer to the VideoView
    displayLayer.bounds = _VideoView.bounds;
    displayLayer.frame = _VideoView.frame;
    displayLayer.backgroundColor = [UIColor blackColor].CGColor;
    displayLayer.position = CGPointMake(CGRectGetMidX(_VideoView.bounds), CGRectGetMidY(_VideoView.bounds));
    displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    
    // Remove from previous view if exists
    [displayLayer removeFromSuperlayer];
    
    [_VideoView.layer addSublayer:displayLayer];
}


- (void)parseNALU:(NSData *)NALU {
    int type = [self getNALUType: NALU];
    
    NSLog(@"NALU with Type \"%@\" received.", naluTypesStrings[type]);
    
    switch (type)
    {
        case NALUTypeSliceNoneIDR:
        case NALUTypeSliceIDR:
            [self handleSlice:NALU];
            break;
        case NALUTypeSPS:
            [self handleSPS:NALU];
            [self updateFormatDescriptionIfPossible];
            break;
        case NALUTypePPS:
            [self handlePPS:NALU];
            [self updateFormatDescriptionIfPossible];
            break;
        default:
            break;
    }
}

- (int)getNALUType:(NSData *)NALU {
    uint8_t * bytes = (uint8_t *) NALU.bytes;
    
    return bytes[0] & 0x1F;
}


- (void)handleSlice:(NSData *)NALU {
    if (self.videoFormatDescriptionAvailable) {
        /* The length of the NALU in big endian */
        const uint32_t NALUlengthInBigEndian = CFSwapInt32HostToBig((uint32_t) NALU.length);
        
        /* Create the slice */
        NSMutableData * slice = [[NSMutableData alloc] initWithBytes:&NALUlengthInBigEndian length:4];
        
        /* Append the contents of the NALU */
        [slice appendData:NALU];
        
        /* Create the video block */
        CMBlockBufferRef videoBlock = NULL;
        
        OSStatus status;
        
        status =
        CMBlockBufferCreateWithMemoryBlock
        (
         NULL,
         (void *) slice.bytes,
         slice.length,
         kCFAllocatorNull,
         NULL,
         0,
         slice.length,
         0,
         & videoBlock
         );
        
        NSLog(@"BlockBufferCreation: %@", (status == kCMBlockBufferNoErr) ? @"successfully." : @"failed.");
        
        /* Create the CMSampleBuffer */
        CMSampleBufferRef sbRef = NULL;
        
        const size_t sampleSizeArray[] = { slice.length };
        
        status =
        CMSampleBufferCreate
        (
         kCFAllocatorDefault,
         videoBlock,
         true,
         NULL,
         NULL,
         _videoFormatDescr,
         1,
         0,
         NULL,
         1,
         sampleSizeArray,
         & sbRef
         );
        
        NSLog(@"SampleBufferCreate: %@", (status == noErr) ? @"successfully." : @"failed.");
        
        /* Enqueue the CMSampleBuffer in the AVSampleBufferDisplayLayer */
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sbRef, YES);
        CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        
        NSLog(@"Error: %@, Status: %@",
              displayLayer.error,
              (displayLayer.status == AVQueuedSampleBufferRenderingStatusUnknown)
              ? @"unknown"
              : (
                 (displayLayer.status == AVQueuedSampleBufferRenderingStatusRendering)
                 ? @"rendering"
                 :@"failed"
                 )
              );
        
        dispatch_async(dispatch_get_main_queue(),^{
            [displayLayer enqueueSampleBuffer:sbRef];
            [displayLayer setNeedsDisplay];
        });
        
        NSLog(@" ");
    }
}

- (void)handleSPS:(NSData *)NALU {
    _spsData = [NALU copy];
}

- (void)handlePPS:(NSData *)NALU {
    _ppsData = [NALU copy];
}

- (void)updateFormatDescriptionIfPossible {
    if (_spsData != nil && _ppsData != nil) {
        const uint8_t * const parameterSetPointers[2] = {
            (const uint8_t *) _spsData.bytes,
            (const uint8_t *) _ppsData.bytes
        };
        
        const size_t parameterSetSizes[2] = {
            _spsData.length,
            _ppsData.length
        };
        
        OSStatus status =
        CMVideoFormatDescriptionCreateFromH264ParameterSets
        (
         kCFAllocatorDefault,
         2,
         parameterSetPointers,
         parameterSetSizes,
         4,
         & _videoFormatDescr
         );
        
        _videoFormatDescriptionAvailable = YES;
        
        NSLog(@"Updated CMVideoFormatDescription. Creation: %@.", (status == noErr) ? @"successfully." : @"failed.");
    }
}


- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}


@end
