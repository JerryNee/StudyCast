//
//  GStreamerPreviewEngine.mm
//  StudyCast
//

#import "GStreamerPreviewEngine.h"

#import <AppKit/AppKit.h>
#import <gst/app/gstappsink.h>
#import <gst/gst.h>
#import <gst/video/video.h>

@interface GStreamerPreviewEngine ()
@property(nonatomic, copy, nullable) GStreamerPreviewFrameHandler frameHandler;
@property(nonatomic, copy, nullable) GStreamerPreviewErrorHandler errorHandler;
- (BOOL)startAudioPipelineWithOutputDeviceID:(NSInteger)audioOutputDeviceID;
- (void)stopAudioPipelineLocked;
@end

@implementation GStreamerPreviewEngine {
    GstElement *_videoPipeline;
    GstElement *_audioPipeline;
    GstElement *_videoSink;
    GstElement *_volumeElement;
    dispatch_queue_t _stateQueue;
    NSInteger _audioPort;
    BOOL _muted;
    double _volume;
}

+ (void)configureRuntimeEnvironment {
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *resourcePath = bundle.resourcePath ?: @"";
    NSString *frameworksPath = [bundle.privateFrameworksPath stringByAppendingPathComponent:@"GStreamer"];
    NSString *pluginsPath = [frameworksPath stringByAppendingPathComponent:@"plugins"];
    NSString *scannerPath = [[bundle.bundleURL URLByAppendingPathComponent:@"Contents/Helpers/gst-plugin-scanner"].path copy];
    NSString *cachePath = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    NSString *registryDirectory = [cachePath stringByAppendingPathComponent:@"StudyCast"];
    NSString *registryPath = [registryDirectory stringByAppendingPathComponent:@"gstreamer-registry.bin"];

    [[NSFileManager defaultManager] createDirectoryAtPath:registryDirectory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:registryPath error:nil];

    if ([[NSFileManager defaultManager] fileExistsAtPath:pluginsPath]) {
        setenv("GST_PLUGIN_PATH", pluginsPath.UTF8String, 1);
        setenv("GST_PLUGIN_SYSTEM_PATH", pluginsPath.UTF8String, 1);
    }
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:scannerPath]) {
        setenv("GST_PLUGIN_SCANNER", scannerPath.UTF8String, 1);
    }
    if (registryPath.length > 0) {
        setenv("GST_REGISTRY", registryPath.UTF8String, 1);
    }
    if (resourcePath.length > 0) {
        setenv("GST_DEBUG_NO_COLOR", "1", 1);
    }
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _stateQueue = dispatch_queue_create("StudyCast.GStreamerPreviewEngine.state", DISPATCH_QUEUE_SERIAL);
        _volume = 1.0;
    }
    return self;
}

- (BOOL)startWithVideoPort:(NSInteger)videoPort
                 audioPort:(NSInteger)audioPort
       audioOutputDeviceID:(NSInteger)audioOutputDeviceID
                   onFrame:(GStreamerPreviewFrameHandler)onFrame
                   onError:(GStreamerPreviewErrorHandler)onError {
    [self stop];
    self.frameHandler = onFrame;
    self.errorHandler = onError;
    _audioPort = audioPort;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [GStreamerPreviewEngine configureRuntimeEnvironment];
        gst_init(NULL, NULL);
    });

    GError *error = NULL;
    NSString *videoLaunch = [NSString stringWithFormat:
        @"udpsrc port=%ld caps=\"application/x-rtp,media=(string)video,encoding-name=(string)H264,payload=(int)96,clock-rate=(int)90000\" "
         "! rtpjitterbuffer latency=80 drop-on-latency=true "
         "! rtph264depay ! h264parse ! vtdec "
         "! videoconvert "
         "! appsink name=video_sink emit-signals=true max-buffers=1 drop=true sync=false",
        (long)videoPort
    ];
    _videoPipeline = gst_parse_launch(videoLaunch.UTF8String, &error);
    if (![self handleParseError:error context:@"视频预览管线创建失败"] || !_videoPipeline) {
        return NO;
    }

    _videoSink = gst_bin_get_by_name(GST_BIN(_videoPipeline), "video_sink");
    if (!_videoSink) {
        [self emitError:@"预览管线缺少必要组件"];
        [self stop];
        return NO;
    }

    GstCaps *videoCaps = gst_caps_from_string("video/x-raw,format=BGRx");
    if (videoCaps) {
        gst_app_sink_set_caps(GST_APP_SINK(_videoSink), videoCaps);
        gst_caps_unref(videoCaps);
    }

    g_signal_connect(_videoSink, "new-sample", G_CALLBACK(newVideoSample), (__bridge void *)self);
    [self installBusHandlerForPipeline:_videoPipeline];
    if (![self startAudioPipelineWithOutputDeviceID:audioOutputDeviceID]) {
        [self emitError:@"音频输出不可用"];
    }

    GstStateChangeReturn videoState = gst_element_set_state(_videoPipeline, GST_STATE_PLAYING);
    if (videoState == GST_STATE_CHANGE_FAILURE) {
        [self emitError:@"预览管线启动失败"];
        [self stop];
        return NO;
    }

    return YES;
}

- (BOOL)restartAudioWithOutputDeviceID:(NSInteger)audioOutputDeviceID {
    __block BOOL started = NO;
    dispatch_sync(_stateQueue, ^{
        [self stopAudioPipelineLocked];
        started = [self startAudioPipelineWithOutputDeviceID:audioOutputDeviceID];
    });
    return started;
}

- (void)stop {
    dispatch_sync(_stateQueue, ^{
        if (_videoPipeline) {
            gst_element_set_state(_videoPipeline, GST_STATE_NULL);
        }
        [self stopAudioPipelineLocked];
        if (_videoSink) {
            gst_object_unref(_videoSink);
            _videoSink = NULL;
        }
        if (_videoPipeline) {
            gst_object_unref(_videoPipeline);
            _videoPipeline = NULL;
        }
        _audioPort = 0;
    });
}

- (void)setMuted:(BOOL)muted {
    dispatch_async(_stateQueue, ^{
        _muted = muted;
        [self applyVolume];
    });
}

- (void)setVolume:(double)volume {
    dispatch_async(_stateQueue, ^{
        _volume = MIN(MAX(volume, 0.0), 1.0);
        [self applyVolume];
    });
}

- (BOOL)handleParseError:(GError *)error context:(NSString *)context {
    if (!error) {
        return YES;
    }
    NSString *message = [NSString stringWithFormat:@"%@: %s", context, error->message];
    g_error_free(error);
    [self emitError:message];
    return NO;
}

- (void)applyVolume {
    if (!_volumeElement) {
        return;
    }
    g_object_set(_volumeElement, "mute", _muted ? TRUE : FALSE, "volume", _volume, NULL);
}

- (BOOL)startAudioPipelineWithOutputDeviceID:(NSInteger)audioOutputDeviceID {
    if (_audioPort <= 0 || audioOutputDeviceID < 0) {
        return YES;
    }

    GError *error = NULL;
    NSString *sink = audioOutputDeviceID > 0
        ? [NSString stringWithFormat:@"osxaudiosink device=%ld sync=false", (long)audioOutputDeviceID]
        : @"osxaudiosink sync=false";
    NSString *audioLaunch = [NSString stringWithFormat:
        @"udpsrc port=%ld caps=\"application/x-rtp,media=(string)audio,encoding-name=(string)L16,encoding-params=(string)2,payload=(int)97,clock-rate=(int)44100,channels=(int)2\" "
         "! rtpjitterbuffer latency=80 "
         "! rtpL16depay ! audioconvert ! audioresample "
         "! volume name=preview_volume "
         "! %@",
        (long)_audioPort,
        sink
    ];

    _audioPipeline = gst_parse_launch(audioLaunch.UTF8String, &error);
    if (![self handleParseError:error context:@"音频预览管线创建失败"] || !_audioPipeline) {
        [self stopAudioPipelineLocked];
        return NO;
    }

    _volumeElement = gst_bin_get_by_name(GST_BIN(_audioPipeline), "preview_volume");
    if (!_volumeElement) {
        [self emitError:@"音频预览管线缺少音量组件"];
        [self stopAudioPipelineLocked];
        return NO;
    }

    [self installBusHandlerForPipeline:_audioPipeline];
    [self applyVolume];

    GstStateChangeReturn audioState = gst_element_set_state(_audioPipeline, GST_STATE_PLAYING);
    if (audioState == GST_STATE_CHANGE_FAILURE) {
        [self emitError:@"音频输出启动失败"];
        [self stopAudioPipelineLocked];
        return NO;
    }

    return YES;
}

- (void)stopAudioPipelineLocked {
    if (_audioPipeline) {
        gst_element_set_state(_audioPipeline, GST_STATE_NULL);
    }
    if (_volumeElement) {
        gst_object_unref(_volumeElement);
        _volumeElement = NULL;
    }
    if (_audioPipeline) {
        gst_object_unref(_audioPipeline);
        _audioPipeline = NULL;
    }
}

- (void)installBusHandlerForPipeline:(GstElement *)pipeline {
    GstBus *bus = gst_element_get_bus(pipeline);
    if (!bus) {
        return;
    }
    gst_bus_set_sync_handler(bus, busSyncHandler, (__bridge void *)self, NULL);
    gst_object_unref(bus);
}

- (void)emitError:(NSString *)message {
    GStreamerPreviewErrorHandler handler = self.errorHandler;
    if (!handler) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(message);
    });
}

static GstBusSyncReply busSyncHandler(GstBus *bus, GstMessage *message, gpointer userData) {
    (void)bus;
    if (GST_MESSAGE_TYPE(message) != GST_MESSAGE_ERROR) {
        return GST_BUS_PASS;
    }

    GError *error = NULL;
    gchar *debugInfo = NULL;
    gst_message_parse_error(message, &error, &debugInfo);
    GStreamerPreviewEngine *engine = (__bridge GStreamerPreviewEngine *)userData;
    GstObject *source = GST_MESSAGE_SRC(message);
    BOOL isAudioError = NO;
    if (source && engine->_audioPipeline) {
        GstObject *audioPipeline = GST_OBJECT(engine->_audioPipeline);
        isAudioError = source == audioPipeline || gst_object_has_as_ancestor(source, audioPipeline);
    }

    NSString *prefix = isAudioError ? @"音频输出不可用" : @"预览不可用";
    NSString *messageText = error
        ? [NSString stringWithFormat:@"%@: %s", prefix, error->message]
        : prefix;

    [engine emitError:messageText];

    if (error) {
        g_error_free(error);
    }
    if (debugInfo) {
        g_free(debugInfo);
    }
    return GST_BUS_PASS;
}

static GstFlowReturn newVideoSample(GstElement *sink, gpointer userData) {
    GstSample *sample = gst_app_sink_pull_sample(GST_APP_SINK(sink));
    if (!sample) {
        return GST_FLOW_OK;
    }

    GstCaps *caps = gst_sample_get_caps(sample);
    GstBuffer *buffer = gst_sample_get_buffer(sample);
    if (!caps || !buffer) {
        gst_sample_unref(sample);
        return GST_FLOW_OK;
    }

    GstVideoInfo info;
    if (!gst_video_info_from_caps(&info, caps)) {
        gst_sample_unref(sample);
        return GST_FLOW_OK;
    }

    GstMapInfo map;
    if (!gst_buffer_map(buffer, &map, GST_MAP_READ)) {
        gst_sample_unref(sample);
        return GST_FLOW_OK;
    }

    const size_t width = GST_VIDEO_INFO_WIDTH(&info);
    const size_t height = GST_VIDEO_INFO_HEIGHT(&info);
    const size_t stride = GST_VIDEO_INFO_PLANE_STRIDE(&info, 0);
    const size_t requiredSize = stride * height;

    if (width > 0 && height > 0 && map.size >= requiredSize) {
        CFDataRef data = CFDataCreate(kCFAllocatorDefault, map.data, requiredSize);
        CGDataProviderRef provider = data ? CGDataProviderCreateWithCFData(data) : NULL;
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGBitmapInfo bitmapInfo = kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst;
        CGImageRef image = provider && colorSpace
            ? CGImageCreate(width, height, 8, 32, stride, colorSpace, bitmapInfo, provider, NULL, false, kCGRenderingIntentDefault)
            : NULL;

        if (image) {
            GStreamerPreviewEngine *engine = (__bridge GStreamerPreviewEngine *)userData;
            GStreamerPreviewFrameHandler handler = engine.frameHandler;
            if (handler) {
                handler(image);
            }
            CGImageRelease(image);
        }

        if (colorSpace) {
            CGColorSpaceRelease(colorSpace);
        }
        if (provider) {
            CGDataProviderRelease(provider);
        }
        if (data) {
            CFRelease(data);
        }
    }

    gst_buffer_unmap(buffer, &map);
    gst_sample_unref(sample);
    return GST_FLOW_OK;
}

@end
