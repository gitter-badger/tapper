defmodule Tapper.Tracer.Supervisor do
    use Supervisor
    require Logger

    def start_link(config) do
        Supervisor.start_link(__MODULE__, [config], name: __MODULE__)
    end

    def init([config]) do
        Logger.debug(fn -> "Tracer.Supervisor init #{:erlang.pid_to_list(self())}" end)
        supervise(
            [worker(Tapper.Tracer.Server, [config], restart: :temporary)], # template for children, with config as first param
            strategy: :simple_one_for_one # i.e. on demand
        )
    end

    @doc "start tracing server with initial trace info"
    @spec start_tracer(Tapper.Tracer.Api.trace_init(), timestamp :: integer(), opts :: Keyword.t) :: Supervisor.on_start_child()
    def start_tracer(trace_init, timestamp, opts) do

        result = Supervisor.start_child(__MODULE__, [trace_init, self(), timestamp, opts]) # NB calls Tapper.Tracer.Server.start_link()

        case result do
            {:ok, _child} -> 
                Logger.debug(fn -> "Started tracer for #{inspect(trace_init)}" end)
                result
            _ ->
                Logger.error("Error starting child for #{inspect(result)}")
                result
        end
    end

end
