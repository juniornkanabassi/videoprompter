#if os(macOS)
/// Exact 640 ms [70,7,1] export; no model weights are bundled.
enum UnifiedModel {
  // Select the runtime configuration and its matching pinned export together.
  static let tier = (chunkFrames: 7, rightFrames: 1, folder: "parakeet-unified-640ms", files: files640)
  static var chunkFrames: Int { tier.chunkFrames }
  static var rightFrames: Int { tier.rightFrames }
  static var folder: String { tier.folder }
  static var files: [ParakeetModel.File] { tier.files }
  static let revision = "d32e972dd4315f1dc3f6be28fb2aab0ab3e80358"
  static let baseURL = "https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml/resolve/\(revision)/"
  private static let files640: [ParakeetModel.File] = [
    .init(path: "parakeet_unified_decoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "9ae70f6559989f88b856b326e59315798f9f0d08207a19fcc2dd3287a30088a5"),
    .init(path: "parakeet_unified_decoder.mlmodelc/coremldata.bin", size: 560, sha256: "ce99c4488840fc463d59f8d4d6d2a9e8ceae8138ead51e3c265dde4d2ba4a0e9"),
    .init(path: "parakeet_unified_decoder.mlmodelc/model.mil", size: 13102, sha256: "6e60965b89c93943aa2be2d991c2461108145851fde05e1d048223a32d4cb20d"),
    .init(path: "parakeet_unified_decoder.mlmodelc/weights/weight.bin", size: 14429952, sha256: "96f990461a5986d5e7309ad1a0f36084fbf0f4b28aec35948f8b8d0dcbf8599e"),
    .init(path: "parakeet_unified_encoder_streaming_70_7_1_int8.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "532a29eef8fb961a6670b82912bcfba6c5969de5f2a444192df917ba6f68ba24"),
    .init(path: "parakeet_unified_encoder_streaming_70_7_1_int8.mlmodelc/coremldata.bin", size: 513, sha256: "aebf6dec20848b9d6412e8a6643925479159314fcbee15ea0363350ce9fe732b"),
    .init(path: "parakeet_unified_encoder_streaming_70_7_1_int8.mlmodelc/model.mil", size: 928896, sha256: "6a26ecda0a7c19e0caec5640ac3c49c2111496e63230ec9e146f391f10f456e8"),
    .init(path: "parakeet_unified_encoder_streaming_70_7_1_int8.mlmodelc/weights/weight.bin", size: 589683392, sha256: "4d2056957de09ac202ffd17127e32acfe7e8c381978bf727400de64f88c7c4ff"),
    .init(path: "parakeet_unified_joint_decision_single_step.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "163877ad14af97ec4107cd854fd1c6d336ee5d40ad25a657cc764fb763f452f5"),
    .init(path: "parakeet_unified_joint_decision_single_step.mlmodelc/coremldata.bin", size: 556, sha256: "68a081570a48b52ec9379e153bd56748a5408a50be16767601563f231eaeff03"),
    .init(path: "parakeet_unified_joint_decision_single_step.mlmodelc/model.mil", size: 9611, sha256: "03c21096090bcd0b71c896c5ae0eb815db31a91c6676f572a7868eee4299abe3"),
    .init(path: "parakeet_unified_joint_decision_single_step.mlmodelc/weights/weight.bin", size: 3446978, sha256: "06831afa6d1beb0c0b10350ebf7886bc37638e951d14e738d7e06fbd2a05012f"),
    .init(path: "vocab.json", size: 15088, sha256: "e1a7bff4f5df133c0f4ad47b8e43c96f6bf1865d99126a4c4725ef51d0108bec"),
  ]
  static var size: Int { files.reduce(0) { $0 + $1.size } }
}
#endif
