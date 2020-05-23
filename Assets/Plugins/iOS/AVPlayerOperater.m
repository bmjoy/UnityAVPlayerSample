//
//  AVPlayerOperater.m
//  Copyright (c) 2020 東亜プリン秘密研究所. All rights reserved.
//

#import "AVPlayerOperater.h"

@interface AVPlayerOperater ()
{	
    MTLCommandQueueRef _commandQueue;
    CVMetalTextureCacheRef _textureCache;
    
    AVPlayer* _avPlayer;
    AVPlayerItemVideoOutput* _videoOutput;
    AVPlayerItem* _avPlayerItem;

    void* _videoSizeCallbackHandle;
    VideoSizeCallbackCaller _videoSizeCallbackCaller;

    NSUInteger _videoSizeWidth;
    NSUInteger _videoSizeHeight;
}

@property (nonnull, nonatomic) MTLDeviceRef metalDevice;
@property (strong, nonatomic) id<MTLTexture> inputTexture;
@property (strong, nonatomic) id<MTLTexture> outputTexture;
@property (assign, nonatomic) BOOL isLoopPlay;

@end

static NSKeyValueObservingOptions _ObservingOptions = NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew;
static void* _ObserveItemStatusContext = (void*)0x1;
static void* _ObservePresentationSizeContext = (void*)0x2;

@implementation AVPlayerOperater

#pragma mark - Public

#pragma mark Initialize

- (id)init
{
    return nil;
}

- (id)initWithIndex:(NSUInteger)index device:(MTLDeviceRef)device
{
    if (self = [super init]) {
        self.index = index;
        _avPlayer = [[AVPlayer alloc] init];
        // Metal
        _metalDevice = device;
        _commandQueue = [device newCommandQueue];
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &_textureCache);
        // Video
        NSDictionary<NSString*,id>* attributes = @{
            (NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
        };
        _videoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:attributes];
        // Callback
        self.playerCallback = [[AVPlayerCallback alloc] init];
    }
    return self;
}

#pragma mark APIs

- (id<MTLTexture>)getOutputTexture
{
    return _outputTexture;
}

- (void)setOutputTexture:(id<MTLTexture>)texture
{
    self.outputTexture = texture;
}

- (void)setPlayerItemWithPath:(NSString*)contentPath
{
    NSLog(@"AVPlayerOperater: setPlayerItemWithPath");
    if (contentPath == nil) {
        NSLog(@"AVPlayerOperater: contentPath is nil!");
        return;
    }
    NSURL* contentUrl = [NSURL URLWithString:contentPath];
    if (contentUrl == nil) {
        NSLog(@"AVPlayerOperater: contentUrl is nil!");
        return;
    }
    AVURLAsset* contentAsset = [AVURLAsset URLAssetWithURL:contentUrl options:nil];
    if (contentAsset == nil) {
        NSLog(@"AVPlayerOperater: contentAsset is nil!");
        return;
    }
    NSLog(@"AVPlayerOperater: contentPath = %@", contentPath);
    // Asset prepareing
    [self prepareAsset:contentAsset];
}

- (void)playWhenReady
{
    NSLog(@"AVPlayerOperater: playWhenReady");

    [_avPlayer play];
}

- (void)pauseWhenReady
{
    NSLog(@"AVPlayerOperater: pauseWhenReady");

    [_avPlayer pause];
}

- (void)seekWithSeconds:(float)seconds
{
    NSLog(@"AVPlayerOperater: seekWithSeconds");

    CMTime position = CMTimeMakeWithSeconds(seconds, NSEC_PER_SEC);
    [_avPlayer seekToTime:position completionHandler:^(BOOL finished) {
        // callback
        [self.playerCallback onSeek];
    }];
}

- (void)setPlayRate:(float)rate
{
    _avPlayer.rate = rate;
}

- (void)setVolume:(float)volume
{
    _avPlayer.volume = volume;
}

- (void)setLoop:(BOOL)loop
{
    _isLoopPlay = loop;
}

- (void)closeAll
{
    NSLog(@"AVPlayerOperater: closeAll");

    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self removeAVPlayerCurrentItemPresentationSizeObserver];
    [self removeAVPlayerItemStatusObserver];
    [_avPlayer replaceCurrentItemWithPlayerItem:nil];
    if (_avPlayerItem != nil) {
        [_avPlayerItem removeOutput:_videoOutput];
    }
    _avPlayerItem = nil;
}

- (float)getCurrentSconds
{
    Float64 currentPosition = _avPlayerItem != nil ? CMTimeGetSeconds(_avPlayerItem.currentTime) : -1.f;
    return (float)currentPosition;
}

- (float)getDuration
{
    Float64 duration = _avPlayerItem != nil ? CMTimeGetSeconds(_avPlayerItem.duration) : 0.f;
    return (float)duration;
}

- (BOOL)isPlaying
{
    return _avPlayer.rate != 0 ? true : false;
}

- (NSUInteger)getVideoWidth
{
    return _videoSizeWidth;
}

- (NSUInteger)getVideoHeight
{
    return _videoSizeHeight;
}

#pragma mark Render

- (void)updateVideo
{
    @synchronized (self) {
        [self readBuffer];
    }
}

#pragma mark - Callbacks

- (void)setVideoSizeCallbackWithHandle:(void*)handle caller:(VideoSizeCallbackCaller)caller
{
    _videoSizeCallbackHandle = handle;
    _videoSizeCallbackCaller = caller;
}

#pragma mark - Observers

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context
{
    NSLog(@"AVPlayerOperater: observeValueForKeyPath = %@", keyPath);

    if (context == _ObserveItemStatusContext) {
        AVPlayerStatus status = [[change objectForKey:NSKeyValueChangeNewKey] integerValue];
        if (status == AVPlayerItemStatusReadyToPlay) {
            [self removeAVPlayerItemStatusObserver];
            [self addAVPlayerCurrentItemPresentationSizeObserver];
            
            NSLog(@"AVPlayerOperater: status == AVPlayerItemStatusReadyToPlay");
        }
    }
    else if (context == _ObservePresentationSizeContext) {
        AVPlayerItem* playerItem = _avPlayer.currentItem;
        NSLog(@"AVPlayerOperater: New presentationSize (%f, %f)", playerItem.presentationSize.width, playerItem.presentationSize.height);
        if (_outputTexture == nil) {
            // Create output texture
            CGSize videoSize = CGSizeMake(playerItem.presentationSize.width, playerItem.presentationSize.height);
            [self createOutputTextureWithSize:videoSize];
            if (_outputTexture != nil) {
                // Notification
                [self addAVPlayerItemDidPlayToEndTimeNotification];
                // callback
                [self.playerCallback onReady];
            }
        }
        if (_outputTexture != nil) {
            // Video Size Callback
            _videoSizeWidth = playerItem.presentationSize.width;
            _videoSizeHeight = playerItem.presentationSize.height;
            if (_videoSizeCallbackHandle != nil && _videoSizeCallbackCaller != nil) {
                (_videoSizeCallbackCaller)(self, (int)_videoSizeWidth, (int)_videoSizeHeight, _videoSizeCallbackHandle);
            }
        }
    }
    else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)addAVPlayerItemStatusObserver
{
    if (_avPlayerItem == nil) {
        return;
    }
    [_avPlayerItem addObserver:self
                    forKeyPath:@"status"
                       options:_ObservingOptions
                       context:_ObserveItemStatusContext];
}

- (void)removeAVPlayerItemStatusObserver
{
    if (_avPlayerItem == nil) {
        return;
    }
    [_avPlayerItem removeObserver:self forKeyPath:@"status"];
}

- (void)addAVPlayerCurrentItemPresentationSizeObserver
{
    [_avPlayer addObserver:self
                forKeyPath:@"currentItem.presentationSize"
                   options:_ObservingOptions
                   context:_ObservePresentationSizeContext];
}

- (void)removeAVPlayerCurrentItemPresentationSizeObserver
{
    [_avPlayer removeObserver:self forKeyPath:@"currentItem.presentationSize"];
}

#pragma mark - Notifications

- (void)didPlayToEndTime:(NSNotification*)notification
{
    if (_isLoopPlay) {
        [_avPlayer seekToTime:kCMTimeZero completionHandler:^(BOOL finished) {
            [_avPlayer play];
        }];
    }
    else {
        [self.playerCallback onEndTime];
    }
}

- (void)addAVPlayerItemDidPlayToEndTimeNotification
{
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(didPlayToEndTime:)
                                               name:AVPlayerItemDidPlayToEndTimeNotification
                                             object:nil];
}

- (void)removeAVPlayerItemDidPlayToEndTimeNotification
{
    [NSNotificationCenter.defaultCenter removeObserver:self
                                                  name:AVPlayerItemDidPlayToEndTimeNotification
                                                object:nil];
}

#pragma mark - Private

-(void)prepareAsset:(AVAsset*)asset
{
    NSLog(@"AVPlayerOperater: prepareAsset");
    
    _avPlayerItem = [AVPlayerItem playerItemWithAsset:asset];
    [_avPlayerItem addOutput:_videoOutput];
    
    [self addAVPlayerItemStatusObserver];
    
    [_avPlayer replaceCurrentItemWithPlayerItem: _avPlayerItem];
}

- (void)createOutputTextureWithSize:(CGSize)videoSize
{
    if (videoSize.width == 0) {
        return;
    }
    if (videoSize.height == 0) {
        return;
    }
    MTLTextureDescriptor* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:videoSize.width
                                                                                         height:videoSize.height
                                                                                      mipmapped:NO];
    _outputTexture = [_metalDevice newTextureWithDescriptor:descriptor];
}

- (void)readBuffer
{
    if (_metalDevice == nil) {
        return;
    }

    CMTime currentTime = _avPlayer.currentTime;
    if (![_videoOutput hasNewPixelBufferForItemTime:currentTime]) {
        return;
    }

    @autoreleasepool
    {
        CVPixelBufferRef pixelBuffer = [_videoOutput copyPixelBufferForItemTime:currentTime
                                                             itemTimeForDisplay:nil];
        if (pixelBuffer != nil) {
            size_t width = CVPixelBufferGetWidth(pixelBuffer);
            size_t height = CVPixelBufferGetHeight(pixelBuffer);
            
            CVMetalTextureRef cvTextureOut = nil;
            CVReturn status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                                        _textureCache,
                                                                        pixelBuffer,
                                                                        nil,
                                                                        MTLPixelFormatBGRA8Unorm,
                                                                        width,
                                                                        height,
                                                                        0,
                                                                        &cvTextureOut);
            if(status == kCVReturnSuccess) {
                _inputTexture = CVMetalTextureGetTexture(cvTextureOut);
                CFRelease(cvTextureOut);
            }
            CFRelease(pixelBuffer);
            
            [self copyTextureWithWidth:width height:height];
        }
    } // autoreleasepool
}

- (void)copyTextureWithWidth:(NSUInteger)width height:(NSUInteger)height
{
    if (_inputTexture == nil) {
        return;
    }
    if (_outputTexture == nil) {
        return;
    }

    MTLCommandBufferRef commandBuffer = [_commandQueue commandBuffer];
    id<MTLBlitCommandEncoder> encoder = [commandBuffer blitCommandEncoder];
    [encoder copyFromTexture:_inputTexture
                 sourceSlice:0
                 sourceLevel:0
                sourceOrigin:MTLOriginMake(0, 0, 0)
                  sourceSize:MTLSizeMake(width, height, _inputTexture.depth)
                   toTexture:_outputTexture
            destinationSlice:0
            destinationLevel:0
           destinationOrigin:MTLOriginMake(0, 0, 0)];
    [encoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
}

@end
