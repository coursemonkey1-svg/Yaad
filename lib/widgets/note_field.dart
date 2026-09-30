import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// A note field with a mic button: speak in English, Urdu or Roman Urdu
/// (whatever the device keyboard / speech engine supports) and the words
/// land in the note. Keeps capture to seconds.
class NoteField extends StatefulWidget {
  final TextEditingController controller;
  const NoteField({super.key, required this.controller});

  @override
  State<NoteField> createState() => _NoteFieldState();
}

class _NoteFieldState extends State<NoteField> {
  final SpeechToText _speech = SpeechToText();
  bool _listening = false;

  Future<void> _toggle() async {
    if (_listening) {
      await _speech.stop();
      setState(() => _listening = false);
      return;
    }
    final ok = await _speech.initialize();
    if (!ok || !mounted) return;
    setState(() => _listening = true);
    await _speech.listen(
      onResult: (r) {
        widget.controller.text = r.recognizedWords;
      },
    );
    if (mounted) setState(() => _listening = false);
  }

  @override
  void dispose() {
    _speech.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      maxLines: 2,
      decoration: InputDecoration(
        labelText: 'Note (optional)',
        hintText: 'e.g. dinner with Ali, paid my share',
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          icon: Icon(_listening ? Icons.mic : Icons.mic_none_outlined,
              color: _listening ? Colors.red : null),
          tooltip: _listening ? 'Listening… tap to stop' : 'Speak note',
          onPressed: _toggle,
        ),
      ),
    );
  }
}
