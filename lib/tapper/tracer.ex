defmodule Tapper.Tracer do
  @moduledoc """
  Low-level client API, interfaces between a Tapper client and a `Tapper.Tracer.Server`.

  Most functions in `Tapper` delegate to this module; `Tapper` also provides helper functions
  for creation of common annotations.

  ## See also

  * `Tapper` - high-level client API.

  """

  @behaviour Tapper.Tracer.Api

  use Bitwise

  require Logger

  import Tapper.Tracer.Server, only: [via_tuple: 1]

  alias Tapper.Timestamp
  alias Tapper.Tracer.Trace
  alias Tapper.Tracer.Api

  @doc """
  start a new root trace, e.g. on originating a request, e.g.:

  ```
  id = Tapper.start(name: "request resource", type: :client, remote: remote_endpoint)
  ```

  ### Options

  * `name` - the name of the span.
  * `sample` - boolean, whether to sample this trace or not.
  * `debug` - boolean, the debugging flag, if `true` this turns sampling for this trace on, regardless of
    the value of `sample`.
  * `annotations` (list, atom or tuple) - a single annotation or list of annotations, specified by `Tapper.tag/3` etc.
  * `type` - the type of the span, i.e.. `:client`, `:server`; defaults to `:client`.
  * `remote` - the remote Endpoint: automatically creates a "sa" (client) or "ca" (server) binary annotation on this span.
  * `ttl` - how long this span should live before automatically finishing it
    (useful for long-running async operations); milliseconds.
  * `reporter` (module atom or function) - override the configured reporter for this trace; useful for testing.

  #### Notes

  * If neither `sample` nor `debug` are set, all operations on this trace become a no-op.
  * `type` determines the type of an automatically created `sr` (`:server`) or `cs` (`:client`) annotation, see also `Tapper.client_send/0` and `Tapper.server_receive/0`.
  """
  def start(opts \\ []) when is_list(opts) do
    trace_id = Tapper.TraceId.generate()
    span_id = elem(trace_id, 0) &&& 0xFFFFFFFFFFFFFFFF # lower 64 bits
    timestamp = Timestamp.instant()

    # check type, and default to :client
    opts = default_type_opts(opts, :client) # if we're starting a trace, we're a client
    :ok = check_endpoint_opt(opts[:remote]) # if we're sending a remote endpoint, check it's an %Tapper.Endpoint{}

    sample = Keyword.get(opts, :sample, false) === true
    debug = Keyword.get(opts, :debug, false) === true

    id = Tapper.Id.init(trace_id, span_id, :root, sample, debug)

    # don't even start tracer if sampled is false
    if id.sampled do
      trace_init = {trace_id, span_id, :root, sample, debug}

      {:ok, _pid} = Tapper.Tracer.Supervisor.start_tracer(trace_init, timestamp, opts)
    end

    Logger.metadata(tapper_id: id)

    id
  end

  @doc """
  join an existing trace, e.g. server recieving an annotated request, returning a `Tapper.Id` for subsequent operations:
  ```
  id = Tapper.join(trace_id, span_id, parent_id, sample, debug, name: "receive request")
  ```

  NB Probably called by an integration (e.g. [`tapper_plug`](https://github.com/Financial-Times/tapper_plug))
  with name, annotations etc. added in the service code, so the name is optional here, see `Tapper.name/1`.

  ## Arguments

  * `trace_id` - the incoming trace id.
  * `span_id` - the incoming span id.
  * `parent_span_id` - the incoming parent span id, or `:root` if none.
  * `sample` is the incoming sampling status; `true` implies trace has been sampled, and
  down-stream spans should be sampled also, `false` that it will not be sampled,
  and down-stream spans should not be sampled either.
  * `debug` is the debugging flag, if `true` this turns sampling for this trace on, regardless of
  the value of `sampled`.


  ## Options
  * `name` (String) name of span, see also `Tapper.name/1`.
  * `annotations` (list, atom or tuple) - a single annotation or list of annotations, specified by `Tapper.tag/3` etc.
  * `type` - the type of the span, i.e.. `:client`, `:server`; defaults to `:server`; determines which of `sr` (`:server`) or `cs`
    (`:client`) annotations is added. Defaults to `:server`.
  * `endpoint` - sets the endpoint for the initial `cr` or `sr` annotation, defaults to one derived from Tapper configuration (see `Tapper.Application.start/2`).
  * `remote` (`Tapper.Endpoint`) - the remote endpoint: automatically creates a "sa" (`:client`) or "ca" (`:server`) binary annotation on this span, see also `Tapper.server_address/1`.
  * `ttl` - how long this span should live between operations, before automatically finishing it
    (useful for long-running async operations); milliseconds.
  * `reporter` (module atom or function) - override the configured reporter for this trace; useful for testing.

  #### Notes

  * If neither `sample` nor `debug` are set, all operations on this trace become a no-op.
  * `type` determines the type of an automatically created `sr` (`:server`) or `cs` (`:client`) annotation, see also `Tapper.client_send/0` and `Tapper.server_receive/0`.
  """
  def join(trace_id, span_id, parent_id, sample, debug, opts \\ []), do: join({trace_id, span_id, parent_id, sample, debug}, opts)
  def join(trace_init = {trace_id, span_id, parent_id, sample, debug}, opts \\ []) when is_list(opts) do

    timestamp = Timestamp.instant()

    # check and default type to :server
    opts = default_type_opts(opts, :server)
    :ok = check_endpoint_opt(opts[:remote])

    id = Tapper.Id.init(trace_id, span_id, parent_id, sample, debug)

    if id.sampled do
      {:ok, _pid} = Tapper.Tracer.Supervisor.start_tracer(trace_init, timestamp, opts)
    end

    Logger.metadata(tapper_id: id)

    id
  end

  defp default_type_opts(opts, default) when default in [:client,:server] do
    {_, opts} = Keyword.get_and_update(opts, :type, fn(value) ->
      case value do
        nil -> {value, default}
        :client -> {value, :client}
        :server -> {value, :server}
      end
    end)
    opts
  end

  defp check_endpoint_opt(endpoint) do
      case endpoint do
        nil -> :ok
        %Tapper.Endpoint{} -> :ok
        _ -> {:error, "invalid endpoint: expected struct %Tapper.Endpoint{}"}
      end
  end

  @doc """
  Finishes the trace.

  For `async` processes (where spans persist in another process), just call
  `finish/2` when done with the main span, passing the `async` option, and finish
  child spans as normal using `finish_span/2`. When the trace times out, spans will
  be sent to the server, marking any unfinished spans with a `timeout` annotation.

  ```
  id = Tapper.finish(id, async: true, annotations: [Tapper.http_status_code(401)])
  ```

  ## See also
  * `Tapper.Tracer.Timeout` - the time-out logic.

  ## Options
  * `async` (boolean) - mark the trace as asynchronous, allowing child spans to finish within the TTL.
  * `annotations` (list) - list of annotations to attach to main span.

  ## See also
  * `Tapper.Tracer.Timeout` - timeout behaviour.
  * `Tapper.async/0` annotation.
"""
  def finish(id, opts \\ [])
  def finish(%Tapper.Id{sampled: false}, _opts), do: :ok
  def finish(id = %Tapper.Id{}, opts) when is_list(opts) do
    end_timestamp = Timestamp.instant()

    GenServer.cast(via_tuple(id), {:finish, end_timestamp, opts})
  end


  @doc """
  Starts a child span, returning an updated `Tapper.Id`.

  ## Arguments
  * `id` - Tapper id.
  * `options` - see below.

  ## Options
  * `name` (string) - name of span.
  * `local` (string) - provide a local span context name (via a `lc` binary annotation).
  * `annotations` (list, atom or tuple) - a list of annotations to attach to the span.

  ```
  id = Tapper.start_span(id, name: "foo", local: "do foo", annotations: [Tapper.sql_query("select * from foo")])
  ```
  """
  def start_span(id, opts \\ [])

  def start_span(:ignore, _opts), do: :ignore

  def start_span(id = %Tapper.Id{sampled: false}, _opts), do: id

  def start_span(id = %Tapper.Id{span_id: span_id}, opts) when is_list(opts) do
    timestamp = Timestamp.instant()

    child_span_id = Tapper.SpanId.generate()

    updated_id = Tapper.Id.push(id, child_span_id)

    name = Keyword.get(opts, :name, "unknown")

    span = %Trace.SpanInfo {
      name: name,
      id: child_span_id,
      start_timestamp: timestamp,
      parent_id: span_id,
      annotations: [],
      binary_annotations: []
    }

    GenServer.cast(via_tuple(id), {:start_span, span, opts})

    updated_id
  end

  @doc """
  Finish a nested span, returning an updated `Tapper.Id`.

  ## Arguments
  * `id` - Tapper id.

  ## Options
  * `annotations` (list, atom, typle) - a list of annotations to attach the the span.

  ```
  id = finish_span(id, annotations: Tapper.http_status_code(202))
  ```
  """
  def finish_span(id, opts \\ [])

  def finish_span(:ignore, _), do: :ignore

  def finish_span(id = %Tapper.Id{sampled: false}, _), do: id

  def finish_span(id = %Tapper.Id{}, opts) do

    timestamp = Timestamp.instant()

    updated_id = Tapper.Id.pop(id)

    GenServer.cast(via_tuple(id), {:finish_span, id.span_id, timestamp, opts})

    updated_id
  end

  @doc "build an name-span action, suitable for passing to `annotations` option or `update_span/3`; see also `Tapper.name/1`."
  @spec name_delta(name :: String.t | atom) :: Api.name_delta
  def name_delta(name) when is_binary(name) or is_atom(name) do
    {:name, name}
  end

  @doc "build an async action, suitable for passing to `annotations` option or `update_span/3`; see also `Tapper.async/0`."
  @spec async_delta() :: Api.async_delta
  def async_delta do
    {:async, true}
  end

  @doc "build a span annotation, suitable for passing to `annotations` option or `update_span/3`; see also convenience functions in `Tapper`."
  @spec annotation_delta(value :: Api.annotation_value(), endpoint :: Api.maybe_endpoint) :: Api.annotation_delta
  def annotation_delta(value, endpoint \\ nil) when is_atom(value) or is_binary(value) do
    value = map_annotation_type(value)
    endpoint = check_endpoint(endpoint)
    {:annotate, {value, endpoint}}
  end

  @binary_annotation_types [:string, :bool, :i16, :i32, :i64, :double, :bytes]

  @doc "build a span binary annotation, suitable for passing to `annotations` option or `update_span/3`; see also convenience functions in `Tapper`."
  @spec binary_annotation_delta(type :: Api.binary_annotation_type, key :: Api.binary_annotation_key, value :: Api.binary_annotation_value, endpoint :: Api.maybe_endpoint ) :: Api.binary_annotaton_delta
  def binary_annotation_delta(type, key, value, endpoint \\ nil) when type in @binary_annotation_types and (is_atom(key) or is_binary(key)) do
    endpoint = check_endpoint(endpoint)
    {:binary_annotate, {type, key, value, endpoint}}
  end

  @doc """
  Add annotations to the current span; returns the same `Tapper.Id`.

  ## Arguments
  * `id` - Tapper id.
  * `deltas` - list, or single annotation tuple/atom. See helper functions.
  * `opts` - keyword list of options.

  ## Options
  * `timestamp` - an alternative timestamp for these annotations, e.g. from `Tapper.Timestamp.instant/0`.

  Use with annotation helper functions:
  ```
  id = Tapper.start_span(id)

  Tapper.update_span(id, [
    Tapper.async(),
    Tapper.name("child"),
    Tapper.http_path("/server/x"),
    Tapper.tag("x", 101)
  ])
  ```
  """
  @spec update_span(id :: Tapper.Id.t, deltas :: Api.delta() | [Api.delta()], opts :: Keyword.t) :: Tapper.Id.t
  def update_span(id, deltas, opts \\ [])

  def update_span(:ignore, _deltas, _opts), do: :ignore

  def update_span(id = %Tapper.Id{}, [], _opts), do: id

  def update_span(id = %Tapper.Id{span_id: span_id}, deltas, opts) when not is_nil(deltas) and is_list(opts) do
    timestamp = opts[:timestamp] || Timestamp.instant()

    GenServer.cast(via_tuple(id), {:update, span_id, timestamp, deltas})

    id
  end

  def whereis(:ignore), do: []
  def whereis(%Tapper.Id{trace_id: trace_id}), do: whereis(trace_id)
  def whereis(trace_id) do
    Registry.lookup(Tapper.Tracers, trace_id)
  end

  def check_endpoint(nil), do: nil
  def check_endpoint(endpoint = %Tapper.Endpoint{}), do: endpoint

  @doc """
  Provides some aliases for event annotation types:

  | alias | annotation value |
  | -- | -- |
  | :client_send | `cs` |
  | :client_recv | `cr` |
  | :server_send | `ss` |
  | :server_recv | `sr` |
  | :wire_send | `ws` |
  | :wire_recv | `wr` |
  """
  def map_annotation_type(type) when is_atom(type) do
    case type do
      :client_send -> :cs
      :client_recv -> :cr
      :server_send -> :ss
      :server_recv -> :sr
      :wire_send -> :ws
      :wire_recv -> :wr
      _ -> type
    end
  end

end