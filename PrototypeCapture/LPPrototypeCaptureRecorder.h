//
//  LPPrototypeCaptureRecorder.h
//  PrototypeCapture
//
//  Created by Игорь Савельев on 28/02/16.
//  Copyright © 2016 Leonspok. All rights reserved.
//

#import <Foundation/Foundation.h>

@import UIKit;

typedef enum {
    LPPrototypeCaptureRecorderStatusConfiguring,
    LPPrototypeCaptureRecorderStatusReadyToRecord,
    LPPrototypeCaptureRecorderStatusRecording,
    LPPrototypeCaptureRecorderStatusRecordingError,
    LPPrototypeCaptureRecorderStatusReadyToRender,
    LPPrototypeCaptureRecorderStatusRendering,
    LPPrototypeCaptureRecorderStatusRenderingError,
    LPPrototypeCaptureRecorderStatusFinished
} LPPrototypeCaptureRecorderStatus;

@interface LPPrototypeCaptureRecorder : NSObject

@property (nonatomic, strong, readonly) NSString *folder;
@property (nonatomic, strong, readonly) UIView *targetView;
@property (nonatomic) NSUInteger fps;
@property (nonatomic) CGFloat downscale;
@property (nonatomic) BOOL withTouches;
@property (nonatomic) BOOL withTouchesLogging;
@property (nonatomic) BOOL withFrontCamera;

@property (nonatomic, readonly) LPPrototypeCaptureRecorderStatus status;
@property (nonatomic, strong, readonly) NSError *recordingError;
@property (nonatomic, strong, readonly) NSError *renderingError;
@property (nonatomic, readonly) NSTimeInterval recordingDuration;

@property (nonatomic, strong, readonly) NSString *pathToCameraCaptureVideo;
@property (nonatomic, strong, readonly) NSString *pathToScreenCaptureVideo;
@property (nonatomic, strong, readonly) NSString *pathToRenderedVideo;
@property (nonatomic, strong, readonly) NSString *pathToResultVideo;

@property (nonatomic, strong) void (^renderingProgressBlock)(float progress);

- (id)initWithTargetView:(UIView *)view folder:(NSString *)folder;

- (void)prepareForRecording;
- (void)startRecording;
- (void)stopRecording;
- (void)render;

#pragma mark Screens

- (void)screenChangedTo:(NSString *)screenName;

+ (NSString *)pathToScreensFolderFromFolder:(NSString *)folder;
+ (NSString *)pathToRecordedScreensFileFromFolder:(NSString *)folder;
+ (NSString *)pathToTouchesLogForScreen:(NSString *)screen andFolder:(NSString *)folder;
+ (NSString *)pathToScreenshotForScreen:(NSString *)screen andFolder:(NSString *)folder;

@end
