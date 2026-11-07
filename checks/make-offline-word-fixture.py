#!/usr/bin/env python3
"""Convert `transcribe` + whisper-cli -ml 1 -sow -ojf JSON, never live candidates.

Usage: make-offline-word-fixture.py input.json output.jsonl.deflate [source-offset-seconds]
Input/output must be explicitly provided; this never modifies the recording or script.
"""
import json
import sys
import zlib
from pathlib import Path


def convert(source, offset=0):
    words = []
    for segment in source['transcription']:
        text = segment['text'].strip()
        # Empty timestamp tokens and marked non-speech (e.g. *Clap*) are not words.
        if not text or (text.startswith('*') and text.endswith('*')):
            continue
        start, end = (round(segment['offsets'][key] / 1000 + offset, 3) for key in ('from', 'to'))
        if not 0 <= start <= end or (words and start < words[-1]['end']):
            raise ValueError('Non-monotonic word timings')
        if len(text.split()) != 1:
            raise ValueError('Expected one word per segment; use -ml 1 -sow')
        words.append(dict(text=text, start=start, end=end))
    if not words:
        raise ValueError('No words')
    text = ''.join(json.dumps(word, ensure_ascii=False, separators=(',', ':')) + '\n' for word in words)
    compressor = zlib.compressobj(9, wbits=-15)  # NSData.CompressionAlgorithm.zlib uses raw DEFLATE.
    return compressor.compress(text.encode()) + compressor.flush()


if __name__ == '__main__':
    Path(sys.argv[2]).write_bytes(convert(json.loads(Path(sys.argv[1]).read_text()), float(sys.argv[3]) if len(sys.argv) > 3 else 0))
