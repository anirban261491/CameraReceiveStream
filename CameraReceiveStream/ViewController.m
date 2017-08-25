//
//  ViewController.m
//  CameraReceiveStream
//
//  Created by Anirban Bhattacharya (Student) on 8/25/17.
//  Copyright © 2017 Anirban Bhattacharya (Student). All rights reserved.
//

#import "ViewController.h"

@interface ViewController ()

@end

@implementation ViewController
GCDAsyncUdpSocket *udpSocket;
AVSampleBufferDisplayLayer* displayLayer;
- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    dispatch_queue_t queue = dispatch_queue_create("com.livestream.queue", DISPATCH_QUEUE_SERIAL);
    udpSocket = [[GCDAsyncUdpSocket alloc] initWithDelegate:self delegateQueue:queue];
    [self initializeDisplayLayer];
    [self startServer];
}

-(void)startServer
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
    
    OSStatus status;
    
    uint8_t *vData = NULL;
    uint8_t *pps = NULL;
    uint8_t *sps = NULL;
    uint8_t *frame=(uint8_t*)[data bytes];
    uint32_t *frameSize = (uint32_t*)[data length];
    
    
    int startCodeIndex = 0;
    int secondStartCodeIndex = 0;
    int thirdStartCodeIndex = 0;
    
    long blockLength = 0;
    
    CMSampleBufferRef sampleBuffer = NULL;
    CMBlockBufferRef blockBuffer = NULL;
    
    int nalu_type = (frame[startCodeIndex + 4] & 0x1F);
    //NSLog(@"~~~~~~~ Received NALU Type \"%@\" ~~~~~~~~", naluTypesStrings[nalu_type]);
    if (nalu_type == 7)
    {
        // find where the second PPS start code begins, (the 0x00 00 00 01 code)
        // from which we also get the length of the first SPS code
        for (int i = startCodeIndex + 4; i < startCodeIndex + 40; i++)
        {
            if (frame[i] == 0x00 && frame[i+1] == 0x00 && frame[i+2] == 0x00 && frame[i+3] == 0x01)
            {
                secondStartCodeIndex = i;
                _spsSize = secondStartCodeIndex;   // includes the header in the size
                break;
            }
        }
        nalu_type = (frame[secondStartCodeIndex + 4] & 0x1F);
        //NSLog(@"~~~~~~~ Received NALU Type \"%@\" ~~~~~~~~", naluTypesStrings[nalu_type]);
    }
    
    if(nalu_type == 8) {
        
        // find where the NALU after this one starts so we know how long the PPS parameter is
        for (int i = _spsSize + 12; i < _spsSize + 50; i++)
        {
            if (frame[i] == 0x00 && frame[i+1] == 0x00 && frame[i+2] == 0x00 && frame[i+3] == 0x01)
            {
                thirdStartCodeIndex = i;
                _ppsSize = thirdStartCodeIndex - _spsSize;
                break;
            }
        }
        
        sps = malloc(_spsSize - 4);
        pps = malloc(_ppsSize - 4);
        
        memcpy (sps, &frame[4], _spsSize-4);
        memcpy (pps, &frame[_spsSize+4], _ppsSize-4);
        
        uint8_t*  parameterSetPointers[2] = {sps, pps};
        size_t parameterSetSizes[2] = {_spsSize-4, _ppsSize-4};
        
        status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2,
                                                                     (const uint8_t *const*)parameterSetPointers,
                                                                     parameterSetSizes, 4,
                                                                     &_formatDesc);
        
        NSLog(@"\t\t Creation of CMVideoFormatDescription: %@", (status == noErr) ? @"successful!" : @"failed...");
        if(status != noErr) NSLog(@"\t\t Format Description ERROR type: %d", (int)status);
        
        nalu_type = (frame[thirdStartCodeIndex + 4] & 0x1F);
    }
    
    if((status == noErr) && (_decompressionSession == NULL))
    {
        [self createDecompSession];
    }
    
    
    if(nalu_type == 5)
    {
        // find the offset, or where the SPS and PPS NALUs end and the IDR frame NALU begins
        int offset = _spsSize + _ppsSize;
        blockLength = frameSize - offset;
        //        NSLog(@"Block Length : %ld", blockLength);
        vData = malloc(blockLength);
        vData = memcpy(vData, &frame[offset], blockLength);
        
        // replace the start code header on this NALU with its size.
        // AVCC format requires that you do this.
        // htonl converts the unsigned int from host to network byte order
        uint32_t dataLength32 = htonl (blockLength - 4);
        memcpy (vData, &dataLength32, sizeof (uint32_t));
        
        // create a block buffer from the IDR NALU
        status = CMBlockBufferCreateWithMemoryBlock(NULL, vData,  // memoryBlock to hold buffered data
                                                    blockLength,  // block length of the mem block in bytes.
                                                    kCFAllocatorNull, NULL,
                                                    0, // offsetToData
                                                    blockLength,   // dataLength of relevant bytes, starting at offsetToData
                                                    0, &blockBuffer);
        
        NSLog(@"\t\t BlockBufferCreation: \t %@", (status == kCMBlockBufferNoErr) ? @"successful!" : @"failed...");
    }
    
    if (nalu_type == 1)
    {
        // non-IDR frames do not have an offset due to SPS and PSS, so the approach
        // is similar to the IDR frames just without the offset
        blockLength = frameSize;
        vData = malloc(blockLength);
        vData = memcpy(vData, &frame[0], blockLength);
        
        // again, replace the start header with the size of the NALU
        uint32_t dataLength32 = htonl (blockLength - 4);
        memcpy (vData, &dataLength32, sizeof (uint32_t));
        
        status = CMBlockBufferCreateWithMemoryBlock(NULL, vData,  // memoryBlock to hold data. If NULL, block will be alloc when needed
                                                    blockLength,  // overall length of the mem block in bytes
                                                    kCFAllocatorNull, NULL,
                                                    0,     // offsetToData
                                                    blockLength,  // dataLength of relevant data bytes, starting at offsetToData
                                                    0, &blockBuffer);
        
        NSLog(@"\t\t BlockBufferCreation: \t %@", (status == kCMBlockBufferNoErr) ? @"successful!" : @"failed...");
    }
    
    // now create our sample buffer from the block buffer,
    if(status == noErr)
    {
        // here I'm not bothering with any timing specifics since in my case we displayed all frames immediately
        const size_t sampleSize = blockLength;
        status = CMSampleBufferCreate(kCFAllocatorDefault,
                                      blockBuffer, true, NULL, NULL,
                                      _formatDesc, 1, 0, NULL, 1,
                                      &sampleSize, &sampleBuffer);
        
        NSLog(@"\t\t SampleBufferCreate: \t %@", (status == noErr) ? @"successful!" : @"failed...");
    }
    
    if(status == noErr)
    {
        // set some values of the sample buffer's attachments
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, YES);
        CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        
        // either send the samplebuffer to a VTDecompressionSession or to an AVSampleBufferDisplayLayer
        [self render:sampleBuffer];
    }
    
    // free memory to avoid a memory leak, do the same for sps, pps and blockbuffer
    if (NULL != vData)
    {
        free (vData);
        data = NULL;
    }
    
}

-(void) createDecompSession
{
    // make sure to destroy the old VTD session
    _decompressionSession = NULL;
    VTDecompressionOutputCallbackRecord callBackRecord;
    callBackRecord.decompressionOutputCallback = decompressionSessionDecodeFrameCallback;
    
    // this is necessary if you need to make calls to Objective C "self" from within in the callback method.
    callBackRecord.decompressionOutputRefCon = (__bridge void *)self;
    
    // you can set some desired attributes for the destination pixel buffer.  I didn't use this but you may
    // if you need to set some attributes, be sure to uncomment the dictionary in VTDecompressionSessionCreate
    /*NSDictionary *destinationImageBufferAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
     [NSNumber numberWithBool:YES],
     (id)kCVPixelBufferOpenGLESCompatibilityKey,
     nil];*/
    
    OSStatus status =  VTDecompressionSessionCreate(NULL, _formatDesc, NULL,
                                                    NULL, // (__bridge CFDictionaryRef)(destinationImageBufferAttributes)
                                                    &callBackRecord, &_decompressionSession);
    NSLog(@"Video Decompression Session Create: \t %@", (status == noErr) ? @"successful!" : @"failed...");
    if(status != noErr) NSLog(@"\t\t VTD ERROR type: %d", (int)status);

}


void decompressionSessionDecodeFrameCallback(void *decompressionOutputRefCon,
                                             void *sourceFrameRefCon,
                                             OSStatus status,
                                             VTDecodeInfoFlags infoFlags,
                                             CVImageBufferRef imageBuffer,
                                             CMTime presentationTimeStamp,
                                             CMTime presentationDuration)
{
    
    if (status != noErr)
    {
        NSError *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
        NSLog(@"Decompressed error: %@", error);
    }
    else
    {
        NSLog(@"Decompressed sucessfully");
    }
}


- (void) render:(CMSampleBufferRef)sampleBuffer
{
    /*
     VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression;
     VTDecodeInfoFlags flagOut;
     NSDate* currentTime = [NSDate date];
     VTDecompressionSessionDecodeFrame(_decompressionSession, sampleBuffer, flags,
     (void*)CFBridgingRetain(currentTime), &flagOut);
     
     CFRelease(sampleBuffer);*/
    
    // if you're using AVSampleBufferDisplayLayer, you only need to use this line of code
    if (displayLayer) {
        NSLog(@"Success ****");
        [displayLayer enqueueSampleBuffer:sampleBuffer];
    }
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



- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}


@end
