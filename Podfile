platform :ios, '18.0'

project 'CodeLens.xcodeproj'

target 'CodeLens' do
  # Native ONNX inference for the official KittenTTS 0.8 artifacts.
  # Pinned so a catalog download can never change the runtime ABI beneath it.
  pod 'onnxruntime-objc', '1.23.0'

  target 'CodeLensTests' do
    inherit! :search_paths
  end
end
