defmodule Jido.Claude.Mapper do
  @moduledoc """
  Maps Claude SDK messages to normalized `Jido.Harness.Event` structs.
  """

  alias ClaudeAgentSDK.Message
  alias Jido.Harness.Event
  alias Jido.Harness.Event.Usage, as: UsageEvent

  @doc """
  Maps a Claude SDK message into one or more normalized harness events.
  """
  @spec map_message(term()) :: {:ok, [Event.t()]} | {:error, term()}
  def map_message(%Message{type: :system, subtype: :init, data: data} = message) when is_map(data) do
    payload = %{
      "cwd" => map_get(data, :cwd),
      "model" => map_get(data, :model),
      "tools" => map_get(data, :tools, [])
    }

    {:ok, [build_event(:session_started, map_get(data, :session_id), payload, message)]}
  end

  def map_message(%Message{type: :assistant, data: data} = message) when is_map(data) do
    session_id = map_get(data, :session_id)
    blocks = Message.content_blocks(message)

    events =
      if blocks == [] do
        maybe_assistant_text_event(data, session_id, message)
      else
        Enum.flat_map(blocks, &map_assistant_block(&1, session_id, message))
      end

    {:ok, events}
  end

  # User messages may contain tool_result blocks (tool execution outputs)
  def map_message(%Message{type: :user, data: data} = message) when is_map(data) do
    session_id = map_get(data, :session_id)
    blocks = Message.content_blocks(message)

    tool_results =
      blocks
      |> Enum.filter(&(is_map(&1) and &1[:type] == :tool_result))
      |> Enum.flat_map(&map_assistant_block(&1, session_id, message))

    {:ok, tool_results}
  end

  def map_message(%Message{type: :result, subtype: :success, data: data} = message) when is_map(data) do
    payload = %{
      "result" => map_get(data, :result),
      "num_turns" => map_get(data, :num_turns),
      "duration_ms" => map_get(data, :duration_ms),
      "is_error" => map_get(data, :is_error, false)
    }

    usage_event = maybe_result_usage(data, message)

    {:ok, List.wrap(usage_event) ++ [build_event(:session_completed, map_get(data, :session_id), payload, message)]}
  end

  def map_message(%Message{type: :result, data: data} = message) when is_map(data) do
    payload = %{
      "error" => map_get(data, :error) || map_get(data, :result),
      "subtype" => to_string(message.subtype || "error")
    }

    {:ok, [build_event(:session_failed, map_get(data, :session_id), payload, message)]}
  end

  def map_message(%Message{type: :stream_event, data: data} = message) when is_map(data) do
    event = map_get(data, :event, %{})
    session_id = map_get(data, :session_id)
    event_type = map_get(event, :type) || map_get(event, "type")

    events = parse_stream_event(event_type, event, session_id, message)
    {:ok, events}
  end

  def map_message(%Message{} = message) do
    {:ok, [build_event(:provider_event, nil, %{"type" => to_string(message.type)}, message)]}
  end

  def map_message(other) do
    {:error, {:unsupported_message, other}}
  end

  defp map_assistant_block(%{type: :text, text: text}, session_id, message) when is_binary(text) do
    [build_event(:output_text_delta, session_id, %{"text" => text}, message)]
  end

  defp map_assistant_block(%{type: :thinking, thinking: thinking}, session_id, message) when is_binary(thinking) do
    [build_event(:thinking_delta, session_id, %{"text" => thinking}, message)]
  end

  defp map_assistant_block(%{type: :tool_use, name: name, input: input, id: id}, session_id, message) do
    [build_event(:tool_call, session_id, %{"name" => name, "input" => input || %{}, "call_id" => id}, message)]
  end

  defp map_assistant_block(
         %{type: :tool_result, content: content, tool_use_id: tool_use_id, is_error: is_error},
         session_id,
         message
       ) do
    [
      build_event(
        :tool_result,
        session_id,
        %{"output" => content, "call_id" => tool_use_id, "is_error" => is_error},
        message
      )
    ]
  end

  defp map_assistant_block(_block, _session_id, _message), do: []

  defp maybe_assistant_text_event(data, session_id, message) do
    text =
      data
      |> map_get(:message, %{})
      |> map_get(:content)
      |> case do
        content when is_binary(content) -> content
        _ -> nil
      end

    if is_binary(text) and text != "" do
      [build_event(:output_text_delta, session_id, %{"text" => text}, message)]
    else
      []
    end
  end

  defp build_event(type, session_id, payload, raw) do
    Event.new!(%{
      type: type,
      provider: :claude,
      session_id: session_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      payload: stringify_keys(payload),
      raw: raw
    })
  end

  defp stringify_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), stringify_keys(v)} end)
    |> Map.new()
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp map_get(map, key, default \\ nil) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Extract usage from nested message_start event structure
  # Handles both atom and string keys: event.message.usage or event["message"]["usage"]
  defp extract_nested_usage(event) do
    msg = map_get(event, :message, %{}) || %{}
    usage = map_get(msg, :usage, %{}) || %{}

    %{}
    |> maybe_put(:input_tokens, map_get(usage, :input_tokens))
    |> maybe_put(:cache_creation_input_tokens, map_get(usage, :cache_creation_input_tokens))
    |> maybe_put(:cache_read_input_tokens, map_get(usage, :cache_read_input_tokens))
  end

  defp get_in_map(map, []), do: map

  defp get_in_map(map, [key | rest]) when is_map(map) do
    value = map_get(map, key)
    if value, do: get_in_map(value, rest), else: nil
  end

  defp get_in_map(_, _), do: nil

  # ── Stream event sub-dispatchers ──

  defp parse_stream_event(type, event, session_id, message)
       when type in ["message_start", :message_start] do
    # Extract per-message usage snapshot (input + cache tokens)
    usage = extract_nested_usage(event)

    if map_size(usage) > 0 do
      model = get_in_map(event, [:message, :model]) || get_in_map(event, ["message", "model"])

      payload =
        %{"source" => "message_start"}
        |> maybe_put("model", model)
        |> maybe_put("input_tokens", usage[:input_tokens])
        |> maybe_put("cache_creation_input_tokens", usage[:cache_creation_input_tokens])
        |> maybe_put("cache_read_input_tokens", usage[:cache_read_input_tokens])

      [build_event(:provider_event, session_id, payload, message)]
    else
      []
    end
  end

  defp parse_stream_event(type, event, session_id, message)
       when type in ["message_delta", :message_delta] do
    # Extract output token count and stop reason
    usage = map_get(event, :usage, %{}) || %{}
    delta = map_get(event, :delta, %{}) || %{}
    output_tokens = map_get(usage, :output_tokens)
    stop_reason = map_get(delta, :stop_reason)

    if output_tokens do
      payload =
        %{"source" => "message_delta", "output_tokens" => output_tokens}
        |> maybe_put("stop_reason", stop_reason)

      [build_event(:provider_event, session_id, payload, message)]
    else
      []
    end
  end

  defp parse_stream_event(type, _event, session_id, message)
       when type in ["message_stop", :message_stop] do
    # Turn boundary
    [build_event(:turn_end, session_id, %{}, message)]
  end

  defp parse_stream_event(_type, event, session_id, message) do
    # Default: try to extract text delta
    text =
      event
      |> map_get(:delta, %{})
      |> map_get(:text)

    if is_binary(text) and text != "" do
      [build_event(:output_text_delta, session_id, %{"text" => text}, message)]
    else
      []
    end
  end

  # Build a canonical :usage event from result data using UsageEvent.build/3
  defp maybe_result_usage(data, message) do
    cost = map_get(data, :total_cost_usd)
    duration = map_get(data, :duration_ms)
    session_id = map_get(data, :session_id) || ""
    usage = map_get(data, :usage, %{}) || %{}
    model = map_get(data, :model)

    input_tokens = map_get(usage, :input_tokens, 0) || 0
    output_tokens = map_get(usage, :output_tokens, 0) || 0
    cached_input_tokens =
      (map_get(usage, :cache_read_input_tokens, 0) || 0) +
        (map_get(usage, :cache_creation_input_tokens, 0) || 0)

    if cost || duration || input_tokens > 0 || output_tokens > 0 do
      UsageEvent.build(:claude, session_id,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        cached_input_tokens: cached_input_tokens,
        cost_usd: cost,
        duration_ms: duration,
        model: if(model, do: to_string(model)),
        raw: message
      )
    else
      nil
    end
  end
end
