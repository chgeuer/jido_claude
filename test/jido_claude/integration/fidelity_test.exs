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
  end

  describe "usage/token fidelity" do
    test "extracts cache tokens from result usage" do
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
      assert usage_event.payload["cached_input_tokens"] == 17000  # 5000 + 12000
      assert usage_event.payload["cost_usd"] == 0.042
      assert usage_event.payload["duration_ms"] == 3500
      assert usage_event.payload["model"] == "claude-sonnet-4-5-20250929"
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
              %{"type" => "tool_use", "name" => "Read", "input" => %{"file_path" => "/src/main.ex"}, "id" => "toolu_123"}
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

    test "maps tool_result blocks with output and error flag" do
      message = %Message{
        type: :user,
        subtype: nil,
        data: %{
          session_id: "test-session",
          message: %{
            "content" => [
              %{"type" => "tool_result", "content" => "file contents here", "tool_use_id" => "toolu_123", "is_error" => false}
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
    test "maps system init with tools and model" do
      message = %Message{
        type: :system,
        subtype: :init,
        data: %{
          session_id: "sess-abc",
          cwd: "/project",
          model: "claude-opus-4-5",
          tools: ["Bash", "Read", "Edit", "Write"]
        },
        raw: nil
      }

      assert {:ok, [event]} = Mapper.map_message(message)
      assert event.type == :session_started
      assert event.session_id == "sess-abc"
      assert event.payload["model"] == "claude-opus-4-5"
      assert event.payload["tools"] == ["Bash", "Read", "Edit", "Write"]
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

    test "maps result success with cost" do
      message = %Message{
        type: :result,
        subtype: :success,
        data: %{
          session_id: "test",
          total_cost_usd: 0.05,
          duration_ms: 5000,
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

      assert usage_event != nil
      assert usage_event.payload["cost_usd"] == 0.05
      assert usage_event.payload["total_tokens"] == 300
    end
  end

  describe "all events carry provider metadata" do
    test "all events have provider :claude and timestamps" do
      messages = [
        %Message{type: :system, subtype: :init, data: %{session_id: "s1", cwd: "/", model: "m", tools: []}, raw: nil},
        %Message{type: :assistant, subtype: nil, data: %{session_id: "s1", message: %{content: [%{type: :text, text: "hi"}]}}, raw: nil},
        %Message{type: :result, subtype: :success, data: %{session_id: "s1", total_cost_usd: nil, duration_ms: nil, num_turns: 1, is_error: false, result: "ok", usage: %{}}, raw: nil}
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
