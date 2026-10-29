import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Voice notes — WhatsApp interaction model: hold to record, slide up to lock,
/// slide left to cancel, release to send. Records to a temp .m4a (AAC-LC —
/// plays natively on Android and Windows); stop() returns the file path.
class VoiceRecorder {
  final AudioRecorder _recorder = AudioRecorder();
  String? _currentPath;

  Future<bool> hasPermission() => _recorder.hasPermission();

  Future<void> start() async {
    final dir = await getTemporaryDirectory();
    _currentPath = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 96000,
        sampleRate: 44100,
        numChannels: 1,
      ),
      path: _currentPath!,
    );
  }

  /// Returns the recorded file path, or null when nothing was captured.
  Future<String?> stop() => _recorder.stop();

  Future<bool> get isRecording => _recorder.isRecording();
  Future<void> pause() => _recorder.pause();
  Future<void> resume() => _recorder.resume();

  Future<void> dispose() => _recorder.dispose();
}

/// Kept for callers that might inspect the raw file.
Future<int> fileSizeOf(String path) => File(path).length();
