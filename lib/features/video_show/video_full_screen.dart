import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import 'logic/player_ads_provider.dart';
import 'models/player_ads_model.dart';

class FullScreenPlayer extends ConsumerStatefulWidget {
  const FullScreenPlayer({
    super.key, 
    required this.controller,
    this.videoUrl,
  });
  final VideoPlayerController controller;
  final String? videoUrl;

  @override
  ConsumerState<FullScreenPlayer> createState() => _FullScreenPlayerState();
}

class _FullScreenPlayerState extends ConsumerState<FullScreenPlayer> {
  bool _showControls = true;
  
  // Ad system variables
  VideoPlayerController? _adController;
  bool _isPlayingAd = false;
  PlayerAdsResponse? _adsResponse;
  Set<int> _playedAds = {};
  bool _canSkipAd = false;
  int _currentAdIndex = -1;
  Timer? _skipCountdownTimer;
  int _skipCountdown = 5;

  @override
  void initState() {
    super.initState();
    // 👉 Only in fullscreen = landscape
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    
    // Initialize ad system (enabled for ALL users on every video)
    _initializeAds();
    _setupAdListener();
  }

  @override
  void dispose() {
    // 👉 Back to portrait when exit
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
    _adController?.dispose();
    _skipCountdownTimer?.cancel();
    super.dispose();
  }
  
  Future<void> _initializeAds() async {
    final adsAsync = ref.read(playerAdsProvider);
    adsAsync.when(
      data: (adsResponse) {
        if (adsResponse != null && adsResponse.showAds) {
          setState(() {
            _adsResponse = adsResponse;
          });
          print('✅ Fullscreen ads initialized: ${adsResponse.ads.length} ads');
        } else {
          print('⚠️ No ads to show in fullscreen');
        }
      },
      loading: () => print('🔄 Loading ads for fullscreen...'),
      error: (e, _) => print('❌ Error loading ads: $e'),
    );
  }

  void _setupAdListener() {
    widget.controller.addListener(() {
      if (!mounted || _isPlayingAd) return;

      final currentPosition = widget.controller.value.position;
      _checkAndPlayAd(currentPosition);
    });

    print('✅ Fullscreen video listener added for ad checks');
  }

  void _checkAndPlayAd(Duration currentPosition) {
    if (_isPlayingAd || _adsResponse == null) {
      return;
    }

    for (var i = 0; i < _adsResponse!.ads.length; i++) {
      if (_playedAds.contains(i)) {
        continue;
      }

      final ad = _adsResponse!.ads[i];
      final adTime = ad.timestartDuration;

      if (currentPosition >= adTime &&
          currentPosition < adTime + const Duration(seconds: 1)) {
        print('🎬 Fullscreen ad trigger at ${currentPosition.inSeconds}s (target: ${adTime.inSeconds}s)');
        _playAd(i, ad);
        break;
      }
    }
  }

  Future<void> _playAd(int adIndex, VideoAd ad) async {
    print('🎬 Attempting to play ad ${adIndex + 1} in fullscreen at ${ad.timestart}');
    print('   Source: ${ad.source}');

    if (!ad.isVideoAd) {
      print('⚠️ Skipping non-video ad (not a video format)');
      _markAdAsPlayed(adIndex);
      return;
    }

    // Validate ad source URL
    if (ad.source.isEmpty || 
        (!ad.source.startsWith('http://') && !ad.source.startsWith('https://'))) {
      print('⚠️ Invalid ad source URL: ${ad.source}');
      _markAdAsPlayed(adIndex);
      return;
    }

    setState(() {
      _isPlayingAd = true;
      _canSkipAd = false;
      _currentAdIndex = adIndex;
      _skipCountdown = 5;
    });

    // Start countdown timer
    _skipCountdownTimer?.cancel();
    _skipCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!_isPlayingAd || _currentAdIndex != adIndex) {
        timer.cancel();
        return;
      }

      setState(() {
        _skipCountdown--;
      });

      if (_skipCountdown <= 0) {
        timer.cancel();
        setState(() {
          _canSkipAd = true;
        });
        print('⏭️ Skip button enabled for ad ${adIndex + 1}');
      }
    });

    // Pause main video
    print('⏸️ Pausing main video for ad');
    widget.controller.pause();

    try {
      print('📥 Loading ad from: ${ad.source}');
      _adController = VideoPlayerController.network(ad.source);
      
      await _adController!.initialize().timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          print('⏱️ Ad initialization timed out');
          throw TimeoutException('Ad loading timeout');
        },
      );

      print('✅ Ad initialized successfully');
      await _adController!.play();
      print('▶️ Ad playing');

      _adController!.addListener(() {
        if (_adController != null &&
            _adController!.value.isInitialized &&
            _adController!.value.position >= _adController!.value.duration) {
          print('✅ Ad completed normally');
          _onAdComplete(adIndex);
        }
      });
    } catch (e) {
      print('❌ Error playing ad: $e');
      print('🔄 Resuming main video');
      _onAdComplete(adIndex);
    }
  }

  void _onAdComplete(int adIndex) {
    print('🏁 Completing ad ${adIndex + 1} in fullscreen');
    _markAdAsPlayed(adIndex);

    _skipCountdownTimer?.cancel();
    _skipCountdownTimer = null;

    _adController?.dispose();
    _adController = null;

    setState(() {
      _isPlayingAd = false;
      _canSkipAd = false;
      _currentAdIndex = -1;
      _skipCountdown = 5;
    });

    // Resume main video
    print('▶️ Resuming main video');
    if (widget.controller.value.isInitialized) {
      widget.controller.play();
      print('✅ Main video resumed');
    } else {
      print('⚠️ Warning: Controller not available for resume');
    }
  }

  void _skipAd() {
    if (!_canSkipAd || _currentAdIndex == -1) return;
    
    print('⏭️ User skipped ad ${_currentAdIndex + 1} in fullscreen');
    _onAdComplete(_currentAdIndex);
  }

  void _markAdAsPlayed(int adIndex) {
    setState(() {
      _playedAds.add(adIndex);
    });
    print('   Marked ad ${adIndex + 1} as played (${_playedAds.length}/${_adsResponse?.ads.length ?? 0})');
  }

  String formatDuration(Duration position) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    final hours = position.inHours;
    final minutes = position.inMinutes.remainder(60);
    final seconds = position.inSeconds.remainder(60);
    if (hours > 0) {
      return "${twoDigits(hours)}:${twoDigits(minutes)}:${twoDigits(seconds)}";
    } else {
      return "${twoDigits(minutes)}:${twoDigits(seconds)}";
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _isPlayingAd && _adController != null 
        ? _adController! 
        : widget.controller;

    return WillPopScope(
      onWillPop: () async {
        await widget.controller.pause();
        _adController?.dispose();
        return true;
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          onTap: () {
            if (!_isPlayingAd) {
              setState(() => _showControls = !_showControls);
            }
          },
          child: Stack(
            children: [
              // 🎬 Video (Main or Ad)
              Center(
                child: AspectRatio(
                  aspectRatio: controller.value.aspectRatio,
                  child: VideoPlayer(controller),
                ),
              ),

              // Ad Label and Skip Button (only during ad)
              if (_isPlayingAd)
                Positioned(
                  top: 30,
                  right: 30,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // AD Label
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.yellow.withOpacity(0.9),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'AD',
                          style: TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      
                      const SizedBox(height: 10),
                      
                      // Skip Button or Countdown
                      if (_canSkipAd)
                        ElevatedButton.icon(
                          onPressed: _skipAd,
                          icon: const Icon(Icons.skip_next, size: 18),
                          label: const Text(
                            'Skip Ad',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white.withOpacity(0.9),
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                            elevation: 4,
                          ),
                        )
                      else
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.6),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            'Skip in ${_skipCountdown}s',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),

              // Ad Progress Bar (only during ad)
              if (_isPlayingAd && _adController != null && _adController!.value.isInitialized)
                Positioned(
                  bottom: 20,
                  left: 30,
                  right: 30,
                  child: Column(
                    children: [
                      VideoProgressIndicator(
                        _adController!,
                        allowScrubbing: false,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        colors: const VideoProgressColors(
                          playedColor: Colors.yellow,
                          backgroundColor: Colors.white24,
                          bufferedColor: Colors.white38,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            formatDuration(_adController!.value.position),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          Text(
                            formatDuration(_adController!.value.duration),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

              // Main video controls (only when NOT playing ad)
              if (_showControls && !_isPlayingAd) ...[
                // 🔙 Back/Close Button (top-left)
                Positioned(
                  top: 20,
                  left: 20,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white, size: 32),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),

                // ▶️ Play / Pause + Skip
                Positioned.fill(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // ⏪ Back 10s
                      IconButton(
                        icon: const Icon(Icons.replay_10, color: Colors.white, size: 40),
                        onPressed: () {
                          final newPos = widget.controller.value.position - const Duration(seconds: 10);
                          widget.controller.seekTo(newPos >= Duration.zero ? newPos : Duration.zero);
                        },
                      ),

                      // ▶️ / ⏸️ Play / Pause (reactive)
                      ValueListenableBuilder<VideoPlayerValue>(
                        valueListenable: widget.controller,
                        builder: (_, value, __) {
                          final playing = value.isPlaying;
                          return IconButton(
                            icon: Icon(
                              playing ? Icons.pause_circle : Icons.play_circle,
                              color: Colors.white,
                              size: 60,
                            ),
                            onPressed: () {
                              if (playing) {
                                widget.controller.pause();
                              } else {
                                widget.controller.setVolume(1.0);
                                widget.controller.play();
                              }
                            },
                          );
                        },
                      ),

                      // ⏩ Forward 10s
                      IconButton(
                        icon: const Icon(Icons.forward_10, color: Colors.white, size: 40),
                        onPressed: () {
                          final maxPos = widget.controller.value.duration;
                          final newPos = widget.controller.value.position + const Duration(seconds: 10);
                          widget.controller.seekTo(newPos <= maxPos ? newPos : maxPos);
                        },
                      ),
                    ],
                  ),
                ),

                // Timeline + Time (Main Video)
                Positioned(
                  bottom: 20,
                  left: 30,
                  right: 30,
                  child: Column(
                    children: [
                      VideoProgressIndicator(
                        widget.controller,
                        allowScrubbing: true,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        colors: const VideoProgressColors(
                          playedColor: Colors.red,
                          backgroundColor: Colors.grey,
                          bufferedColor: Colors.white30,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            formatDuration(widget.controller.value.position),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          Text(
                            formatDuration(widget.controller.value.duration),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
              
              // Back button during ad
              if (_isPlayingAd)
                Positioned(
                  top: 20,
                  left: 20,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white, size: 32),
                    onPressed: () {
                      _adController?.dispose();
                      Navigator.pop(context);
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
