import 'dart:typed_data';

import 'package:record/record.dart';

/// Voice notes — WhatsApp interaction model: hold to record, slide up to lock,
/// slide left to cancel, release to send.
class VoiceRecorder {
  final AudioRecorder _recorder = AudioRecorder();

  Future<bool> hasPermission() => _recorder.hasPermission();

  /// Stream mode: subscribe FIRST (record 5.x contract), then start with no path.
  Stream<Uint8List> stream() => _recorder.stream();

  Future<void> start() async {
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc, // .m4a — plays everywhere (Android/Windows/web)
        bitRate: 96000,
        sampleRate: 44100,
        numChannels: 1,
      ),
      path: null,
    );
  }

  Future<String?> stop() => _recorder.stop();

  Future<bool> get isRecording => _recorder.isRecording();

  Future<void> pause() => _recorder.pause();
  Future<void> resume() => _recorder.resume();

  Future<void> dispose() => _recorder.dispose();
}
