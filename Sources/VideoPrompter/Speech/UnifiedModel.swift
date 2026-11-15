#if os(macOS)
/// Exact 320 ms [70,2,2] export; no model weights are bundled.
enum UnifiedModel {
  // Select the runtime configuration and its matching pinned export together.
  static let tier = (chunkFrames: 2, rightFrames: 2, folder: "parakeet-unified-320ms", files: files320)
  static var chunkFrames: Int { tier.chunkFrames }
  static var rightFrames: Int { tier.rightFrames }
  static var folder: String { tier.folder }
  static var files: [ParakeetModel.File] { tier.files }
  static let revision = "d32e972dd4315f1dc3f6be28fb2aab0ab3e80358"
  static let baseURL = "https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml/resolve/\(revision)/"
  private static let files320: [ParakeetModel.File] = [
    .init(path: "parakeet_unified_decoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "9ae70f6559989f88b856b326e59315798f9f0d08207a19fcc2dd3287a30088a5"),
    .init(path: "parakeet_unified_decoder.mlmodelc/coremldata.bin", size: 560, sha256: "ce99c4488840fc463d59f8d4d6d2a9e8ceae8138ead51e3c265dde4d2ba4a0e9"),
    .init(path: "parakeet_unified_decoder.mlmodelc/model.mil", size: 13102, sha256: "6e60965b89c93943aa2be2d991c2461108145851fde05e1d048223a32d4cb20d"),
    .init(path: "parakeet_unified_decoder.mlmodelc/weights/weight.bin", size: 14429952, sha256: "96f990461a5986d5e7309ad1a0f36084fbf0f4b28aec35948f8b8d0dcbf8599e"),
    .init(path: "parakeet_unified_encoder_streaming_70_2_2_int8.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "381de2c3c951682d57c68434c1b514b0a927649959e244207418f1853b0bffa0"),
    .init(path: "parakeet_unified_encoder_streaming_70_2_2_int8.mlmodelc/coremldata.bin", size: 513, sha256: "53d87fd3585ac4dc6a777f8f3471cd83af7e3f45c02084bbbcba8ec37e92a996"),
    .init(path: "parakeet_unified_encoder_streaming_70_2_2_int8.mlmodelc/model.mil", size: 924694, sha256: "9c2e11ffd6e06b6acf1ded06a37701bb2f710bd88842420ad2db4f7385303cc0"),
    .init(path: "parakeet_unified_encoder_streaming_70_2_2_int8.mlmodelc/weights/weight.bin", size: 589486784, sha256: "19335544401c6bd94344b2b3ae633d0478ea5f02b8173c97868c719051ae7397"),
    .init(path: "parakeet_unified_joint_decision_single_step.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "163877ad14af97ec4107cd854fd1c6d336ee5d40ad25a657cc764fb763f452f5"),
    .init(path: "parakeet_unified_joint_decision_single_step.mlmodelc/coremldata.bin", size: 556, sha256: "68a081570a48b52ec9379e153bd56748a5408a50be16767601563f231eaeff03"),
    .init(path: "parakeet_unified_joint_decision_single_step.mlmodelc/model.mil", size: 9611, sha256: "03c21096090bcd0b71c896c5ae0eb815db31a91c6676f572a7868eee4299abe3"),
    .init(path: "parakeet_unified_joint_decision_single_step.mlmodelc/weights/weight.bin", size: 3446978, sha256: "06831afa6d1beb0c0b10350ebf7886bc37638e951d14e738d7e06fbd2a05012f"),
    .init(path: "vocab.json", size: 15088, sha256: "e1a7bff4f5df133c0f4ad47b8e43c96f6bf1865d99126a4c4725ef51d0108bec"),
  ]
  static var size: Int { files.reduce(0) { $0 + $1.size } }
}
#endif
