defmodule Jido.Claude.Mapper.FidelityTest do
  @moduledoc """
  Tests full event fidelity of the Claude mapper against the gold standard
  set by jido_ghcopilot: thinking, usage/tokens, cache metrics, tool calls, cost.
  """
  use ExUnit.Case, async: true

  alias ClaudeAgentSDK.Message
  alias Jido.Claude.Mapper

  describe "thinking fidelity" do
    test "maps thinking blocks from assistant messages" do
      message = %Message{
        type: :assistant,
        subtype: nil,
        data: %{
          session_id: "test-session",
          message: %{
            "content" => [
              %{"type" => "thinking", "thinking" => "Let me analyze this step by step..."},
              %{"type" => "text", "text" => "The answer is 4."}
            ]
          }
        },
        raw: nil
      }

      assert {:ok, events} = Mapper.map_message(message)
      thinking_events = Enum.filter(events, &(&1.type == :thinking_delta))
      text_events = Enum.filter(events, &(&1.type == :output_text_delta))

      assert length(thinking_events) == 1
      assert hd(thinking_events).payload["text"] == "Let me analyze this step by step..."
      assert length(text_events) == 1
      assert hd(text_events).payload["text"] == "The answer is 4."
    end

    test "maps multiple thinking blocks interleaved with text" do
      message = %Message{
        type: :assistant,
        subtype: nil,
        data: %{
          session_id: "test-session",
          message: %{
            "content" => [
              %{"type" => "thinking", "thinking" => "First, consider..."},
              %{"type" => "text", "text" => "Step 1."},
              %{"type" => "thinking", "thinking" => "Next, analyze..."},
              %{"type" => "text", "text" => "Step 2."}
            ]
          }
        },
        raw: nil
      }

      assert {:ok, events} = Mapper.map_message(message)
      types = Enum.map(events, & &1.type)
      assert types == [:thinking_delta, :output_text_delta, :thinking_delta, :output_text_delta]
    end

    test "maps thinking block with signature" do
      message = %Message{
        type: :assistant,
        subtype: nil,
        data: %{
          session_id: "test-session",
          message: %{
            "content" => [
              %{"type" => "thinking", "thinking" => "Deep analysis...", "signature" => "sig_abc123"}
            ]
          }
        },
        raw: nil
      }

      assert {:ok, [event]} = Mapper.map_message(message)
      assert event.type == :thinking_delta
      assert event.payload["text"] == "Deep analysis..."
      assert event.payload["signature"] == "sig_abc123"
    end

    test "maps redacted_thinking blocks" do
      message = %Message{
        type: :assistant,
        subtype: nil,
        data: %{
          session_id: "test-session",
          message: %{
            "content" => [
              %{"type" => "redacted_thinking", "data" => "encrypted_blob_xyz"},
              %{"type" => "text", "text" => "Here is my answer."}
            ]
          }
        },
        raw: nil
      }

      assert {:ok, events} = Mapper.map_message(message)
      thinking_events = Enum.filter(events, &(&1.type == :thinking_delta))
      assert length(thinking_events) == 1
      assert hd(thinking_events).payload["redacted"] == true
      assert hd(thinking_events).payload["data"] == "encrypted_blob_xyz"
    end
  end

  describe "usage/token fidelity" do
    test "separates cache_read and cache_creation tokens" do
      message = %Message{
        type: :result,
        subtype: :success,
        data: %{
          session_id: "test-session",
          total_cost_usd: 0.042,
          duration_ms: 3500,
          model: "claude-sonnet-4-5-20250929",
          num_turns: 1,
          is_error: false,
          result: "done",
          usage: %{
            input_tokens: 10,
            output_tokens: 150,
            cache_creation_input_tokens: 5000,
            cache_read_input_tokens: 12000
          }
        },
        raw: nil
      }

      assert {:ok, events} = Mapper.map_message(message)
      usage_event = Enum.find(events, &(&1.type == :usage))

      assert usage_event != nil
      assert usage_event.payload["input_tokens"] == 10
      assert usage_event.payload["output_tokens"] == 150
      # Combined value for backward compat
      assert usage_event.payload["cached_input_tokens"] == 17000
      # Separate values for copilot_lv's cache_read_tokens / cache_write_tokens
      assert usage_event.payload["cache_read_input_tokens"] == 12000
      assert usage_event.payload["cache_creation_input_tokens"] == 5000
      assert usage_event.payload["cost_usd"] == 0.042
      assert usage_event.payload["duration_ms"] == 3500
      assert usage_event.payload["model"] == "claude-sonnet-4-5-20250929"
    end

    test "includes duration_api_ms and stop_reason when present" do
      message = %Message{
        type: :result,
        subtype: :success,
        data: %{
          session_id: "test-session",
          total_cost_usd: 0.01,
          duration_ms: 2000,
          duration_api_ms: 1500,
          stop_reason: "end_turn",
          model: "claude-sonnet-4-5-20250929",
          num_turns: 1,
          is_error: false,
          result: "done",
          usage: %{input_tokens: 100, output_tokens: 50}
        },
        raw: nil
      }

      assert {:ok, events} = Mapper.map_message(message)
      usage_event = Enum.find(events, &(&1.type == :usage))

      assert usage_event.payload["duration_api_ms"] == 1500
      assert usage_event.payload["stop_reason"] == "end_turn"
    end

    test "omits zero cache tokens from separate fields" do
      message = %Message{
        type: :result,
        subtype: :success,
        data: %{
          session_id: "test",
          total_cost_usd: 0.01,
          duration_ms: 100,
          num_turns: 1,
          is_error: false,
          result: "ok",
          usage: %{input_tokens: 50, output_tokens: 20}
        },
        raw: nil
      }

      assert {:ok, events} = Mapper.map_message(message)
      usage_event = Enum.find(events, &(&1.type == :usage))

      assert usage_event.payload["cached_input_tokens"] == 0
      refute Map.has_key?(usage_event.payload, "cache_read_input_tokens")
      refute Map.has_key?(usage_event.payload, "cache_creation_input_tokens")
    end

    test "extracts per-message usage from message_start stream event" do
      message = %Message{
        type: :stream_event,
        subtype: nil,
        data: %{
          session_id: "test-session",
          event: %{
            type: :message_start,
            message: %{
              model: "claude-sonnet-4-5-20250929",
              usage: %{
                input_tokens: 2,
                cache_creation_input_tokens: 800,
                cache_read_input_tokens: 15000
              }
            }
          }
        },
        raw: nil
      }

      assert {:ok, events} = Mapper.map_message(message)
      assert length(events) == 1
      [event] = events
      assert event.type == :provider_event
      assert event.payload["source"] == "message_start"
      assert event.payload["input_tokens"] == 2
      assert event.payload["cache_creation_input_tokens"] == 800
      assert event.payload["cache_read_input_tokens"] == 15000
      assert event.payload["model"] == "claude-sonnet-4-5-20250929"
    end

    test "extracts output tokens from message_delta stream event" do
      message = %Message{
        type: :stream_event,
        subtype: nil,
        data: %{
          session_id: "test-session",
          event: %{
            type: :message_delta,
            usage: %{output_tokens: 250},
            delta: %{stop_reason: "end_turn"}
          }
        },
        raw: nil
      }

      assert {:ok, events} = Mapper.map_message(message)
      assert length(events) == 1
      [event] = events
      assert event.type == :provider_event
      assert event.payload["source"] == "message_delta"
      assert event.payload["output_tokens"] == 250
      assert event.payload["stop_reason"] == "end_turn"
    end
  end

  describe "tool call fidelity" do
    test "maps tool_use blocks with full arguments" do
      message = %Message{
        type: :assistant,
        subtype: nil,
        data: %{
          session_id: "test-session",
          message: %{
            "content" => [
              %{
                "type" => "tool_use",
                "name" => "Read",
                "input" => %{"file_path" => "/src/main.ex"},
                "id" => "toolu_123"
              }
            ]
          }
        },
        raw: nil
      }

      assert {:ok, [event]} = Mapper.map_message(message)
      assert event.type == :tool_call
      assert event.payload["name"] == "Read"
      assert event.payload["input"] == %{"file_path" => "/src/main.ex"}
      assert event.payload["call_id"] == "toolu_123"
    end

    test "maps server_tool_use blocks with server_tool flag" do
      message = %Message{
        type: :assistant,
        subtype: nil,
        data: %{
          session_id: "test-session",
          message: %{
            "content" => [
              %{
                "type" => "server_tool_use",
                "name" => "web_search",
                "input" => %{"query" => "elixir docs"},
                "id" => "toolu_srv_1"
              }
            ]
          }
        },
        raw: nil
      }

      assert {:ok, [event]} = Mapper.map_message(message)
      assert event.type == :tool_call
      assert event.payload["name"] == "web_search"
      assert event.payload["server_tool"] == true
      assert event.payload["call_id"] == "toolu_srv_1"
      assert event.payload["input"] == %{"query" => "elixir docs"}
    end

    test "maps tool_result blocks with output and error flag" do
      message = %Message{
        type: :user,
        subtype: nil,
        data: %{
          session_id: "test-session",
          message: %{
            "content" => [
              %{
                "type" => "tool_result",
                "content" => "file contents here",
                "tool_use_id" => "toolu_123",
                "is_error" => false
              }
            ]
          }
        },
        raw: nil
      }

      assert {:ok, [event]} = Mapper.map_message(message)
      assert event.type == :tool_result
      assert event.payload["output"] == "file contents here"
      assert event.payload["call_id"] == "toolu_123"
      assert event.payload["is_error"] == false
    end
  end

  describe "session lifecycle fidelity" do
    test "maps system init with tools, model, and extended fields" do
      message = %Message{
        type: :system,
        subtype: :init,
        data: %{
          session_id: "sess-abc",
          cwd: "/project",
          model: "claude-opus-4-5",
          tools: ["Bash", "Read", "Edit", "Write"],
          api_key_source: "env:ANTHROPIC_API_KEY",
          permission_mode: "accept_edits",
          mcp_servers: ["math-server"]
        },
        raw: nil
      }

      assert {:ok, [event]} = Mapper.map_message(message)
      assert event.type == :session_started
      assert event.session_id == "sess-abc"
      assert event.payload["model"] == "claude-opus-4-5"
      assert event.payload["tools"] == ["Bash", "Read", "Edit", "Write"]
      assert event.payload["api_key_source"] == "env:ANTHROPIC_API_KEY"
      assert event.payload["permission_mode"] == "accept_edits"
      assert event.payload["mcp_servers"] == ["math-server"]
    end

    test "system init omits nil extended fields" do
      message = %Message{
        type: :system,
        subtype: :init,
        data: %{
          session_id: "sess-abc",
          cwd: "/project",
          model: "claude-sonnet",
          tools: []
        },
        raw: nil
      }

      assert {:ok, [event]} = Mapper.map_message(message)
      refute Map.has_key?(event.payload, "api_key_source")
      refute Map.has_key?(event.payload, "permission_mode")
      refute Map.has_key?(event.payload, "mcp_servers")
    end

    test "maps message_stop to turn_end" do
      message = %Message{
        type: :stream_event,
        subtype: nil,
        data: %{session_id: "test", event: %{type: :message_stop}},
        raw: nil
      }

      assert {:ok, [event]} = Mapper.map_message(message)
      assert event.type == :turn_end
    end

    test "maps result success with cost and enriched payload" do
      message = %Message{
        type: :result,
        subtype: :success,
        data: %{
          session_id: "test",
          total_cost_usd: 0.05,
          duration_ms: 5000,
          duration_api_ms: 4200,
          stop_reason: "end_turn",
          num_turns: 3,
          is_error: false,
          result: "complete",
          usage: %{input_tokens: 100, output_tokens: 200}
        },
        raw: nil
      }

      assert {:ok, events} = Mapper.map_message(message)
      session_event = Enum.find(events, &(&1.type == :session_completed))
      usage_event = Enum.find(events, &(&1.type == :usage))

      assert session_event != nil
      assert session_event.payload["num_turns"] == 3
      assert session_event.payload["duration_api_ms"] == 4200
      assert session_event.payload["stop_reason"] == "end_turn"

      assert usage_event != nil
      assert usage_event.payload["cost_usd"] == 0.05
      assert usage_event.payload["total_tokens"] == 300
    end
  end

  describe "error stream events" do
    test "maps error stream events to provider_event" do
      message = %Message{
        type: :stream_event,
        subtype: nil,
        data: %{
          session_id: "test",
          event: %{
            type: :error,
            error: %{type: "overloaded_error", message: "API is overloaded"}
          }
        },
        raw: nil
      }

      assert {:ok, [event]} = Mapper.map_message(message)
      assert event.type == :provider_event
      assert event.payload["source"] == "stream_error"
      assert event.payload["error_type"] == "overloaded_error"
      assert event.payload["message"] == "API is overloaded"
    end
  end

  describe "all events carry provider metadata" do
    test "all events have provider :claude and timestamps" do
      messages = [
        %Message{type: :system, subtype: :init, data: %{session_id: "s1", cwd: "/", model: "m", tools: []}, raw: nil},
        %Message{
          type: :assistant,
          subtype: nil,
          data: %{session_id: "s1", message: %{content: [%{type: :text, text: "hi"}]}},
          raw: nil
        },
        %Message{
          type: :result,
          subtype: :success,
          data: %{
            session_id: "s1",
            total_cost_usd: nil,
            duration_ms: nil,
            num_turns: 1,
            is_error: false,
            result: "ok",
            usage: %{}
          },
          raw: nil
        }
      ]

      all_events =
        Enum.flat_map(messages, fn msg ->
          {:ok, events} = Mapper.map_message(msg)
          events
        end)

      for event <- all_events do
        assert event.provider == :claude
        assert is_binary(event.timestamp)
      end
    end
  end
end
