# Voice activity stage and assets

Varta runs genuine Silero VAD through whisper.cpp v1.8.3 before Whisper ASR. It does
not substitute RMS, blank suppression or a decoder no-speech threshold for voice
activity detection. The detector processes each original 16 kHz mono WAV window,
bounded to 30 seconds, with two CPU threads. VAD memory is released before ASR.

The fixed policy uses threshold 0.5, minimum speech 250 ms, minimum silence 100 ms,
speech padding 30 ms and no overlapping decode crops. Native centisecond boundaries
convert to original sample frames; overlapping/touching padded spans merge. ASR
reads those original-buffer ranges and restores their offsets. Original source and
prepared audio are never rewritten or compacted.

Both engines accumulate bounded PCM reads because AVFoundation may return fewer
frames than requested before EOF. The shared reader requires exact file length and
position, finite samples and forward progress; it never pads missing samples.
The sample array remains alive throughout each synchronous native call.

Quiet windows complete without calling Whisper. Successful all-quiet processing
preserves prior transcript, generated outputs and audio, records a completed job
with a no-speech diagnostic, and shows a no-speech message. A positive speech
decision followed by empty or invalid ASR output fails instead of becoming silence.

Checkpoints bind meeting/source IDs, language, transcript revision, exact prepared
window ownership/frame timeline, VAD model/policy and Whisper metadata identity.
Changed or legacy identities reject Resume without deleting data. Source IDs and
revision are checked again inside the completion transaction. Only a complete
accepted original window advances the checkpoint; interrupted processing reruns
the pending window. Whisper identity detects ordinary file selection, replacement
and modification through path/inode/size/mtime metadata, not unchanged-metadata
tampering or cryptographic model certification.

## Pinned model and licence

| Field | Value |
|---|---|
| Publisher | ggml-org/whisper-vad |
| Revision | 9ffd54a1e1ee413ddf265af9913beaf518d1639b |
| File | ggml-silero-v6.2.0.bin |
| Bytes | 885,098 |
| SHA-256 | 2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987 |
| Licence | MIT; retain the upstream copyright and permission notice when redistributing |

[Immutable model](https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v6.2.0.bin),
[publisher metadata](https://huggingface.co/api/models/ggml-org/whisper-vad/tree/9ffd54a1e1ee413ddf265af9913beaf518d1639b?recursive=true&expand=false),
[pinned model card](https://huggingface.co/ggml-org/whisper-vad/blob/9ffd54a1e1ee413ddf265af9913beaf518d1639b/README.md),
[Silero licence](https://github.com/snakers4/silero-vad/blob/be95df9152c0d7618fa1edfeb296fc3dae32376f/LICENSE).
The publisher supplies converted weights; its model card does not provide an exact
conversion command/tool hash. Varta verifies the published bytes rather than
claiming independently reproduced training or conversion.

Settings accepts only a readable local file matching the exact size/checksum.
The default manifest path is Models/vad/ggml-silero-v6.2.0.bin beneath app companion
storage. The app does not download weights automatically.

## Native failure and cancellation boundary

Pinned v1.8.3 can return success after a VAD graph-compute failure, leaving unwritten
probabilities. The detector primes a same-sized probability buffer with NaN after
a silence warm-up, then requires every actual-input probability to be overwritten,
finite and within [0,1] before segmentation. Incomplete work cannot become a quiet
decision. This guard follows the exact
[pinned native implementation](https://github.com/ggml-org/whisper.cpp/blob/v1.8.3/src/whisper.cpp#L5086).

The pinned standalone VAD API has no abort callback. Cancellation is checked before
loading, before/between/after native calls and before checkpoint advance. One native
call over at most 30 seconds of audio may finish before cancellation is observed;
this is an audio-length bound, not a certified wall-time latency bound.

## Verification boundary

Public standard macOS CI prepares the small model and official pinned jfk.wav,
verifies their sizes/checksums, model window/context header and 13 native exports,
then runs mandatory real VAD silence/speech/mixed-offset tests. Only fixture
metadata and upstream MIT notices are uploaded alongside test evidence, not model
weights or downloaded audio. The upstream samples README gives no separate
recording-specific licence; the fixture manifest records that qualification and
retains the repository MIT notice.

The fixture helper refuses downloads outside the CI runner. No ASR/LLM weights are
downloaded in CI. Native VAD execution on a fixed English clip and silence does not
certify bilingual/noisy-speech quality, physical microphone/system timing, rendered
UI, four-hour performance or distribution signing/notarisation.
