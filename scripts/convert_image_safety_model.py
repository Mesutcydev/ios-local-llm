#!/usr/bin/env python3
"""Convert the pinned GantMan MobileNet v1.1.0 graph without TensorFlow.

Requires coremltools==9.0, numpy==1.26.4, Pillow. Model weights are build inputs,
not part of the source distribution. This converter accepts only the verified
upstream graph and rejects unsupported operations instead of approximating them.
"""
import argparse
import hashlib
import math
import struct
from pathlib import Path

import coremltools as ct
import numpy as np
from coremltools.models import datatypes
from coremltools.models.neural_network import NeuralNetworkBuilder
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
RELEASE_SHA256 = "57278dd5a158b7ad8cb4f8d32f26c5f836d0d038044a2119f76fecff7aa241e9"
GRAPH_SHA256 = "5b59e8562d54c53d5948a9fc25d0c3d9b27e4797026ca7cb0248fb20f0e09987"
LABELS = ["drawings", "hentai", "neutral", "porn", "sexy"]
OUTPUT = "sequential/prediction/Softmax"


def varint(data, position):
    value = shift = 0
    while True:
        byte = data[position]
        position += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return value, position
        shift += 7
        if shift > 70:
            raise ValueError("Invalid protobuf varint")


def fields(data):
    """Read the subset of protobuf wire types used by the pinned GraphDef."""
    position, result = 0, {}
    while position < len(data):
        tag, position = varint(data, position)
        number, wire = tag >> 3, tag & 7
        if wire == 0:
            value, position = varint(data, position)
        elif wire == 2:
            length, position = varint(data, position)
            value = data[position:position + length]
            position += length
        elif wire in (1, 5):
            length = 8 if wire == 1 else 4
            value = data[position:position + length]
            position += length
        else:
            raise ValueError(f"Unsupported protobuf wire type {wire}")
        result.setdefault(number, []).append(value)
    return result


def int_list(attribute):
    values = fields(attribute[1][0]).get(3, [])
    if not values:
        return []
    if isinstance(values[0], int):
        return values
    result, position = [], 0
    while position < len(values[0]):
        value, position = varint(values[0], position)
        result.append(value)
    return result


def tensor(attribute):
    value = fields(attribute[8][0])
    shape = [fields(dimension)[1][0] for dimension in fields(value[2][0]).get(2, [])]
    dtype = {1: np.dtype("<f4"), 3: np.dtype("<i4")}[value[1][0]]
    if 4 in value:
        array = np.frombuffer(value[4][0], dtype=dtype)
    elif dtype.kind == "f":
        array = np.array([struct.unpack("<f", item)[0] for item in value[5]], dtype=dtype)
    else:
        array = np.array(value.get(7, []), dtype=dtype)
    count = math.prod(shape)
    if array.size == 1 and count > 1:
        array = np.repeat(array, count)
    return array.reshape(shape)


def load_graph(path):
    nodes = {}
    for raw in fields(path.read_bytes())[1]:
        item = fields(raw)
        attrs = {}
        for raw_attribute in item.get(5, []):
            attribute = fields(raw_attribute)
            attrs[attribute[1][0].decode()] = fields(attribute[2][0])
        name = item[1][0].decode()
        nodes[name] = {
            "name": name, "op": item[2][0].decode(), "attrs": attrs,
            "inputs": [value.decode().removesuffix(":0") for value in item.get(3, [])
                       if not value.startswith(b"^")],
        }
    return nodes


def resolve(nodes, name):
    while nodes[name]["op"] == "Identity":
        name = nodes[name]["inputs"][0]
    return name


def convert(nodes):
    builder = NeuralNetworkBuilder([("image", datatypes.Array(3, 224, 224))],
                                   [("scores", datatypes.Array(5, 1, 1))])
    builder.set_pre_processing_parameters(image_input_names=["image"], image_scale=1 / 255)
    blobs, constants = {}, {}

    def constant(name):
        name = resolve(nodes, name)
        if name not in constants:
            assert nodes[name]["op"] == "Const", name
            constants[name] = tensor(nodes[name]["attrs"]["value"])
        return constants[name]

    def emit(name):
        name = resolve(nodes, name)
        if name in blobs:
            return blobs[name]
        node = nodes[name]
        op, inputs, attrs = node["op"], node["inputs"], node["attrs"]
        if op == "Placeholder":
            blobs[name] = "image"
            return "image"
        source = emit(inputs[0])
        output = "scores" if name == OUTPUT else f"value_{len(blobs)}"
        if op in ("Mul", "Sub"):
            scalar = constant(inputs[1])
            assert scalar.size == 1
            value = float(scalar.reshape(-1)[0])
            builder.add_scale(output, np.array([value if op == "Mul" else 1], dtype=np.float32),
                              np.array([-value if op == "Sub" else 0], dtype=np.float32),
                              True, source, output)
        elif op in ("Conv2D", "DepthwiseConv2dNative"):
            assert attrs["data_format"][2][0] == b"NHWC"
            weights = constant(inputs[1])
            height, width, channels, last = weights.shape
            depthwise = op == "DepthwiseConv2dNative"
            strides = int_list(attrs["strides"])
            builder.add_convolution(
                output, 1 if depthwise else channels, channels * last if depthwise else last,
                height, width, strides[1], strides[2],
                attrs["padding"][2][0].decode().lower(), channels if depthwise else 1,
                weights.reshape(height, width, 1, channels * last) if depthwise else weights,
                None, False, input_name=source, output_name=output,
            )
        elif op == "FusedBatchNormV3":
            assert attrs["is_training"][5][0] == 0
            gamma, beta, mean, variance = [constant(value) for value in inputs[1:5]]
            builder.add_batchnorm(output, gamma.size, gamma, beta, mean, variance,
                                  input_name=source, output_name=output,
                                  epsilon=struct.unpack("<f", attrs["epsilon"][4][0])[0])
        elif op == "Relu6":
            builder.add_clip(output, source, output, min_value=0, max_value=6)
        elif op == "AddV2":
            builder.add_elementwise(output, [source, emit(inputs[1])], output, "ADD")
        elif op == "BiasAdd":
            bias = constant(inputs[1])
            builder.add_bias(output, bias, source, output, shape_bias=[bias.size])
        elif op == "AvgPool":
            kernel, strides = int_list(attrs["ksize"]), int_list(attrs["strides"])
            builder.add_pooling(output, kernel[1], kernel[2], strides[1], strides[2],
                                "AVERAGE", attrs["padding"][2][0].decode(), source, output)
        elif op == "Squeeze":
            assert int_list(attrs["squeeze_dims"]) == [1, 2]
            # Core ML's legacy C,H,W representation keeps the 1x1 spatial axes.
            output = source
        elif op == "MatMul":
            assert attrs["transpose_a"][5][0] == attrs["transpose_b"][5][0] == 0
            weights = constant(inputs[1])
            builder.add_inner_product(output, weights.T, None, weights.shape[0],
                                      weights.shape[1], False, source, output)
        elif op == "Softmax":
            builder.add_softmax(output, source, output)
        else:
            raise ValueError(f"Unsupported reachable operation: {op}")
        blobs[name] = output
        return output

    emit(OUTPUT)
    model = ct.models.MLModel(builder.spec, compute_units=ct.ComputeUnit.CPU_ONLY)
    model.short_description = "Local generated-image sexual-content classifier (MobileNet v1.1.0)."
    model.author = "The nsfw_model Developers; Core ML conversion: iOS Local LLM"
    model.license = "MIT (classifier); Apache-2.0 (TensorFlow Hub MobileNet backbone)"
    model.user_defined_metadata["upstream_release"] = "GantMan/nsfw_model 1.1.0"
    model.user_defined_metadata["class_labels"] = ",".join(LABELS)
    model.user_defined_metadata["release_sha256"] = RELEASE_SHA256
    return model


def reference(nodes, image):
    """Evaluate the original frozen graph with NumPy as a conversion check."""
    cache = {}

    def evaluate(name):
        name = resolve(nodes, name)
        if name in cache:
            return cache[name]
        node = nodes[name]
        op, attrs = node["op"], node["attrs"]
        if op == "Placeholder":
            return image.astype(np.float32)[None] / 255
        if op == "Const":
            return tensor(attrs["value"])
        inputs = [evaluate(value) for value in node["inputs"]]
        x = inputs[0]
        if op == "Mul": result = x * inputs[1]
        elif op == "Sub": result = x - inputs[1]
        elif op in ("Conv2D", "DepthwiseConv2dNative", "AvgPool"):
            is_pool = op == "AvgPool"
            weights = None if is_pool else inputs[1]
            kernel = int_list(attrs["ksize"])[1:3] if is_pool else weights.shape[:2]
            strides = int_list(attrs["strides"])[1:3]
            if attrs["padding"][2][0] == b"SAME":
                pads = [max(0, (math.ceil(x.shape[i + 1] / strides[i]) - 1) * strides[i]
                            + kernel[i] - x.shape[i + 1]) for i in range(2)]
                x = np.pad(x, [(0, 0), (pads[0] // 2, pads[0] - pads[0] // 2),
                               (pads[1] // 2, pads[1] - pads[1] // 2), (0, 0)])
            windows = np.lib.stride_tricks.sliding_window_view(x, kernel, axis=(1, 2))
            windows = windows[:, ::strides[0], ::strides[1]]
            if is_pool: result = windows.mean(axis=(-1, -2))
            elif op == "Conv2D": result = np.einsum("nhwcij,ijco->nhwo", windows, weights, optimize=True)
            else:
                result = np.einsum("nhwcij,ijcm->nhwcm", windows, weights, optimize=True)
                result = result.reshape(*result.shape[:3], -1)
        elif op == "FusedBatchNormV3":
            epsilon = struct.unpack("<f", attrs["epsilon"][4][0])[0]
            result = (x - inputs[3]) / np.sqrt(inputs[4] + epsilon) * inputs[1] + inputs[2]
        elif op == "Relu6": result = np.clip(x, 0, 6)
        elif op in ("AddV2", "BiasAdd"): result = x + inputs[1]
        elif op == "Squeeze": result = np.squeeze(x, axis=tuple(int_list(attrs["squeeze_dims"])))
        elif op == "MatMul": result = x @ inputs[1]
        elif op == "Softmax":
            result = np.exp(x - x.max(axis=-1, keepdims=True))
            result /= result.sum(axis=-1, keepdims=True)
        else: raise ValueError(op)
        cache[name] = result
        return result

    return evaluate(OUTPUT).reshape(-1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--graph", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if hashlib.sha256(args.graph.read_bytes()).hexdigest() != GRAPH_SHA256:
        raise SystemExit("Graph does not match the pinned upstream release")
    nodes = load_graph(args.graph)
    model = convert(nodes)
    # Procedural, non-personal fixtures: no downloaded or objectionable media.
    fixtures = [np.full((224, 224, 3), color, dtype=np.uint8)
                for color in ([0, 0, 0], [255, 255, 255], [30, 140, 70])]
    fixtures.append(np.random.default_rng(42).integers(0, 256, (224, 224, 3), dtype=np.uint8))
    for index, pixels in enumerate(fixtures):
        expected = reference(nodes, pixels)
        actual = np.asarray(model.predict({"image": Image.fromarray(pixels)})["scores"]).reshape(-1)
        np.testing.assert_allclose(actual, expected, rtol=0.002, atol=0.0002)
        assert np.isfinite(actual).all() and abs(actual.sum() - 1) < 0.001
        print(f"Fixture {index}: maximum probability error {np.max(np.abs(actual - expected)):.7f}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    model.save(str(args.output))
    print(f"Verified and saved {args.output}")


if __name__ == "__main__":
    main()
