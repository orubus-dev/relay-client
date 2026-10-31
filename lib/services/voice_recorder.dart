import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

/// Ground-truth microphone permission state, resolved from the OS — never
/// guessed. `blocked` means permanently denied: the only fix is app settings.
enum MicPermission { granted, denied, blocked }

/// Voice notes — WhatsApp interaction model: hold to record, slide up to lock,
/// slide left to cancel, release to send. Records to a temp .m4a (AAC-LC —
/// plays natively on Android and Windows); stop() returns the file path.
class VoiceRecorder {
  final AudioRecorder _recorder = AudioRecorder();
  String? _currentPath;

  /// Cached last-resolved state so the UI can react without a round-trip.
  MicPermission lastKnown = MicPermission.denied;

  /// OS-level microphone check. On Android this uses permission_handler
  /// (deterministic checkSelfPermission semantics). The `record` plugin's own
  /// check returns false whenever its activity binding is absent — that was
  /// the "says microphone permission required while permission is enabled"
  /// false negative. Windows has no permission_handler implementation; there
  /// we still defer to the recorder's check.
  Future<MicPermission> resolvePermission({bool request = true}) async {
    if (Platform.isAndroid) {
      final status = await Permission.microphone.status;
      if (status.isGranted) return lastKnown = MicPermission.granted;
      if (status.isPermanentlyDenied || status.isRestricted) {
        return lastKnown = MicPermission.blocked;
      }
      if (!request) return lastKnown = MicPermission.denied;
      final after = await Permission.microphone.request();
      if (after.isGranted) return lastKnown = MicPermission.granted;
      if (after.isPermanentlyDenied || after.isRestricted) {
        return lastKnown = MicPermission.blocked;
      }
      return lastKnown = MicPermission.denied;
    }
    try {
      final ok = await _recorder.hasPermission();
      return lastKnown = ok ? MicPermission.granted : MicPermission.denied;
    } catch (_) {
      return lastKnown = MicPermission.denied;
    }
  }

  /// Boolean wrapper used by existing call sites.
  Future<bool> hasPermission() async => await resolvePermission() == MicPermission.granted;

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
