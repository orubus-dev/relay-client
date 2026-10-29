import 'package:record/record.dart';

/// Voice notes — WhatsApp interaction model: hold to record, slide up to lock,
/// slide left to cancel, release to send.
class VoiceRecorder {
  final AudioRecorder _recorder = AudioRecorder();

  Future<bool> hasPermission() => _recorder.hasPermission();

  Future<void> start() async {
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc, // .m4a — plays everywhere (Android/Windows/web)
        bitRate: 96000,
        sampleRate: 44100,
        numChannels: 1,
      ),
      path: null, // stream mode — caller drains via stream()
    );
  }

  Stream<Uint8ListX> stream() => _recorder.stream().map(Uint8ListX.new);

  Future<String?> stop() => _recorder.stop();

  Future<bool> get isRecording => _recorder.isRecording();

  Future<void> pause() => _recorder.pause();
  Future<void> resume() => _recorder.resume();

  Future<void> dispose() => _recorder.dispose();
}

typedef Uint8ListX = List<int>;
