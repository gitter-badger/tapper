defmodule TraceIdTest do
  use ExUnit.Case
  doctest Tapper.TraceId

  test "can generate id" do
    {id, uniq} = Tapper.TraceId.generate()
    assert is_integer(id)
    assert is_integer(uniq)

    assert {id, uniq} != Tapper.TraceId.generate()
  end

  test "format" do
    assert Tapper.TraceId.format({100,200}) == "#Tapper.TraceId<64.200>"
  end

  test "parse" do
      assert :error == Tapper.TraceId.parse("")
      assert :error == Tapper.TraceId.parse("xxx")
      assert :error == Tapper.TraceId.parse("123x")
      assert :error == Tapper.TraceId.parse("x123")
      assert {:ok, {291, u}} = Tapper.TraceId.parse("123")
      assert is_integer(u)
  end
end

defmodule SpanIdTest do
  use ExUnit.Case
  doctest Tapper.SpanId

  test "can generate id" do
    span_id = Tapper.SpanId.generate()
    assert is_integer(span_id)

    assert span_id != Tapper.SpanId.generate()
  end

  test "format" do
    assert Tapper.SpanId.format(1024) == "#Tapper.SpanId<400>"
  end

  test "parse" do
      assert :error == Tapper.SpanId.parse("")
      assert :error == Tapper.SpanId.parse("xxx")
      assert :error == Tapper.SpanId.parse("123x")
      assert :error == Tapper.SpanId.parse("x123")
      assert {:ok, 291} = Tapper.SpanId.parse("123")
  end
end

defmodule TapperIdTest do
  use ExUnit.Case

  test "push span when empty" do
    id = %Tapper.Id{
      trace_id: Tapper.TraceId.generate(),
      span_id: Tapper.SpanId.generate(),
      parent_ids: []
    }

    span_id = Tapper.SpanId.generate()

    updated_id = Tapper.Id.push(id, span_id)

    assert updated_id.parent_ids == [id.span_id]
    assert updated_id.span_id == span_id
  end

  test "push span when has parents" do
    parent_span_id = Tapper.SpanId.generate()

    id = %Tapper.Id{
      trace_id: Tapper.TraceId.generate(),
      span_id: Tapper.SpanId.generate(),
      parent_ids: [parent_span_id]
    }

    span_id = Tapper.SpanId.generate()

    updated_id = Tapper.Id.push(id, span_id)

    assert updated_id.parent_ids == [id.span_id, parent_span_id]
    assert updated_id.span_id == span_id
  end

  test "pop span, one parent" do
    parent_span_id = Tapper.SpanId.generate()

    id = %Tapper.Id{
      trace_id: Tapper.TraceId.generate(),
      span_id: Tapper.SpanId.generate(),
      parent_ids: [parent_span_id]
    }

    updated_id = Tapper.Id.pop(id)

    assert updated_id.span_id == parent_span_id
    assert updated_id.parent_ids == []
  end

  test "pop span, more than one parent" do
    parent1_span_id = Tapper.SpanId.generate()
    parent2_span_id = Tapper.SpanId.generate()

    id = %Tapper.Id{
      trace_id: Tapper.TraceId.generate(),
      span_id: Tapper.SpanId.generate(),
      parent_ids: [parent1_span_id, parent2_span_id]
    }

    updated_id = Tapper.Id.pop(id)

    assert updated_id.span_id == parent1_span_id
    assert updated_id.parent_ids == [parent2_span_id]
  end

  test "pop span, no parents is no-op" do
    id = %Tapper.Id{
      trace_id: Tapper.TraceId.generate(),
      span_id: Tapper.SpanId.generate(),
      parent_ids: []
    }

    assert Tapper.Id.pop(id) == id
  end

  test "Inspect protocol" do
    id = %Tapper.Id{
      trace_id: Tapper.TraceId.generate(),
      span_id: Tapper.SpanId.generate(),
      parent_ids: [],
      sampled: true
    }

    regex = ~r/#Tapper.Id<#Tapper.TraceId<(.+)\.(.+)>:#Tapper.SpanId<(.+)>,(.+)>/
    assert Regex.match?(regex,inspect(id))

    [_, trace_id, uniq, span_id, sampled] = Regex.run(regex, inspect(id))

    {trace_id, ""} = Integer.parse(trace_id, 16)
    {uniq, ""} = Integer.parse(uniq, 10)
    {span_id, ""} = Integer.parse(span_id, 16)

    assert trace_id == elem(id.trace_id,0)
    assert uniq == elem(id.trace_id,1)
    assert span_id == id.span_id
    assert sampled == "SAMPLED"
  end

  test "String.Chars protocol" do
    id = %Tapper.Id{
      trace_id: Tapper.TraceId.generate(),
      span_id: Tapper.SpanId.generate(),
      parent_ids: [],
      sampled: true
    }

    regex = ~r/#Tapper.Id<#Tapper.TraceId<(.+)\.(.+)>:#Tapper.SpanId<(.+)>,(.+)>/

    chars = to_string(id)

    assert Regex.match?(regex, chars)

    [_, trace_id, uniq, span_id, sampled] = Regex.run(regex, chars)

    {trace_id, ""} = Integer.parse(trace_id, 16)
    {uniq, ""} = Integer.parse(uniq, 10)
    {span_id, ""} = Integer.parse(span_id, 16)

    assert trace_id == elem(id.trace_id,0)
    assert uniq == elem(id.trace_id,1)
    assert span_id == id.span_id
    assert sampled == "SAMPLED"
  end
end