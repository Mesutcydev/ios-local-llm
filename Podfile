platform :ios, '27.0'

project 'OnDeviceCoreAIStudio.xcodeproj'

target 'IOSLocalLLM' do
  # Native ONNX inference for the official KittenTTS 0.8 artifacts.
  # Pinned so a catalog download can never change the runtime ABI beneath it.
  pod 'onnxruntime-objc', '1.23.0'

  target 'IOSLocalLLMTests' do
    inherit! :search_paths
  end
end
