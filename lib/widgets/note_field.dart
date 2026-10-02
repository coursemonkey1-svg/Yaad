import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../l10n/strings.dart';
import '../main.dart';

/// A note field with a mic button: speak in English, Urdu or Roman Urdu
/// (whatever the device keyboard / speech engine supports) and the words
/// land in the note. Keeps capture to seconds.
///
/// When [micButton] is provided it replaces the built-in mic (used by
/// screens that run their own runtime-permission flow).
class NoteField extends StatefulWidget {
  final TextEditingController controller;
  final Widget? micButton;
  const NoteField({super.key, required this.controller, this.micButton});

  @override
  State<NoteField> createState() => _NoteFieldState();
}

class _NoteFieldState extends State<NoteField> {
  final SpeechToText _speech = SpeechToText();
  bool _listening = false;

  /// Whatever was typed before dictation started. Dictated words are
  /// APPENDED after it — an earlier version replaced the whole field
  /// with every partial transcript, silently wiping the typed note.
  String _baseText = '';

  Future<void> _toggle() async {
    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    final ok = await _speech.initialize();
    if (!ok || !mounted) return;
    _baseText = widget.controller.text;
    setState(() => _listening = true);
    await _speech.listen(
      onResult: (r) {
        if (!mounted) return;
        final words = r.recognizedWords;
        final base = _baseText.trimRight();
        widget.controller.text =
            words.isEmpty ? _baseText : (base.isEmpty ? words : '$base $words');
      },
    );
    // listen()'s future completes when the session ends on its own
    // (silence timeout, engine stop) — reflect that in the icon.
    if (mounted) setState(() => _listening = false);
  }

  @override
  void dispose() {
    _speech.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings(appState.settings.language);
    return TextField(
      controller: widget.controller,
      maxLines: 2,
      decoration: InputDecoration(
        labelText: s.get('note'),
        hintText: 'e.g. dinner with Ali, paid my share',
        border: const OutlineInputBorder(),
        suffixIcon: widget.micButton ??
            IconButton(
              icon: Icon(_listening ? Icons.mic : Icons.mic_none_outlined,
                  color: _listening ? Colors.red : null),
              tooltip: _listening ? s.get('listening') : s.get('speakNote'),
              onPressed: _toggle,
            ),
      ),
    );
  }
}
