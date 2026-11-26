platform :ios, '18.0'

project 'IOSLocalLLM.xcodeproj'

target 'IOSLocalLLM' do
  # Native ONNX inference for the official KittenTTS 0.8 artifacts.
  # Pinned so a catalog download can never change the runtime ABI beneath it.
  pod 'onnxruntime-objc', '1.29.0'

  target 'IOSLocalLLMTests' do
    inherit! :search_paths
  end
end

# Without an explicit floor, Mac Catalyst maps the ONNX pods to macOS 10.15,
# which Xcode 27 rejects. Pods share the app's iOS 18 floor.
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0'
    end
  end
end

# ONNX Runtime 1.29 ships no Mac Catalyst slice, so the Mac build links none
# of it. OnnxTTSEngines.swift stands in for its API there, and the ONNX voices
# report "not available on Mac".
post_integrate do |installer|
  installer.aggregate_targets.each do |aggregate|
    aggregate.user_build_configurations.each_key do |name|
      path = aggregate.xcconfig_path(name)
      text = File.read(path)
      flags = text[/^OTHER_LDFLAGS = (.*)$/, 1] or next
      # In a conditional setting $(inherited) means this file's unconditional
      # value, which would bring the ONNX flags back; drop it.
      mac = flags.sub('$(inherited) ', '').sub(' -l"onnxruntime-objc"', '').sub(' -framework "onnxruntime"', '')
      # Rewrite rather than append: pod install runs after every XcodeGen
      # regeneration, and appending again would stack identical lines.
      text = text.gsub(/^OTHER_LDFLAGS\[sdk=macosx\*\] = .*\n/, '')
      text += "\n" unless text.end_with?("\n")
      File.write(path, "#{text}OTHER_LDFLAGS[sdk=macosx*] = #{mac}\n")
    end
  end
end
