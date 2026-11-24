# Local speech and OCR assets

Kokoro-82M v1.0 int8 (hexgrad and upstream contributors), Apache-2.0.
Downloaded from k2-fsa/sherpa-onnx `tts-models/kokoro-int8-multi-lang-v1_0.tar.bz2`.
Archive SHA-256: 72c347230107ef8a31098ec4d468a605244beef5f1ed00db97efa13518800653.
Runtime inference uses the official Microsoft ONNX Runtime Android 1.23.2 (MIT).
No sherpa-onnx, espeak-ng, or Android TextToSpeech runtime is packaged.

Misaki English word lists and phonemizer model, Apache-2.0.
Dictionary/G2P logic copyright hexgrad; neural fallback PeterReid/graphemes_to_phonemes_en_us.
ONNX packaging by nekwo / Eternia launcher. Source and artifact details:
https://huggingface.co/nekwo/misaki-en-us-g2p-onnx/tree/4b3a605d2f605318ab4f762ab9855c44106528b7
- misaki-en_us-g2p.onnx: 757759c3e3ccb0bf59c379b1671c9834a27543ceaefd6846850823633b9665a1
- misaki-en_us-g2p.json: 8a8e3350713b0a00102425a5d5bd6b58b34854c74a3e8d837589f55212c51658

English OCR trained data: tesseract-ocr/tessdata_fast, tag 4.1.0, Apache-2.0.
https://github.com/tesseract-ocr/tessdata_fast/tree/4.1.0
eng.traineddata SHA-256: 7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2.
Tesseract4Android 4.9.0 (Apache-2.0) embeds Tesseract, Leptonica, PNG and JPEG libraries;
upstream notices: https://github.com/adaptech-cz/Tesseract4Android/tree/4.9.0.

License texts accompanying these assets are in licenses/. Kokoro's archive also
retains its upstream LICENSE at installation. No book passages are downloaded
or uploaded by synthesis or OCR. The explicitly chosen model download fetches
only the pinned public asset bytes.
