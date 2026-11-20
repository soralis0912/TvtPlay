// SPDX-License-Identifier: GPL-2.0-or-later
#import "TVTestPlaybackPlugin.h"
#import <vlc/vlc.h>
#import <dlfcn.h>

static NSError *PlaybackError(NSString *message) {
    return [NSError errorWithDomain:@"jp.tvtest.native.tvtplay" code:1
                            userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *TimeString(libvlc_time_t milliseconds) {
    long long seconds = MAX(0, milliseconds) / 1000;
    return [NSString stringWithFormat:@"%02lld:%02lld:%02lld",
            seconds / 3600, seconds / 60 % 60, seconds % 60];
}

@interface TvtPlayPlugin : NSObject <TVTestPlaybackPlugin>
@end

@implementation TvtPlayPlugin {
    libvlc_instance_t *_engine;
    libvlc_media_player_t *_player;
    NSView *_view;
    NSView *_video;
    NSButton *_playPause;
    NSButton *_stop;
    NSSlider *_seek;
    NSTextField *_time;
    NSTextField *_status;
    NSTimer *_timer;
    BOOL _hasRecording;
    BOOL _verbose;
    BOOL _reportedPlayback;
}

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
    _timer = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(__unused NSTimer *timer) {
        [weakSelf refreshControls];
    }];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    return self;
}

- (NSView *)view {
    return _view;
}

- (void)dealloc {
    [_timer invalidate];
    if (_player) {
        libvlc_media_player_stop(_player);
        libvlc_media_player_set_nsobject(_player, NULL);
        libvlc_media_player_release(_player);
    }
    if (_engine) {
        libvlc_release(_engine);
    }
}

- (void)buildView {
    _view = [[NSView alloc] init];
    _video = [[NSView alloc] init];
    _video.wantsLayer = YES;
    _video.layer.backgroundColor = NSColor.blackColor.CGColor;
    _video.translatesAutoresizingMaskIntoConstraints = NO;
    [_view addSubview:_video];

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
    [_view addSubview:controls];

    _status = [NSTextField labelWithString:@"TvtPlay   ·   ⌘O で録画を開く"];
    _status.textColor = NSColor.secondaryLabelColor;
    _status.translatesAutoresizingMaskIntoConstraints = NO;
    [_view addSubview:_status];

    [NSLayoutConstraint activateConstraints:@[
        [_video.topAnchor constraintEqualToAnchor:_view.topAnchor],
        [_video.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor],
        [_video.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor],
        [controls.topAnchor constraintEqualToAnchor:_video.bottomAnchor constant:10],
        [controls.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor constant:14],
        [controls.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor constant:-14],
        [_status.topAnchor constraintEqualToAnchor:controls.bottomAnchor constant:6],
        [_status.leadingAnchor constraintEqualToAnchor:controls.leadingAnchor],
        [_status.trailingAnchor constraintEqualToAnchor:controls.trailingAnchor],
        [_status.bottomAnchor constraintEqualToAnchor:_view.bottomAnchor constant:-10],
    ]];
    [self refreshControls];
}

- (BOOL)openRecording:(NSURL *)url error:(NSError **)error {
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
    libvlc_media_player_stop(_player);
    libvlc_media_player_set_media(_player, media);
    libvlc_media_release(media);
    _hasRecording = YES;
    _reportedPlayback = NO;
    if (libvlc_media_player_play(_player) < 0) {
        if (error) {
            *error = PlaybackError(@"録画の再生を開始できませんでした。");
        }
        return NO;
    }
    [self refreshControls];
    return YES;
}

- (void)togglePlayback:(id)sender {
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

- (void)stopPlayback:(id)sender {
    libvlc_media_player_stop(_player);
    [self refreshControls];
}

- (void)seek:(NSSlider *)sender {
    if (libvlc_media_player_is_seekable(_player)) {
        libvlc_media_player_set_position(_player, sender.floatValue);
    }
}

- (void)refreshControls {
    libvlc_state_t state = libvlc_media_player_get_state(_player);
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
    _time.stringValue = [NSString stringWithFormat:@"%@ / %@",
                         TimeString(libvlc_media_player_get_time(_player)),
                         TimeString(libvlc_media_player_get_length(_player))];
    if (state == libvlc_Error) {
        _status.stringValue = @"TvtPlay   ·   この録画を再生できませんでした";
    } else if (starting) {
        _status.stringValue = @"TvtPlay   ·   読み込み中";
    } else {
        _status.stringValue = _hasRecording ? @"TvtPlay" : @"TvtPlay   ·   ⌘O で録画を開く";
    }
}
@end
