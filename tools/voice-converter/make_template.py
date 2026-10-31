#!/usr/bin/env python3
"""Makes the template the app fills in when it turns a .pth into a voice (Sources/VoiceConverter.swift):

  python3 make_template.py CONVERTED.mlmodelc voices/templates/RATE

CONVERTED is any voice convert_voice.py made at that sample rate (48000, 40000 or 32000). A template holds the model's
layout and none of its voice: model.mil with every place a number from the voice goes marked with @, plus
coremldata.bin and analytics/coremldata.bin. Rebuild the templates when convert_voice.py's model changes.
"""
import math
import os
import re
import shutil
import sys

# What convert_voice.py's quantize() sees: bigger weights are 8-bit, and the app's converter keeps a weight 16-bit
# itself when it has a nearly flat slice. So every big weight is written in its 8-bit form here, whichever form this
# voice had. Position tables stay 16-bit: their padding is always flat.
SMALL = 2048
OFFSET = re.compile(r"offset = tensor<uint64, \[\]>\(\d+\)")
BLOB = 'BLOBFILE(path = tensor<string, []>("@model_path/weights/weight.bin"), offset = tensor<uint64, []>(@))'


def as_8_bit(line):
    """A plain weight's line as coremltools writes it when the weight is 8-bit."""
    m = re.match(r"(\s*)tensor<fp16, \[([\d, ]*)\]> (g_\w+_to_fp16) = const\(\)", line)
    if not m:
        return line
    indent, dims, name = m.groups()
    shape = [int(d) for d in dims.split(", ")]
    if math.prod(shape) <= SMALL:
        return line
    axis = 1 if name.startswith("g_dec_ups_") else 0  # ConvTranspose1d's output channels
    quantized = name + "_quantized"
    channels = "[%d]" % shape[axis]
    return ('%stensor<fp16, [%s]> %s = constexpr_affine_dequantize()[axis = tensor<int32, []>(%d), name = tensor<string, []>("%s"), '
            "quantized_data = tensor<int8, [%s]>(%s), scale = tensor<fp16, %s>(%s), zero_point = tensor<int8, %s>(%s)];\n"
            % (indent, dims, quantized, axis, quantized, dims, BLOB, channels, BLOB, channels, BLOB))


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    model, out = sys.argv[1:]
    with open(os.path.join(model, "model.mil")) as f:
        lines = f.readlines()
    text = "".join(lines)
    # source * weight + bias, the two numbers of the voice that live in model.mil itself.
    weight = re.search(r"var_\d+_cast_fp16 = mul\(x = source_to_fp16, y = (var_\d+_to_fp16)\)", text).group(1)
    made = re.search(r"(var_\d+_cast_fp16) = mul\(x = source_to_fp16", text).group(1)
    bias = re.search(r"= add\(x = %s, y = (var_\d+_to_fp16)\)" % made, text).group(1)
    written, renamed = [], []
    for line in lines:
        if "BLOBFILE" in line:
            before = line
            line = as_8_bit(line)
            if line != before:
                renamed.append(re.search(r"(g_\w+_to_fp16)_quantized", line).group(1))
            line = OFFSET.sub("offset = tensor<uint64, []>(@)", line)
        for name, mark in ((weight, "@WEIGHT@"), (bias, "@BIAS@")):
            if line.lstrip().startswith("tensor<fp16, []> %s = const()" % name):
                line = re.sub(r"val = tensor<fp16, \[\]>\([^)]*\)", "val = tensor<fp16, []>(%s)" % mark, line)
        written.append(line)
    text = "".join(written)
    for name in renamed:
        text = re.sub(r"(weight = %s)([,)])" % name, r"\1_quantized\2", text)
    os.makedirs(os.path.join(out, "analytics"), exist_ok=True)
    with open(os.path.join(out, "model.mil"), "w") as f:
        f.write(text)
    for name in ("coremldata.bin", "analytics/coremldata.bin"):
        shutil.copyfile(os.path.join(model, name), os.path.join(out, name))
    print("%s: %d stored tensors, %d written back to 8-bit" % (out, text.count("BLOBFILE"), len(renamed)))


if __name__ == "__main__":
    main()
