//
//  LPPrototypeCaptureRecorder.m
//  PrototypeCapture
//
//  Created by Игорь Савельев on 28/02/16.
//  Copyright © 2016 Leonspok. All rights reserved.
//

#import "LPPrototypeCaptureRecorder.h"
#import "LPViewTouchesRecognizer.h"

@import AVFoundation;

@interface LPPrototypeCaptureRecorder() <UIGestureRecognizerDelegate>
@property (nonatomic, strong) NSString *currentRecordFolder;
//@property (nonatomic, strong) CADisplayLink *recordingDisplayLink;
@property (nonatomic, strong) NSTimer *captureTargetViewTimer;
@property (nonatomic, strong) NSTimer *recordVideoTimer;
@property (nonatomic, strong) NSDate *currentRecordStartTime;
@property (nonatomic, strong) AVAssetWriter *videoWriter;
@property (nonatomic, strong) AVAssetWriterInput *videoWriterInput;
@property (nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor *pixelBufferAdaptor;
@property (nonatomic, strong) UIImage *targetViewSnapshot;
@property (nonatomic, strong) LPViewTouchesRecognizer *touchesRecognizer;

@end

@implementation LPPrototypeCaptureRecorder {
    dispatch_queue_t writeQueue;
    dispatch_queue_t snapshotQueue;
    dispatch_semaphore_t semaphore;
    CGRect capturingFrame;
    CGContextRef touchesDrawingContext;
    NSUInteger frameCounter;
    NSMutableArray *frames;
}

- (id)initWithTargetView:(UIView *)view baseFolder:(NSString *)baseFolder {
    self = [super init];
    if (self) {
        _targetView = view;
        _baseFolder = baseFolder;
        self.fps = 12;
        self.downscale = 2.0f;
        
        writeQueue = dispatch_queue_create("Recording Queue", DISPATCH_QUEUE_CONCURRENT);
        snapshotQueue = dispatch_queue_create("Snapshot Queue", DISPATCH_QUEUE_CONCURRENT);
        
        semaphore = dispatch_semaphore_create(1);
        frames = [NSMutableArray array];
        touchesDrawingContext = NULL;
    }
    return self;
}

#pragma mark Recording

- (void)getSnapshotCompletion:(void (^)(UIImage *))completion {
    UIGraphicsBeginImageContextWithOptions(capturingFrame.size, YES, 1.0f);
    
    if (self.withTouches) {
        CGAffineTransform flipVertical = CGAffineTransformMake(1, 0, 0, -1, 0, capturingFrame.size.height);
        CGContextConcatCTM(UIGraphicsGetCurrentContext(), flipVertical);
    }
    
    [self.targetView drawViewHierarchyInRect:capturingFrame afterScreenUpdates:NO];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    
    UIGraphicsEndImageContext();
    
    if (self.withTouches) {
        NSArray<LPViewTouch *> *touches = [self.touchesRecognizer currentTouches];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            if (!self.recording || touchesDrawingContext == NULL) {
                return;
            }
            
            CGContextDrawImage(touchesDrawingContext, capturingFrame, image.CGImage);
            
            size_t gradLocationsNum = 2;
            CGFloat gradLocations[2] = {0.0f, 1.0f};
            CGFloat gradColors[8] = {0.0f,0.0f,0.0f,0.0f,0.0f,0.0f,0.0f,0.5f};
            CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
            CGGradientRef gradient = CGGradientCreateWithColorComponents(colorSpace, gradColors, gradLocations, gradLocationsNum);
            CGColorSpaceRelease(colorSpace);
            
            for (LPViewTouch *touch in touches) {
                CGPoint location = touch.location;
                location.x /= self.downscale;
                location.y /= self.downscale;
                CGFloat radius = touch.radius/self.downscale;
                CGFloat shadowRadius = touch.shadowRadius/self.downscale;
                CGFloat alpha = touch.alpha;
                
                CGPathRef path = CGPathCreateWithEllipseInRect(CGRectMake(location.x-radius, location.y-radius, radius*2, radius*2), NULL);
                CGContextBeginPath(touchesDrawingContext);
                CGContextAddPath(touchesDrawingContext, path);
                
                CGContextSetFillColorWithColor(touchesDrawingContext, [UIColor colorWithWhite:0.95f alpha:alpha].CGColor);
                CGContextFillPath(touchesDrawingContext);
                CGPathRelease(path);
                
                CGContextDrawRadialGradient(touchesDrawingContext, gradient, location, (radius+shadowRadius), location, radius, kCGGradientDrawsBeforeStartLocation);
            }
            
            CGGradientRelease(gradient);
            
            CGImageRef cgImage = CGBitmapContextCreateImage(touchesDrawingContext);
            UIImage *snapshotImage = [[UIImage alloc] initWithCGImage:cgImage];
            CGImageRelease(cgImage);
            
            if (completion) {
                completion(snapshotImage);
            }
        });
    } else {
        if (completion) {
            completion(image);
        }
    }
}

- (CVPixelBufferRef)pixelBufferFromCGImage:(CGImageRef)image {
    CGSize frameSize = CGSizeMake(CGImageGetWidth(image), CGImageGetHeight(image));
    NSDictionary *options = @{(__bridge NSString *)kCVPixelBufferCGImageCompatibilityKey: @(YES),
                              (__bridge NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @(YES)};
    CVPixelBufferRef pixelBuffer;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, frameSize.width, frameSize.height,  kCVPixelFormatType_32ARGB, (__bridge CFDictionaryRef) options, &pixelBuffer);
    if (status != kCVReturnSuccess) {
        return NULL;
    }
    
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void *data = CVPixelBufferGetBaseAddress(pixelBuffer);
    CGColorSpaceRef rgbColorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(data, frameSize.width, frameSize.height, 8, CVPixelBufferGetBytesPerRow(pixelBuffer), rgbColorSpace, (CGBitmapInfo) kCGImageAlphaNoneSkipFirst);
    CGContextDrawImage(context, CGRectMake(0, 0, CGImageGetWidth(image), CGImageGetHeight(image)), image);
    CGColorSpaceRelease(rgbColorSpace);
    CGContextRelease(context);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    
    return pixelBuffer;
}

- (void)recordSnapshot:(UIImage *)snapshot timestamp:(NSTimeInterval)timestamp {
    dispatch_async(writeQueue, ^{
        while(!self.pixelBufferAdaptor.assetWriterInput.readyForMoreMediaData) {}
        
        CVPixelBufferRef pixelBuffer = [self pixelBufferFromCGImage:snapshot.CGImage];
        BOOL appended = YES;
        if (pixelBuffer != NULL) {
            appended = [self.pixelBufferAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:CMTimeMake((int64_t)frameCounter, (int32_t)self.fps)];
            CVPixelBufferRelease(pixelBuffer);
        }
        frameCounter++;
    });
}

- (void)captureFrame {
    if (dispatch_semaphore_wait(semaphore, DISPATCH_TIME_NOW) == 0) {
        [self getSnapshotCompletion:^(UIImage *image) {
            dispatch_semaphore_signal(semaphore);
            self.targetViewSnapshot = image;
        }];
    }
}

- (void)recordFrame {
    NSTimeInterval timestamp = [[NSDate date] timeIntervalSinceDate:self.currentRecordStartTime];
    [self recordSnapshot:self.targetViewSnapshot timestamp:timestamp];
}

#pragma mark Managing

- (void)prepareForRecording {
    if (self.recording) {
        return;
    }
    
    //Init folder
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd HH.mm.ss"];
    NSString *folderName = [formatter stringFromDate:[NSDate date]];
    NSString *newRecordingFolder = [self.baseFolder stringByAppendingPathComponent:folderName];
    [[NSFileManager defaultManager] createDirectoryAtPath:newRecordingFolder withIntermediateDirectories:NO attributes:nil error:nil];
    self.currentRecordFolder = newRecordingFolder;
    
    capturingFrame = (CGRect){CGPointZero, CGSizeMake(floor(self.targetView.bounds.size.width/self.downscale), floor(self.targetView.bounds.size.height/self.downscale))};
    
    //Video writer
    NSError *error = nil;
    self.videoWriter = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:[self.currentRecordFolder stringByAppendingPathComponent:@"video.mp4"]] fileType:AVFileTypeMPEG4 error:&error];
    NSParameterAssert(self.videoWriter);
    
    NSDictionary *videoSettings = [NSDictionary dictionaryWithObjectsAndKeys:AVVideoCodecH264, AVVideoCodecKey, @(capturingFrame.size.width), AVVideoWidthKey, @(capturingFrame.size.height), AVVideoHeightKey, nil];
    AVAssetWriterInput* writerInput = [AVAssetWriterInput                                  assetWriterInputWithMediaType:AVMediaTypeVideo                                        outputSettings:videoSettings];
    NSParameterAssert(writerInput);
    NSParameterAssert([self.videoWriter canAddInput:writerInput]);
    self.videoWriterInput.expectsMediaDataInRealTime = YES;
    [self.videoWriter addInput:writerInput];
    
    self.pixelBufferAdaptor = [AVAssetWriterInputPixelBufferAdaptor                                                  assetWriterInputPixelBufferAdaptorWithAssetWriterInput:writerInput sourcePixelBufferAttributes:nil];
    
    //Touches
    if (!self.withTouches || self.touchesRecognizer) {
        [self.touchesRecognizer.view removeGestureRecognizer:self.touchesRecognizer];
        self.touchesRecognizer = nil;
    }
    if (touchesDrawingContext != NULL) {
        CGContextRelease(touchesDrawingContext);
        touchesDrawingContext = NULL;
    }
    
    if (self.withTouches) {
        self.touchesRecognizer = [[LPViewTouchesRecognizer alloc] init];
        [self.targetView addGestureRecognizer:self.touchesRecognizer];
        self.touchesRecognizer.delegate = self;
        self.targetView.multipleTouchEnabled = YES;
        
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        touchesDrawingContext = CGBitmapContextCreate(nil, capturingFrame.size.width, capturingFrame.size.height, 8, capturingFrame.size.width * (CGColorSpaceGetNumberOfComponents(colorSpace) + 1), colorSpace, kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(colorSpace);
        
        CGAffineTransform flipVertical = CGAffineTransformMake(1, 0, 0, -1, 0, capturingFrame.size.height);
        CGContextConcatCTM(touchesDrawingContext, flipVertical);
    }
    
    _readyToRecord = YES;
}

- (void)startRecording {
    if (!self.isReadyToRecord || self.isRecording) {
        return;
    }
    _recording = YES;
    
    self.captureTargetViewTimer = [NSTimer scheduledTimerWithTimeInterval:1.0f/self.fps target:self selector:@selector(captureFrame) userInfo:nil repeats:YES];
    self.recordVideoTimer = [NSTimer scheduledTimerWithTimeInterval:1.0f/self.fps target:self selector:@selector(recordFrame) userInfo:nil repeats:YES];
    
    self.currentRecordStartTime = [NSDate date];
    
    [self.videoWriter startWriting];
    [self.videoWriter startSessionAtSourceTime:kCMTimeZero];
    
    frameCounter = 0;
    
    [self captureFrame];
    [self recordFrame];
}

- (void)stopRecording {
    [self.captureTargetViewTimer invalidate];
    self.captureTargetViewTimer = nil;
    [self.recordVideoTimer invalidate];
    self.recordVideoTimer = nil;
    
    [self.videoWriterInput markAsFinished];
    [self.videoWriter endSessionAtSourceTime:CMTimeMake([[NSDate date] timeIntervalSinceDate:self.currentRecordStartTime], 1)];
    [self.videoWriter finishWritingWithCompletionHandler:^{
        
    }];
    
    if (self.withTouches || self.touchesRecognizer) {
        [self.touchesRecognizer.view removeGestureRecognizer:self.touchesRecognizer];
        self.touchesRecognizer = nil;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0f * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self.recording && touchesDrawingContext != NULL) {
            CGContextRelease(touchesDrawingContext);
            touchesDrawingContext = NULL;
        }
    });
    
    _recording = NO;
    _readyToRecord = NO;
}

#pragma mark UIGestureRecognizerDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceivePress:(UIPress *)press {
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

@end
