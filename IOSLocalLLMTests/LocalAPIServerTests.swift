import XCTest
@testable import IOSLocalLLM

final class LocalAPIServerTests: XCTestCase {
    func testNativeLFM3CallsRespectSchemasAndParallelSetting() throws {
        let tool = LocalAPIToolDefinition(name: "search", description: nil, parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer"}},"required":["query"]}"#)
        let xml = "<tool_call><function=search><parameter=query>007</parameter><parameter=limit>2</parameter></function></tool_call>"
        let calls = LocalAPIToolCalling.parse(xml + xml, tools: [tool], parallelToolCalls: true)
        XCTAssertEqual(calls.count, 2)
        let args = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(calls[0].argumentsJSON.utf8)) as? [String: Any])
        XCTAssertEqual(args["query"] as? String, "007")
        XCTAssertEqual(args["limit"] as? Int, 2)
        XCTAssertEqual(LocalAPIToolCalling.parse(xml + xml, tools: [tool], parallelToolCalls: false).count, 1)
        XCTAssertTrue(LocalAPIToolCalling.parse(xml, tools: [], parallelToolCalls: true).isEmpty)
        XCTAssertTrue(LocalAPIToolCalling.shouldBufferForToolDecision(String(xml.prefix(80))))
    }

    func testNativeLFM3ToolPromptCarriesFunctionSchema() {
        let tool = LocalAPIToolDefinition(name: "lookup", description: "Look up a record", parametersJSON: #"{"type":"object","properties":{}}"#)
        let messages = LocalAPIToolCalling.messages(from: [ChatMessage(role: .user, content: "Find it")], tools: [tool], choice: .function("lookup"), parallelToolCalls: false, nativeLFM3: true)
        XCTAssertEqual(messages.first?.role, .system)
        XCTAssertTrue(messages.first?.content.contains("<tools>") == true)
        XCTAssertTrue(messages.first?.content.contains("You must call the function named lookup") == true)
        XCTAssertFalse(messages.first?.content.contains("output only valid JSON") == true)
    }

    func testNativeLFM3PromptMergesIntoFirstSystemTurn() {
        let tool = LocalAPIToolDefinition(name: "lookup", description: "Look up a record", parametersJSON: #"{"type":"object","properties":{}}"#)
        let messages = LocalAPIToolCalling.messages(from: [
            ChatMessage(role: .system, content: "Be brief."),
            ChatMessage(role: .user, content: "Find it"),
        ], tools: [tool], choice: .auto, parallelToolCalls: true, nativeLFM3: true)
        XCTAssertEqual(messages.filter { $0.role == .system }.count, 1)
        XCTAssertTrue(messages.first?.content.hasPrefix("Be brief.") == true)
        XCTAssertTrue(messages.first?.content.contains("<tools>") == true)
    }

    func testNativeLFM3ToolLinesMatchTemplateFormat() {
        let tool = LocalAPIToolDefinition(name: "lookup", description: "Look up a/b", parametersJSON: #"{"type":"object","properties":{}}"#)
        XCTAssertTrue(LFM3ToolCodec.instructions(tools: [tool]).contains(
            #"{"name": "lookup", "description": "Look up a/b", "parameters": {"properties":{},"type":"object"}}"#))
    }

    func testToolDecisionBuffersReasoningBeforeALFM3Call() {
        XCTAssertTrue(LocalAPIToolCalling.shouldBufferForToolDecision("<think>checking"))
        XCTAssertTrue(LocalAPIToolCalling.shouldBufferForToolDecision(
            "<think>checking</think>\n<tool_call><function=lookup>"))
        XCTAssertFalse(LocalAPIToolCalling.shouldBufferForToolDecision(
            "<think>checking</think>Here is the answer."))
    }
    func testPortValidation() {
        XCTAssertNil(LocalAPIValidation.validPort(1023))
        XCTAssertEqual(LocalAPIValidation.validPort(11434), 11434)
        XCTAssertEqual(LocalAPIValidation.validPort(65535), 65535)
        XCTAssertNil(LocalAPIValidation.validPort(65536))
    }

    func testModelAliases() {
        XCTAssertTrue(LocalAPIValidation.modelMatches("qwen", id: "qwen", repoID: "org/qwen"))
        XCTAssertTrue(LocalAPIValidation.modelMatches("org/qwen", id: "qwen", repoID: "org/qwen"))
        XCTAssertFalse(LocalAPIValidation.modelMatches("other", id: "qwen", repoID: "org/qwen"))
    }

    func testTunnelInterfacesAreExcludedFromLANAddresses() {
        XCTAssertTrue(LocalAPIValidation.isReachableLANInterface("en0"))
        XCTAssertTrue(LocalAPIValidation.isReachableLANInterface("bridge100"))
        XCTAssertFalse(LocalAPIValidation.isReachableLANInterface("utun4"))
        XCTAssertFalse(LocalAPIValidation.isReachableLANInterface("ipsec0"))
        XCTAssertFalse(LocalAPIValidation.isReachableLANInterface("pdp_ip0"))
    }

    func testRemoteInferenceLimitsBoundToolSelection() {
        XCTAssertEqual(
            LocalAPIInferencePolicy.maxTokens(
                requested: 65_536,
                toolCallingEnabled: true
            ),
            256
        )
        XCTAssertEqual(
            LocalAPIInferencePolicy.maxTokens(
                requested: 128,
                toolCallingEnabled: true
            ),
            128
        )
        XCTAssertEqual(
            LocalAPIInferencePolicy.maxTokens(
                requested: nil,
                toolCallingEnabled: true
            ),
            256
        )
        XCTAssertEqual(
            LocalAPIInferencePolicy.maxTokens(
                requested: 65_536,
                toolCallingEnabled: false
            ),
            4_096
        )
        XCTAssertNil(
            LocalAPIInferencePolicy.maxTokens(
                requested: nil,
                toolCallingEnabled: false
            )
        )
    }

    func testRemoteInferenceDeadlinesCoverToolsAndPlainResponses() {
        XCTAssertEqual(
            LocalAPIInferencePolicy.deadline(toolCallingEnabled: true),
            .seconds(30)
        )
        XCTAssertEqual(
            LocalAPIInferencePolicy.deadline(toolCallingEnabled: false),
            .seconds(90)
        )
    }

    func testToolDecisionBuffersOnlyPotentialToolSyntax() {
        XCTAssertTrue(LocalAPIToolCalling.shouldBufferForToolDecision(""))
        XCTAssertTrue(LocalAPIToolCalling.shouldBufferForToolDecision("  {"))
        XCTAssertTrue(LocalAPIToolCalling.shouldBufferForToolDecision("<tool"))
        XCTAssertTrue(LocalAPIToolCalling.shouldBufferForToolDecision("```json\n{"))
        XCTAssertFalse(
            LocalAPIToolCalling.shouldBufferForToolDecision(
                "The weather is sunny."
            )
        )
        XCTAssertFalse(
            LocalAPIToolCalling.shouldBufferForToolDecision(
                #"{"answer":"This is ordinary JSON output, not a tool call, and it is long enough to make that decision without buffering the whole generation."}"#
            )
        )
        XCTAssertTrue(
            LocalAPIToolCalling.shouldBufferForToolDecision(
                #"{"tool_calls":[{"name":"get_weather","arguments":{"city":"Istanbul","units":"metric","include_forecast":true}}]}"#
            )
        )
    }

    func testOpenAIRequestDecodesTextMessagesAndOverrides() throws {
        let data = Data("""
        {
          "model":"qwen",
          "messages":[
            {"role":"system","content":"Be concise."},
            {"role":"user","content":"Hello"}
          ],
          "stream":true,
          "max_tokens":128,
          "temperature":0.2,
          "top_p":0.8
        }
        """.utf8)
        let request = try LocalAPIChatRequest.decodeOpenAI(data)
        XCTAssertEqual(request.model, "qwen")
        XCTAssertEqual(request.messages.count, 2)
        XCTAssertTrue(request.stream)
        XCTAssertEqual(request.maxTokens, 128)
        XCTAssertEqual(request.temperature, 0.2)
        XCTAssertEqual(request.topP, 0.8)
    }

    func testOpenAIAcceptsEmptyTools() throws {
        let data = Data("""
        {"model":"qwen","messages":[{"role":"user","content":"Hi"}],"tools":[]}
        """.utf8)
        let request = try LocalAPIChatRequest.decodeOpenAI(data)
        XCTAssertEqual(request.messages.map(\.content), ["Hi"])
    }

    func testOpenAIDecodesFunctionTools() throws {
        let data = Data("""
        {
          "model":"qwen",
          "messages":[{"role":"user","content":"What is the weather in Cairo?"}],
          "tools":[{
            "type":"function",
            "function":{
              "name":"get_weather",
              "description":"Get weather",
              "parameters":{
                "type":"object",
                "properties":{"city":{"type":"string"}},
                "required":["city"]
              }
            }
          }],
          "tool_choice":"required",
          "parallel_tool_calls":false
        }
        """.utf8)
        let request = try LocalAPIChatRequest.decodeOpenAI(data)
        XCTAssertEqual(request.tools.map(\.name), ["get_weather"])
        XCTAssertEqual(request.tools.first?.description, "Get weather")
        XCTAssertEqual(request.toolChoice, .required)
        XCTAssertFalse(request.parallelToolCalls)
    }

    func testOpenAIAcceptsHermesAgentCustomProviderOptions() throws {
        let data = Data("""
        {
          "model":"qwen",
          "messages":[
            {"role":"system","content":"You are Hermes Agent."},
            {"role":"user","content":"Inspect the workspace."}
          ],
          "tools":[{
            "type":"function",
            "function":{
              "name":"terminal",
              "description":"Run a shell command",
              "parameters":{
                "type":"object",
                "properties":{"command":{"type":"string"}},
                "required":["command"]
              }
            }
          }],
          "stream":true,
          "stream_options":{"include_usage":true},
          "max_tokens":65536,
          "reasoning_effort":"none",
          "think":false,
          "options":{"num_ctx":64000}
        }
        """.utf8)
        let request = try LocalAPIChatRequest.decodeOpenAI(data)
        XCTAssertTrue(request.stream)
        XCTAssertEqual(request.maxTokens, 65_536)
        XCTAssertEqual(request.tools.map(\.name), ["terminal"])
        XCTAssertEqual(request.toolChoice, .auto)

        let inferenceMessages = LocalAPIToolCalling.messages(
            from: request.messages,
            tools: request.tools,
            choice: request.toolChoice,
            parallelToolCalls: request.parallelToolCalls
        )
        XCTAssertFalse(inferenceMessages.contains { $0.role == .system })
        XCTAssertTrue(inferenceMessages.last?.content.contains("You are Hermes Agent.") == true)
        XCTAssertTrue(inferenceMessages.last?.content.contains("Inspect the workspace.") == true)
    }

    func testOpenAIDecodesHermesTextPartArraysAndToolResult() throws {
        let data = Data("""
        {
          "model":"qwen",
          "messages":[
            {"role":"system","content":"You are in agent mode."},
            {"role":"user","content":[{"type":"text","text":"show me the codebase"}]},
            {
              "role":"assistant",
              "content":[{"type":"text","text":"I will inspect the root."}],
              "tool_calls":[{
                "id":"tool_1",
                "type":"function",
                "function":{"name":"terminal","arguments":"{\\"command\\":\\"find . -maxdepth 2\\"}"}
              }]
            },
            {
              "role":"tool",
              "tool_call_id":"tool_1",
              "content":[{"type":"text","text":"README.md\\nsrc/main.py"}]
            },
            {"role":"user","content":[{"type":"input_text","text":"continue"}]}
          ],
          "tools":[{
            "type":"function",
            "function":{
              "name":"terminal",
              "description":"Run a command",
              "parameters":{"type":"object"}
            }
          }],
          "stream":true,
          "messagesOptions":{"precompleted":true}
        }
        """.utf8)
        let request = try LocalAPIChatRequest.decodeOpenAI(data)
        XCTAssertEqual(
            request.messages.map(\.role),
            [.system, .user, .assistant, .user, .user]
        )
        XCTAssertEqual(request.messages[1].content, "show me the codebase")
        XCTAssertTrue(request.messages[2].content.contains("I will inspect the root."))
        XCTAssertTrue(request.messages[2].content.contains("terminal"))
        XCTAssertTrue(request.messages[3].content.contains("README.md\nsrc/main.py"))
        XCTAssertEqual(request.messages[4].content, "continue")
    }

    func testOpenAIRejectsUnknownNamedToolChoice() {
        let data = Data("""
        {
          "model":"qwen",
          "messages":[{"role":"user","content":"Hi"}],
          "tools":[{
            "type":"function",
            "function":{"name":"known","parameters":{"type":"object"}}
          }],
          "tool_choice":{"type":"function","function":{"name":"unknown"}}
        }
        """.utf8)
        XCTAssertThrowsError(try LocalAPIChatRequest.decodeOpenAI(data))
    }

    func testOpenAIDecodesToolCallHistoryAndResult() throws {
        let data = Data("""
        {
          "model":"qwen",
          "messages":[
            {"role":"user","content":"Weather?"},
            {
              "role":"assistant",
              "content":null,
              "tool_calls":[{
                "id":"call_1",
                "type":"function",
                "function":{"name":"get_weather","arguments":"{\\"city\\":\\"Cairo\\"}"}
              }]
            },
            {"role":"tool","tool_call_id":"call_1","content":"31 C, sunny"}
          ]
        }
        """.utf8)
        let request = try LocalAPIChatRequest.decodeOpenAI(data)
        XCTAssertEqual(request.messages.map(\.role), [.user, .assistant, .user])
        XCTAssertTrue(request.messages[1].content.contains("get_weather"))
        XCTAssertTrue(request.messages[2].content.contains("31 C, sunny"))
    }

    func testOpenAIPreservesAssistantTextAlongsideToolCallHistory() throws {
        let data = Data("""
        {
          "model":"qwen",
          "messages":[{
            "role":"assistant",
            "content":"I will inspect that.",
            "tool_calls":[{
              "id":"call_1",
              "type":"function",
              "function":{"name":"terminal","arguments":"{\\"command\\":\\"pwd\\"}"}
            }]
          }]
        }
        """.utf8)
        let request = try LocalAPIChatRequest.decodeOpenAI(data)
        XCTAssertTrue(request.messages[0].content.contains("I will inspect that."))
        XCTAssertTrue(request.messages[0].content.contains("terminal"))
        XCTAssertTrue(request.messages[0].content.contains("call_1"))
    }

    func testToolCallingPromptAndParser() {
        let tool = LocalAPIToolDefinition(
            name: "get_weather",
            description: "Get weather",
            parametersJSON: #"{"properties":{"city":{"type":"string"}},"type":"object"}"#
        )
        let messages = LocalAPIToolCalling.messages(
            from: [ChatMessage(role: .user, content: "Weather in Cairo?")],
            tools: [tool],
            choice: .auto,
            parallelToolCalls: true
        )
        XCTAssertEqual(messages.first?.role, .user)
        XCTAssertTrue(messages.first?.content.contains("get_weather") == true)
        XCTAssertTrue(messages.first?.content.contains("Weather in Cairo?") == true)

        let calls = LocalAPIToolCalling.parse(
            """
            <tool_call>
            {"tool_calls":[{"name":"get_weather","arguments":{"city":"Cairo"}}]}
            </tool_call>
            """,
            tools: [tool],
            parallelToolCalls: true
        )
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "get_weather")
        XCTAssertEqual(calls.first?.argumentsJSON, #"{"city":"Cairo"}"#)
    }

    func testToolCallingParserCollectsParallelHermesCalls() {
        let tools = [
            LocalAPIToolDefinition(
                name: "read_file",
                description: nil,
                parametersJSON: #"{"type":"object"}"#
            ),
            LocalAPIToolDefinition(
                name: "terminal",
                description: nil,
                parametersJSON: #"{"type":"object"}"#
            )
        ]
        let calls = LocalAPIToolCalling.parse(
            """
            <tool_call>{"name":"read_file","arguments":{"path":"README.md"}}</tool_call>
            <tool_call>{"name":"terminal","parameters":{"command":"pwd"}}</tool_call>
            """,
            tools: tools,
            parallelToolCalls: true
        )
        XCTAssertEqual(calls.map(\.name), ["read_file", "terminal"])
        XCTAssertEqual(calls[1].argumentsJSON, #"{"command":"pwd"}"#)
    }

    func testToolCallingParserAcceptsAppStyleArgs() {
        let tool = LocalAPIToolDefinition(
            name: "get_weather",
            description: nil,
            parametersJSON: #"{"type":"object"}"#
        )
        let calls = LocalAPIToolCalling.parse(
            #"{"name":"get_weather","args":{"city":"Asyut"}}"#,
            tools: [tool],
            parallelToolCalls: false
        )
        XCTAssertEqual(calls.first?.name, "get_weather")
        XCTAssertEqual(calls.first?.argumentsJSON, #"{"city":"Asyut"}"#)
    }

    func testOpenAIResponsesDecodesTextInputBlocks() throws {
        let data = Data("""
        {
          "model":"qwen",
          "instructions":"Be concise.",
          "input":[{
            "role":"user",
            "content":[{"type":"input_text","text":"Hi"}]
          }],
          "tools":[],
          "max_output_tokens":64
        }
        """.utf8)
        let request = try LocalAPIChatRequest.decodeOpenAIResponses(data)
        XCTAssertEqual(request.messages.map(\.role), [.system, .user])
        XCTAssertEqual(request.messages.map(\.content), ["Be concise.", "Hi"])
        XCTAssertEqual(request.maxTokens, 64)
        XCTAssertFalse(request.stream)
    }

    func testOpenAIResponsesAcceptsStringInput() throws {
        let data = Data("""
        {"model":"qwen","input":"Hi","stream":true}
        """.utf8)
        let request = try LocalAPIChatRequest.decodeOpenAIResponses(data)
        XCTAssertEqual(request.messages.map(\.content), ["Hi"])
        XCTAssertTrue(request.stream)
    }

    func testOllamaChatDefaultsToStreaming() throws {
        let data = Data("""
        {"model":"qwen","messages":[{"role":"user","content":"Hi"}]}
        """.utf8)
        XCTAssertTrue(try LocalAPIChatRequest.decodeOllamaChat(data).stream)
    }

    func testOllamaChatCanUseCurrentModelWhenOmitted() throws {
        let data = Data("""
        {"messages":[{"role":"user","content":"Hi"}],"stream":false}
        """.utf8)
        let request = try LocalAPIChatRequest.decodeOllamaChat(data)
        XCTAssertEqual(request.model, "")
        XCTAssertFalse(request.stream)
    }

    func testOllamaChatDecodesToolsAndObjectArgumentsHistory() throws {
        let data = Data("""
        {
          "model":"qwen",
          "messages":[
            {"role":"user","content":"Weather?"},
            {
              "role":"assistant",
              "content":"",
              "tool_calls":[{
                "function":{
                  "name":"get_weather",
                  "arguments":{"city":"Cairo"}
                }
              }]
            },
            {"role":"tool","content":"31 C, sunny"}
          ],
          "tools":[{
            "type":"function",
            "function":{
              "name":"get_weather",
              "description":"Get weather",
              "parameters":{"type":"object"}
            }
          }]
        }
        """.utf8)
        let request = try LocalAPIChatRequest.decodeOllamaChat(data)
        XCTAssertEqual(request.tools.map(\.name), ["get_weather"])
        XCTAssertEqual(request.toolChoice, .auto)
        XCTAssertTrue(request.messages[1].content.contains("get_weather"))
        XCTAssertTrue(request.messages[2].content.contains("31 C, sunny"))
    }

    func testOllamaGenerateBuildsSystemAndUserMessages() throws {
        let data = Data("""
        {"model":"qwen","system":"Be concise.","prompt":"Hi","stream":false}
        """.utf8)
        let request = try LocalAPIChatRequest.decodeOllamaGenerate(data)
        XCTAssertEqual(request.messages.map(\.role), [.system, .user])
        XCTAssertFalse(request.stream)
    }

    func testAnthropicRequestDecodesTextBlocksAndSystem() throws {
        let data = Data("""
        {
          "model":"qwen",
          "system":[{"type":"text","text":"Be concise."}],
          "messages":[{"role":"user","content":[{"type":"text","text":"Hello"}]}],
          "max_tokens":128,
          "stream":true
        }
        """.utf8)
        let request = try LocalAPIChatRequest.decodeAnthropic(data)
        XCTAssertEqual(request.messages.map(\.role), [.system, .user])
        XCTAssertEqual(request.messages.map(\.content), ["Be concise.", "Hello"])
        XCTAssertEqual(request.maxTokens, 128)
        XCTAssertTrue(request.stream)
    }

    func testAnthropicDecodesToolsAndToolResultHistory() throws {
        let data = Data("""
        {
          "model":"qwen",
          "max_tokens":64,
          "messages":[
            {"role":"user","content":"Weather?"},
            {
              "role":"assistant",
              "content":[{
                "type":"tool_use",
                "id":"toolu_1",
                "name":"get_weather",
                "input":{"city":"Cairo"}
              }]
            },
            {
              "role":"user",
              "content":[{
                "type":"tool_result",
                "tool_use_id":"toolu_1",
                "content":"31 C, sunny"
              }]
            }
          ],
          "tools":[{
            "name":"get_weather",
            "description":"Get weather",
            "input_schema":{"type":"object"}
          }],
          "tool_choice":{"type":"auto"}
        }
        """.utf8)
        let request = try LocalAPIChatRequest.decodeAnthropic(data)
        XCTAssertEqual(request.tools.map(\.name), ["get_weather"])
        XCTAssertEqual(request.toolChoice, .auto)
        XCTAssertTrue(request.messages[1].content.contains("toolu_1"))
        XCTAssertTrue(request.messages[2].content.contains("31 C, sunny"))
    }

    func testAnthropicResponseHasCompatibilityShape() throws {
        let data = LocalAPIResponse.anthropicMessage(id: "msg_test", model: "qwen", text: "hello")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "message")
        XCTAssertEqual(object["role"] as? String, "assistant")
        let content = try XCTUnwrap(object["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "hello")
    }

    func testOpenAIChunkHasCompatibilityShape() throws {
        let data = LocalAPIResponse.openAIChunk(
            id: "chatcmpl-test",
            model: "qwen",
            text: "hello",
            role: "assistant"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["object"] as? String, "chat.completion.chunk")
        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let delta = try XCTUnwrap(choices.first?["delta"] as? [String: Any])
        XCTAssertEqual(delta["content"] as? String, "hello")
        XCTAssertEqual(delta["role"] as? String, "assistant")
    }

    func testOpenAIToolCallResponseHasCompatibilityShape() throws {
        let data = LocalAPIResponse.openAIChatCompletion(
            id: "chatcmpl-test",
            model: "qwen",
            text: "",
            toolCalls: [
                LocalAPIToolCall(
                    id: "call_test",
                    name: "get_weather",
                    argumentsJSON: #"{"city":"Cairo"}"#
                )
            ]
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        XCTAssertEqual(choices.first?["finish_reason"] as? String, "tool_calls")
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        XCTAssertTrue(message["content"] is NSNull)
        let calls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(calls.first?["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "get_weather")
        XCTAssertEqual(function["arguments"] as? String, #"{"city":"Cairo"}"#)
    }

    func testAnthropicToolResponseHasCompatibilityShape() throws {
        let data = LocalAPIResponse.anthropicToolMessage(
            id: "msg_test",
            model: "qwen",
            calls: [
                LocalAPIToolCall(
                    id: "toolu_test",
                    name: "get_weather",
                    argumentsJSON: #"{"city":"Cairo"}"#
                )
            ]
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["stop_reason"] as? String, "tool_use")
        let content = try XCTUnwrap(object["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "tool_use")
        XCTAssertEqual(content.first?["id"] as? String, "toolu_test")
    }

    func testOllamaToolResponseHasCompatibilityShape() throws {
        let data = LocalAPIResponse.ollamaToolCalls(
            model: "qwen",
            calls: [
                LocalAPIToolCall(
                    id: "ignored",
                    name: "get_weather",
                    argumentsJSON: #"{"city":"Cairo"}"#
                )
            ],
            done: true
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let message = try XCTUnwrap(object["message"] as? [String: Any])
        let calls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(calls.first?["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "get_weather")
        XCTAssertEqual(
            (function["arguments"] as? [String: Any])?["city"] as? String,
            "Cairo"
        )
    }

    func testOpenAIResponseHasCompatibilityShape() throws {
        let data = LocalAPIResponse.openAIResponse(
            id: "resp_test", model: "qwen", text: "hello"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["object"] as? String, "response")
        XCTAssertEqual(object["status"] as? String, "completed")
        XCTAssertEqual(object["output_text"] as? String, "hello")
        let output = try XCTUnwrap(object["output"] as? [[String: Any]])
        XCTAssertEqual(output.first?["role"] as? String, "assistant")
    }

    func testOpenAIChatCompletionReportsUsage() throws {
        let data = LocalAPIResponse.openAIChatCompletion(
            id: "chatcmpl-test",
            model: "qwen",
            text: "hi",
            toolCalls: [],
            usage: (12, 34)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let usage = try XCTUnwrap(object["usage"] as? [String: Any])
        XCTAssertEqual(usage["prompt_tokens"] as? Int, 12)
        XCTAssertEqual(usage["completion_tokens"] as? Int, 34)
        XCTAssertEqual(usage["total_tokens"] as? Int, 46)
    }

    func testOpenAIChatCompletionOmitsUsageWhenUnknown() throws {
        let data = LocalAPIResponse.openAIChatCompletion(
            id: "chatcmpl-test",
            model: "qwen",
            text: "hi",
            toolCalls: []
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNil(object["usage"])
    }

    func testAnthropicMessageReportsUsage() throws {
        let data = LocalAPIResponse.anthropicMessage(
            id: "msg_test",
            model: "qwen",
            text: "hi",
            usage: (8, 16)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let usage = try XCTUnwrap(object["usage"] as? [String: Any])
        XCTAssertEqual(usage["input_tokens"] as? Int, 8)
        XCTAssertEqual(usage["output_tokens"] as? Int, 16)
    }

    func testOllamaChatReportsEvalCountsWhenDone() throws {
        let data = LocalAPIResponse.ollamaChat(
            model: "qwen",
            text: "hi",
            done: true,
            usage: (10, 20)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["prompt_eval_count"] as? Int, 10)
        XCTAssertEqual(object["eval_count"] as? Int, 20)
    }

    func testHTTPRequestParsesQueryAndBearer() {
        let request = HTTPRequest(data: Data("""
        POST /v1/chat/completions?trace=1 HTTP/1.1\r
        Authorization: Bearer abc\r
        Content-Type: application/json\r
        Content-Length: 2\r
        \r
        {}
        """.utf8))
        XCTAssertEqual(request?.path, "/v1/chat/completions")
        XCTAssertEqual(request?.headers["authorization"], "Bearer abc")
        XCTAssertEqual(request?.body, Data("{}".utf8))
    }

    func testRequestPresentsKeyChecksHeadersOnly() {
        func request(_ header: String, body: String = "") -> Data {
            Data("POST /v1/chat/completions HTTP/1.1\r\n\(header)\r\n\r\n\(body)".utf8)
        }
        XCTAssertTrue(LocalAPIServer.requestPresentsKey(request("Authorization: Bearer sk-test"), key: "sk-test"))
        XCTAssertTrue(LocalAPIServer.requestPresentsKey(request("X-API-Key: sk-test"), key: "sk-test"))
        XCTAssertFalse(LocalAPIServer.requestPresentsKey(request("Authorization: Bearer wrong"), key: "sk-test"))
        XCTAssertFalse(LocalAPIServer.requestPresentsKey(request("Content-Length: 5"), key: "sk-test"))
        // A key smuggled into the body, or headers that never end, do not count.
        XCTAssertFalse(LocalAPIServer.requestPresentsKey(request("Content-Length: 20", body: "Authorization: Bearer sk-test"), key: "sk-test"))
        XCTAssertFalse(LocalAPIServer.requestPresentsKey(Data("POST / HTTP/1.1\r\nAuthorization: Bearer sk-test".utf8), key: "sk-test"))
    }

    func testEmbeddingsDecodeAcceptsOpenAIAndOllamaShapes() throws {
        XCTAssertEqual(try LocalAPIEmbeddings.decode(Data(#"{"input":"hi"}"#.utf8)).inputs, ["hi"])
        let many = try LocalAPIEmbeddings.decode(Data(#"{"input":["a","b"],"encoding_format":"base64"}"#.utf8))
        XCTAssertEqual(many.inputs, ["a", "b"])
        XCTAssertTrue(many.base64)
        let legacy = try LocalAPIEmbeddings.decode(Data(#"{"prompt":"hi"}"#.utf8))
        XCTAssertTrue(legacy.legacy)
        for bad in [#"{}"#, #"{"input":""}"#, #"{"input":[]}"#, #"{"input":[[1,2]]}"#, "[]"] {
            XCTAssertThrowsError(try LocalAPIEmbeddings.decode(Data(bad.utf8)), bad)
        }
    }

    func testEmbeddingsResponseShapes() throws {
        let vectors: [[Float]] = [[1, 0], [0, 1]]
        let request = LocalAPIEmbeddings.Request(inputs: ["one two", "three"])
        let openAI = try XCTUnwrap(JSONSerialization.jsonObject(with: LocalAPIEmbeddings.response(vectors, for: request, path: "/v1/embeddings")) as? [String: Any])
        XCTAssertEqual(openAI["object"] as? String, "list")
        XCTAssertEqual((openAI["data"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((openAI["usage"] as? [String: Int])?["prompt_tokens"], 3)

        var b64 = request
        b64.base64 = true
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: LocalAPIEmbeddings.response(vectors, for: b64, path: "/v1/embeddings")) as? [String: Any])
        let first = try XCTUnwrap((encoded["data"] as? [[String: Any]])?.first?["embedding"] as? String)
        XCTAssertEqual(Data(base64Encoded: first)?.count, 2 * MemoryLayout<Float>.size)

        let ollama = try XCTUnwrap(JSONSerialization.jsonObject(with: LocalAPIEmbeddings.response(vectors, for: request, path: "/api/embed")) as? [String: Any])
        XCTAssertEqual((ollama["embeddings"] as? [[Double]])?.count, 2)
        var old = request
        old.legacy = true
        let legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: LocalAPIEmbeddings.response(vectors, for: old, path: "/api/embeddings")) as? [String: Any])
        XCTAssertEqual((legacy["embedding"] as? [Double])?.count, 2)
    }

    func testEmbeddingsAreNormalizedAndRankBySimilarity() throws {
        let vectors: [[Float]]
        do {
            vectors = try LocalAPIEmbeddings.embed(["The cat sat on the mat.", "A kitten rests on a rug.", "Quarterly tax filing deadlines."])
        } catch is LocalAPIEmbeddings.Unavailable {
            throw XCTSkip("No NaturalLanguage sentence embedding on this runtime")
        }
        XCTAssertEqual(OnDeviceEmbedder.cosine(vectors[0], vectors[0]), 1, accuracy: 0.001)
        XCTAssertGreaterThan(OnDeviceEmbedder.cosine(vectors[0], vectors[1]), OnDeviceEmbedder.cosine(vectors[0], vectors[2]))
    }
}
