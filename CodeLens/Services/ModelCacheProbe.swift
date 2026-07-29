import Foundation

// MARK: - ModelCacheProbe
//
// Shared on-disk "is this model directory usable?" check. Both
// CodingAssistantService and MLXVisionService need to answer the same
// question — "do we have a complete model here, or just a partial
// download?" — and they MUST agree on the answer, otherwise one service's
// "Preparing" pill becomes the other's mid-load error.
//
// A directory is usable when it contains either:
//   • a validated GGUF text model or GGUF VLM pair (`GGUF` magic bytes,
//     plus `mmproj-*.gguf` for vision), OR
//   • a config/tokenizer companion plus at least one weights file
//     (.safetensors / .npz / .bin)
//
// AND, when the weights are sharded (a `model.safetensors.index.json` is
// present), EVERY shard the index references must be on disk. Without that
// last check, an interrupted download of a multi-file model (e.g.
// Qwen3-4B-4bit ships as model-00001-of-00002 + model-00002-of-00002) can
// land config.json + one shard, pass as "cached", and trip MLX into a
// mid-load "Key model.layers.N.…weight not found" error because the tensors
// in the missing shard never made it to disk. Rejecting the partial dir lets
// the loader fall back to the repo-id config so HubApi re-fetches the rest.

enum ModelCacheProbe {

    /// True when `dir` exists and passes the shared foundation validator.
    /// Returns false on missing dir, unsupported layout, corrupt GGUF magic,
    /// or a partial/incomplete sharded download.
    static func isUsableModelDirectory(_ dir: URL) -> Bool {
        LocalModelFileValidator.validateModelRoot(dir).isSupported
    }

    /// Parses a `model.safetensors.index.json` and returns the set of shard
    /// filenames its `weight_map` references. Returns nil when the file can't
    /// be read or parsed — callers then fall back to the looser check rather
    /// than reject a directory over an unreadable index.
    private static func requiredShards(indexURL: URL) -> Set<String>? {
        guard
            let data = try? Data(contentsOf: indexURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let weightMap = json["weight_map"] as? [String: String]
        else { return nil }
        let shards = Set(weightMap.values)
        return shards.isEmpty ? nil : shards
    }
}
