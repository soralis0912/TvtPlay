// SPDX-License-Identifier: GPL-2.0-or-later
#import "TVTestPlaybackPlugin.h"
#import <vlc/vlc.h>
#import <dlfcn.h>
#import <pthread.h>
#import <string.h>

static const size_t kLiveRingCapacity = 4 * 1024 * 1024;

@interface TvtPlayLiveRingBuffer : NSObject
- (void)pushBytes:(const uint8_t *)bytes length:(size_t)length;
- (ssize_t)readBytes:(unsigned char *)buf maxLength:(size_t)len;
- (void)purge;
- (void)close;
@end

@implementation TvtPlayLiveRingBuffer {
    uint8_t *_buf;
    size_t _capacity;
    size_t _head;
    size_t _tail;
    size_t _size;
    BOOL _closed;
    pthread_mutex_t _lock;
    pthread_cond_t _cond;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _capacity = kLiveRingCapacity;
        _buf = (uint8_t *)malloc(_capacity);
        pthread_mutex_init(&_lock, NULL);
        pthread_cond_init(&_cond, NULL);
    }
    return self;
}

- (void)dealloc {
    pthread_mutex_destroy(&_lock);
    pthread_cond_destroy(&_cond);
    free(_buf);
}

- (void)pushBytes:(const uint8_t *)bytes length:(size_t)length {
    if (!bytes || length == 0 || !_buf) {
        return;
    }
    pthread_mutex_lock(&_lock);
    if (_closed) {
        pthread_mutex_unlock(&_lock);
        return;
    }
    if (length >= _capacity) {
        // Keep only the newest 188-aligned portion
        size_t keep = (_capacity / 188) * 188;
        memcpy(_buf, bytes + (length - keep), keep);
        _head = 0;
        _tail = keep % _capacity;
        _size = keep;
    } else {
        if (_size + length > _capacity) {
            size_t drop = _size + length - _capacity;
            drop = ((drop + 187) / 188) * 188;
            if (drop > _size) {
                drop = _size;
            }
            _head = (_head + drop) % _capacity;
            _size -= drop;
        }
        size_t first = _capacity - _tail;
        if (first > length) {
            first = length;
        }
        memcpy(_buf + _tail, bytes, first);
        if (length > first) {
            memcpy(_buf, bytes + first, length - first);
        }
        _tail = (_tail + length) % _capacity;
        _size += length;
    }
    pthread_cond_signal(&_cond);
    pthread_mutex_unlock(&_lock);
}

- (ssize_t)readBytes:(unsigned char *)buf maxLength:(size_t)len {
    if (!buf || len == 0 || !_buf) {
        return 0;
    }
    pthread_mutex_lock(&_lock);
    while (_size == 0 && !_closed) {
        pthread_cond_wait(&_cond, &_lock);
    }
    if (_size == 0 && _closed) {
        pthread_mutex_unlock(&_lock);
        return 0;
    }
    size_t toRead = (_size < len) ? _size : len;
    size_t first = _capacity - _head;
    if (first > toRead) {
        first = toRead;
    }
    memcpy(buf, _buf + _head, first);
    if (toRead > first) {
        memcpy(buf + first, _buf, toRead - first);
    }
    _head = (_head + toRead) % _capacity;
    _size -= toRead;
    pthread_mutex_unlock(&_lock);
    return (ssize_t)toRead;
}

- (void)purge {
    pthread_mutex_lock(&_lock);
    _head = 0;
    _tail = 0;
    _size = 0;
    pthread_mutex_unlock(&_lock);
}

- (void)close {
    pthread_mutex_lock(&_lock);
    _closed = YES;
    pthread_cond_broadcast(&_cond);
    pthread_mutex_unlock(&_lock);
}
@end

static int TvtPlayLiveOpenCB(void *opaque, void **datap, uint64_t *sizep) {
    TvtPlayLiveRingBuffer *ring = (__bridge TvtPlayLiveRingBuffer *)opaque;
    if (!ring) {
        return -1;
    }
    *datap = (void *)CFBridgingRetain(ring);
    *sizep = UINT64_MAX;
    return 0;
}

static ssize_t TvtPlayLiveReadCB(void *opaque, unsigned char *buf, size_t len) {
    TvtPlayLiveRingBuffer *ring = (__bridge TvtPlayLiveRingBuffer *)opaque;
    if (!ring) {
        return 0;
    }
    return [ring readBytes:buf maxLength:len];
}

static void TvtPlayLiveCloseCB(void *opaque) {
    if (opaque) {
        CFBridgingRelease(opaque);
    }
}

static NSError *PlaybackError(NSString *message) {
    return [NSError errorWithDomain:@"jp.tvtest.native.tvtplay" code:1
                            userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *TimeString(libvlc_time_t milliseconds) {
    long long seconds = MAX(0, milliseconds) / 1000;
    return [NSString stringWithFormat:@"%02lld:%02lld:%02lld",
            seconds / 3600, seconds / 60 % 60, seconds % 60];
}

@interface TvtPlayOverlayContainer : NSView
@end

@implementation TvtPlayOverlayContainer
- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}
@end

@interface TvtPlayPlugin : NSObject <TVTestPlaybackPlugin>
@end

@implementation TvtPlayPlugin {
    libvlc_instance_t *_engine;
    libvlc_media_player_t *_player;
    NSView *_view;
    NSView *_video;
    NSView *_videoOverlay;
    NSView *_controlBar;
    NSLayoutConstraint *_videoBottomToControls;
    NSLayoutConstraint *_videoBottomToView;
    NSButton *_playPause;
    NSButton *_stop;
    NSSlider *_seek;
    NSTextField *_time;
    NSTextField *_status;
    NSTimer *_timer;
    BOOL _hasRecording;
    BOOL _isLiveStream;
    TvtPlayLiveRingBuffer *_liveBuffer;
    BOOL _verbose;
    BOOL _reportedPlayback;
    BOOL _controlsHidden;
    double _pendingSeekPosition;
    float _desiredRate;
    NSString *_aspectRatio;
    NSString *_cropGeometry;
    NSString *_deinterlaceMode;
    TVTestAudioChannelMode _audioChannelMode;
}

@synthesize delegate = _delegate;

+ (NSUInteger)apiVersion {
    return TVTestPlaybackPluginAPIVersion;
}

+ (instancetype)newWithError:(NSError **)error {
    return [[self alloc] initWithError:error];
}

- (instancetype)initWithError:(NSError **)error {
    self = [super init];
    if (!self) {
        return nil;
    }
    _pendingSeekPosition = -1.0;
    _desiredRate = 1.0f;
    _audioChannelMode = TVTestAudioChannelModeStereo;

    // The VLC app supplies its codec modules next to the library directory.
    Dl_info library = {0};
    if (dladdr((const void *)libvlc_new, &library)) {
        NSString *libraryPath = [NSFileManager.defaultManager
            stringWithFileSystemRepresentation:library.dli_fname length:strlen(library.dli_fname)];
        NSString *modules = [[libraryPath stringByDeletingLastPathComponent]
            stringByDeletingLastPathComponent];
        modules = [modules stringByAppendingPathComponent:@"plugins"];
        setenv("VLC_PLUGIN_PATH", modules.fileSystemRepresentation, 1);
    }

    _verbose = [NSProcessInfo.processInfo.environment[@"TVTEST_VLC_VERBOSE"] isEqualToString:@"1"];
    const char *options[] = {"--ignore-config", "--no-video-title-show", "--verbose=2"};
    _engine = libvlc_new(_verbose ? 3 : 2, options);
    if (_engine) {
        if (_verbose) {
            libvlc_log_set_file(_engine, stderr);
        }
        _player = libvlc_media_player_new(_engine);
    }
    if (!_player) {
        if (error) {
            *error = PlaybackError(@"VLC の再生エンジンを初期化できません。");
        }
        return nil;
    }

    [self buildView];
    libvlc_media_player_set_nsobject(_player, (__bridge void *)_video);

    __weak TvtPlayPlugin *weakSelf = self;
    _timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(__unused NSTimer *timer) {
        [weakSelf refreshControls];
    }];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    return self;
}

- (NSView *)view {
    return _view;
}

- (NSView *)videoOverlayView {
    return _videoOverlay;
}

- (BOOL)isPlaying {
    return _player && libvlc_media_player_get_state(_player) == libvlc_Playing;
}

- (BOOL)isLiveStream {
    return _isLiveStream;
}

- (int64_t)playbackTimeMs {
    if (!_player || !_hasRecording) {
        return -1;
    }
    return libvlc_media_player_get_time(_player);
}

- (int64_t)durationMs {
    if (!_player || !_hasRecording) {
        return -1;
    }
    return libvlc_media_player_get_length(_player);
}

- (double)playbackPosition {
    if (!_player || !_hasRecording) {
        return 0.0;
    }
    float pos = libvlc_media_player_get_position(_player);
    return pos >= 0.0f ? (double)pos : 0.0;
}

- (float)playbackRate {
    if (!_player) {
        return 1.0f;
    }
    float rate = libvlc_media_player_get_rate(_player);
    return rate > 0.0f ? rate : _desiredRate;
}

- (NSInteger)volume {
    if (!_player) {
        return 100;
    }
    int vol = libvlc_audio_get_volume(_player);
    return vol >= 0 ? vol : 100;
}

- (BOOL)muted {
    if (!_player) {
        return NO;
    }
    return libvlc_audio_get_mute(_player) > 0;
}

- (NSSize)videoSize {
    if (!_player || !_hasRecording) {
        return NSZeroSize;
    }
    unsigned int w = 0, h = 0;
    if (libvlc_video_get_size(_player, 0, &w, &h) == 0 && w > 0 && h > 0) {
        return NSMakeSize((CGFloat)w, (CGFloat)h);
    }
    return NSZeroSize;
}

- (nullable NSString *)aspectRatio {
    return _aspectRatio;
}

- (nullable NSString *)cropGeometry {
    return _cropGeometry;
}

- (nullable NSString *)deinterlaceMode {
    return _deinterlaceMode;
}

- (TVTestAudioChannelMode)audioChannelMode {
    if (_player && _hasRecording) {
        int ch = libvlc_audio_get_channel(_player);
        if (ch >= libvlc_AudioChannel_Stereo && ch <= libvlc_AudioChannel_Right) {
            return (TVTestAudioChannelMode)ch;
        }
    }
    return _audioChannelMode;
}

- (BOOL)controlsHidden {
    return _controlsHidden;
}

- (void)setControlsHidden:(BOOL)controlsHidden {
    if (_controlsHidden == controlsHidden) {
        return;
    }
    _controlsHidden = controlsHidden;
    _controlBar.hidden = controlsHidden;
    _videoBottomToControls.active = !controlsHidden;
    _videoBottomToView.active = controlsHidden;
}

- (NSArray<NSDictionary<NSString *, id> *> *)audioTracks {
    if (!_player || !_hasRecording) {
        return @[];
    }
    libvlc_track_description_t *head = libvlc_audio_get_track_description(_player);
    if (!head) {
        return @[];
    }
    NSMutableArray<NSDictionary<NSString *, id> *> *tracks = [NSMutableArray array];
    for (libvlc_track_description_t *cur = head; cur != NULL; cur = cur->p_next) {
        NSString *name = cur->psz_name ? [NSString stringWithUTF8String:cur->psz_name] : nil;
        if (!name.length) {
            name = [NSString stringWithFormat:@"Track %d", cur->i_id];
        }
        [tracks addObject:@{
            @"id": @(cur->i_id),
            @"name": name,
        }];
    }
    libvlc_track_description_list_release(head);
    return tracks;
}

- (NSInteger)currentAudioTrackID {
    if (!_player || !_hasRecording) {
        return -1;
    }
    return libvlc_audio_get_track(_player);
}

- (void)dealloc {
    [_timer invalidate];
    [_liveBuffer close];
    if (_player) {
        libvlc_media_player_stop(_player);
        libvlc_media_player_set_nsobject(_player, NULL);
        libvlc_media_player_release(_player);
    }
    _liveBuffer = nil;
    if (_engine) {
        libvlc_release(_engine);
    }
}

- (void)buildView {
    _view = [[NSView alloc] init];
    _view.wantsLayer = YES;

    _video = [[NSView alloc] init];
    _video.wantsLayer = YES;
    _video.layer.backgroundColor = NSColor.blackColor.CGColor;
    _video.translatesAutoresizingMaskIntoConstraints = NO;
    [_view addSubview:_video];

    _videoOverlay = [[TvtPlayOverlayContainer alloc] init];
    _videoOverlay.wantsLayer = YES;
    _videoOverlay.layer.backgroundColor = NSColor.clearColor.CGColor;
    _videoOverlay.layer.zPosition = 100.0;
    _videoOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    [_view addSubview:_videoOverlay positioned:NSWindowAbove relativeTo:_video];

    _controlBar = [[NSView alloc] init];
    _controlBar.translatesAutoresizingMaskIntoConstraints = NO;
    [_view addSubview:_controlBar];

    _playPause = [NSButton buttonWithTitle:@"再生" target:self action:@selector(togglePlayback:)];
    _stop = [NSButton buttonWithTitle:@"停止" target:self action:@selector(stopPlayback:)];
    _seek = [NSSlider sliderWithValue:0 minValue:0 maxValue:1 target:self action:@selector(seek:)];
    _seek.continuous = NO;
    _seek.accessibilityLabel = @"再生位置";
    _time = [NSTextField labelWithString:@"00:00:00 / 00:00:00"];
    _time.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize weight:NSFontWeightRegular];
    [_time setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *controls = [NSStackView stackViewWithViews:@[_playPause, _stop, _seek, _time]];
    controls.spacing = 10;
    controls.translatesAutoresizingMaskIntoConstraints = NO;
    [_controlBar addSubview:controls];

    _status = [NSTextField labelWithString:@"TvtPlay   ·   ⌘O で録画を開く"];
    _status.textColor = NSColor.secondaryLabelColor;
    _status.font = [NSFont systemFontOfSize:11.0];
    _status.translatesAutoresizingMaskIntoConstraints = NO;
    [_controlBar addSubview:_status];

    _videoBottomToControls = [_video.bottomAnchor constraintEqualToAnchor:_controlBar.topAnchor];
    _videoBottomToView = [_video.bottomAnchor constraintEqualToAnchor:_view.bottomAnchor];
    _videoBottomToView.active = NO;

    [NSLayoutConstraint activateConstraints:@[
        [_video.topAnchor constraintEqualToAnchor:_view.topAnchor],
        [_video.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor],
        [_video.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor],
        _videoBottomToControls,

        [_videoOverlay.topAnchor constraintEqualToAnchor:_video.topAnchor],
        [_videoOverlay.bottomAnchor constraintEqualToAnchor:_video.bottomAnchor],
        [_videoOverlay.leadingAnchor constraintEqualToAnchor:_video.leadingAnchor],
        [_videoOverlay.trailingAnchor constraintEqualToAnchor:_video.trailingAnchor],

        [_controlBar.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor],
        [_controlBar.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor],
        [_controlBar.bottomAnchor constraintEqualToAnchor:_view.bottomAnchor],

        [controls.topAnchor constraintEqualToAnchor:_controlBar.topAnchor constant:8],
        [controls.leadingAnchor constraintEqualToAnchor:_controlBar.leadingAnchor constant:12],
        [controls.trailingAnchor constraintEqualToAnchor:_controlBar.trailingAnchor constant:-12],
        [_status.topAnchor constraintEqualToAnchor:controls.bottomAnchor constant:4],
        [_status.leadingAnchor constraintEqualToAnchor:controls.leadingAnchor],
        [_status.trailingAnchor constraintEqualToAnchor:controls.trailingAnchor],
        [_status.bottomAnchor constraintEqualToAnchor:_controlBar.bottomAnchor constant:-6],
    ]];
    [self refreshControls];
}

- (BOOL)openRecording:(NSURL *)url error:(NSError **)error {
    return [self openRecording:url serviceID:0 startPosition:0.0 error:error];
}

- (BOOL)openRecording:(NSURL *)url
            serviceID:(NSInteger)serviceID
        startPosition:(double)position
                error:(NSError **)error {
    NSString *extension = url.pathExtension.lowercaseString;
    NSArray<NSString *> *extensions = @[@"ts", @"m2ts", @"m2t", @"mts"];
    NSNumber *isFile = nil;
    if (!url.isFileURL || ![extensions containsObject:extension] ||
        ![url.URLByResolvingSymlinksInPath getResourceValue:&isFile forKey:NSURLIsRegularFileKey error:NULL] ||
        !isFile.boolValue || ![NSFileManager.defaultManager isReadableFileAtPath:url.path]) {
        if (error) {
            *error = PlaybackError(@"読み込み可能な TS または M2TS 録画を選択してください。");
        }
        return NO;
    }

    libvlc_media_t *media = libvlc_media_new_path(_engine, url.fileSystemRepresentation);
    if (!media) {
        if (error) {
            *error = PlaybackError(@"録画を開けませんでした。");
        }
        return NO;
    }
    if (serviceID > 0) {
        NSString *opt = [NSString stringWithFormat:@":program=%ld", (long)serviceID];
        libvlc_media_add_option(media, opt.UTF8String);
    }
    [_liveBuffer close];
    libvlc_media_player_stop(_player);
    _liveBuffer = nil;
    _isLiveStream = NO;
    libvlc_media_player_set_media(_player, media);
    libvlc_media_release(media);
    _hasRecording = YES;
    _reportedPlayback = NO;
    _pendingSeekPosition = (position > 0.0 && position < 0.995) ? position : -1.0;
    if (libvlc_media_player_play(_player) < 0) {
        if (error) {
            *error = PlaybackError(@"録画の再生を開始できませんでした。");
        }
        return NO;
    }
    [self applyVideoAndAudioPreferences];
    [self refreshControls];
    return YES;
}

- (BOOL)openLiveStreamWithServiceID:(NSInteger)serviceID error:(NSError **)error {
    if (!_engine || !_player) {
        if (error) {
            *error = PlaybackError(@"VLC 再生エンジンが初期化されていません。");
        }
        return NO;
    }
    [_liveBuffer close];
    libvlc_media_player_stop(_player);

    TvtPlayLiveRingBuffer *ring = [[TvtPlayLiveRingBuffer alloc] init];
    _liveBuffer = ring;
    libvlc_media_t *media = libvlc_media_new_callbacks(
        _engine,
        TvtPlayLiveOpenCB,
        TvtPlayLiveReadCB,
        NULL,
        TvtPlayLiveCloseCB,
        (__bridge void *)ring);
    if (!media) {
        _liveBuffer = nil;
        if (error) {
            *error = PlaybackError(@"ライブストリームのメディアを作成できませんでした。");
        }
        return NO;
    }
    libvlc_media_add_option(media, ":demux=ts");
    libvlc_media_add_option(media, ":live-caching=350");
    if (serviceID > 0) {
        NSString *opt = [NSString stringWithFormat:@":program=%ld", (long)serviceID];
        libvlc_media_add_option(media, opt.UTF8String);
    }
    libvlc_media_player_set_media(_player, media);
    libvlc_media_release(media);

    _hasRecording = YES;
    _isLiveStream = YES;
    _reportedPlayback = NO;
    _pendingSeekPosition = -1.0;
    if (libvlc_media_player_play(_player) < 0) {
        [_liveBuffer close];
        _liveBuffer = nil;
        _isLiveStream = NO;
        if (error) {
            *error = PlaybackError(@"ライブストリーム再生を開始できませんでした。");
        }
        return NO;
    }
    [self applyVideoAndAudioPreferences];
    [self refreshControls];
    return YES;
}

- (void)pushLiveTSBytes:(const uint8_t *)bytes length:(NSUInteger)length {
    [_liveBuffer pushBytes:bytes length:(size_t)length];
}

- (void)purgeLiveStream {
    [_liveBuffer purge];
}

- (void)closeLiveStream {
    [_liveBuffer close];
    if (_player) {
        libvlc_media_player_stop(_player);
    }
    _liveBuffer = nil;
    _isLiveStream = NO;
    _hasRecording = NO;
    [self refreshControls];
}

- (void)applyVideoAndAudioPreferences {
    if (!_player) {
        return;
    }
    if (_desiredRate != 1.0f) {
        libvlc_media_player_set_rate(_player, _desiredRate);
    }
    libvlc_video_set_aspect_ratio(_player, _aspectRatio.length ? _aspectRatio.UTF8String : NULL);
    libvlc_video_set_crop_geometry(_player, _cropGeometry.length ? _cropGeometry.UTF8String : NULL);
    libvlc_video_set_deinterlace(_player, _deinterlaceMode.length ? _deinterlaceMode.UTF8String : NULL);
    if (_audioChannelMode != TVTestAudioChannelModeStereo) {
        libvlc_audio_set_channel(_player, (int)_audioChannelMode);
    }
}

- (void)togglePlayPause {
    if (!_player || !_hasRecording) {
        return;
    }
    libvlc_state_t state = libvlc_media_player_get_state(_player);
    if (state == libvlc_Playing) {
        libvlc_media_player_set_pause(_player, 1);
    } else if (state == libvlc_Paused) {
        libvlc_media_player_set_pause(_player, 0);
    } else {
        libvlc_media_player_play(_player);
    }
    [self refreshControls];
}

- (void)stop {
    if (!_player) {
        return;
    }
    _pendingSeekPosition = -1.0;
    libvlc_media_player_stop(_player);
    [self refreshControls];
}

- (void)seekToTimeMs:(int64_t)timeMs {
    if (!_player || !_hasRecording || !libvlc_media_player_is_seekable(_player)) {
        return;
    }
    int64_t clamped = MAX((int64_t)0, timeMs);
    int64_t dur = libvlc_media_player_get_length(_player);
    if (dur > 0) {
        clamped = MIN(clamped, dur);
    }
    libvlc_media_player_set_time(_player, (libvlc_time_t)clamped);
    [self refreshControls];
}

- (void)seekByMs:(int64_t)deltaMs {
    int64_t cur = self.playbackTimeMs;
    if (cur < 0) {
        return;
    }
    [self seekToTimeMs:cur + deltaMs];
}

- (void)setPlaybackRate:(float)rate {
    if (!_player || rate <= 0.0f) {
        return;
    }
    _desiredRate = rate;
    libvlc_media_player_set_rate(_player, rate);
    [self refreshControls];
}

- (void)setVolume:(NSInteger)volume {
    if (!_player) {
        return;
    }
    int clamped = (int)MAX((NSInteger)0, MIN((NSInteger)100, volume));
    libvlc_audio_set_volume(_player, clamped);
    [self refreshControls];
}

- (void)setMuted:(BOOL)muted {
    if (!_player) {
        return;
    }
    libvlc_audio_set_mute(_player, muted ? 1 : 0);
    [self refreshControls];
}

- (BOOL)selectAudioTrackID:(NSInteger)trackID {
    if (!_player || !_hasRecording) {
        return NO;
    }
    int rc = libvlc_audio_set_track(_player, (int)trackID);
    [self refreshControls];
    return rc == 0;
}

- (BOOL)setAudioChannelMode:(TVTestAudioChannelMode)mode {
    _audioChannelMode = mode;
    if (!_player || !_hasRecording) {
        return YES;
    }
    int rc = libvlc_audio_set_channel(_player, (int)mode);
    [self refreshControls];
    return rc == 0;
}

- (void)setAspectRatio:(nullable NSString *)aspectRatio {
    _aspectRatio = aspectRatio.length ? [aspectRatio copy] : nil;
    if (_player) {
        libvlc_video_set_aspect_ratio(_player, _aspectRatio ? _aspectRatio.UTF8String : NULL);
    }
}

- (void)setCropGeometry:(nullable NSString *)cropGeometry {
    _cropGeometry = cropGeometry.length ? [cropGeometry copy] : nil;
    if (_player) {
        libvlc_video_set_crop_geometry(_player, _cropGeometry ? _cropGeometry.UTF8String : NULL);
    }
}

- (void)setDeinterlaceMode:(nullable NSString *)mode {
    _deinterlaceMode = mode.length ? [mode copy] : nil;
    if (_player) {
        libvlc_video_set_deinterlace(_player, _deinterlaceMode ? _deinterlaceMode.UTF8String : NULL);
    }
}

- (BOOL)takeSnapshotToURL:(NSURL *)outputURL error:(NSError **)error {
    if (!_player || !_hasRecording) {
        if (error) {
            *error = PlaybackError(@"再生中の映像がありません。");
        }
        return NO;
    }
    NSURL *dir = [outputURL URLByDeletingLastPathComponent];
    if (![NSFileManager.defaultManager createDirectoryAtURL:dir
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:error]) {
        return NO;
    }
    int rc = libvlc_video_take_snapshot(_player, 0, outputURL.fileSystemRepresentation, 0, 0);
    if (rc != 0) {
        if (error) {
            *error = PlaybackError(@"静止画キャプチャを保存できませんでした。");
        }
        return NO;
    }
    return YES;
}

- (void)togglePlayback:(id)sender {
    (void)sender;
    [self togglePlayPause];
}

- (void)stopPlayback:(id)sender {
    (void)sender;
    [self stop];
}

- (void)seek:(NSSlider *)sender {
    if (libvlc_media_player_is_seekable(_player)) {
        libvlc_media_player_set_position(_player, sender.floatValue);
        [self refreshControls];
    }
}

- (void)refreshControls {
    libvlc_state_t state = libvlc_media_player_get_state(_player);
    if (_pendingSeekPosition >= 0.0 && state == libvlc_Playing && libvlc_media_player_is_seekable(_player)) {
        libvlc_media_player_set_position(_player, (float)_pendingSeekPosition);
        _pendingSeekPosition = -1.0;
    }
    if (_verbose && state == libvlc_Ended && !_reportedPlayback) {
        libvlc_media_t *media = libvlc_media_player_get_media(_player);
        libvlc_media_stats_t stats = {0};
        if (media && libvlc_media_get_stats(media, &stats)) {
            fprintf(stderr, "TvtPlay: displayed %d pictures, played %d audio buffers\n",
                    stats.i_displayed_pictures, stats.i_played_abuffers);
        }
        if (media) {
            libvlc_media_release(media);
        }
        _reportedPlayback = YES;
    }
    BOOL playing = state == libvlc_Playing;
    BOOL starting = state == libvlc_Opening || state == libvlc_Buffering;
    _playPause.title = playing ? @"一時停止" : @"再生";
    _playPause.enabled = _hasRecording && !starting;
    _stop.enabled = playing || starting || state == libvlc_Paused;
    _seek.enabled = libvlc_media_player_is_seekable(_player) != 0;
    if (!_seek.cell.isHighlighted) {
        _seek.doubleValue = MAX(0, libvlc_media_player_get_position(_player));
    }
    if (_isLiveStream) {
        _time.stringValue = @"LIVE";
        _seek.enabled = NO;
        _seek.doubleValue = 1.0;
    } else {
        _time.stringValue = [NSString stringWithFormat:@"%@ / %@",
                             TimeString(libvlc_media_player_get_time(_player)),
                             TimeString(libvlc_media_player_get_length(_player))];
    }
    if (state == libvlc_Error) {
        _status.stringValue = @"TvtPlay   ·   ストリームを再生できませんでした";
    } else if (starting) {
        _status.stringValue = _isLiveStream ? @"TVTest Live   ·   バッファリング中" : @"TvtPlay   ·   読み込み中";
    } else if (_isLiveStream) {
        _status.stringValue = @"TVTest Live (MacBonDriver)";
    } else if (_hasRecording && _desiredRate != 1.0f) {
        _status.stringValue = [NSString stringWithFormat:@"TvtPlay   ·   %.2gx", _desiredRate];
    } else {
        _status.stringValue = _hasRecording ? @"TvtPlay" : @"TvtPlay   ·   ⌘O で録画を開く / ⇧⌘O で MacBonDriver を開く";
    }

    if ([_delegate respondsToSelector:@selector(playbackPluginDidUpdateState:)]) {
        [_delegate playbackPluginDidUpdateState:self];
    }
}
@end
