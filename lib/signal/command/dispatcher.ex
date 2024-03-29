defmodule Signal.Command.Dispatcher do

    alias Signal.Result
    alias Signal.Stream.Event
    alias Signal.Stream.History
    alias Signal.Command.Action
    alias Signal.Stream.Producer
    alias Signal.Execution.Queue
    alias Signal.Task, as: SigTask

    def dispatch(%SigTask{}=task) do
        case execute(task) do
            {:ok, result} ->
                process(%SigTask{task | result: result})
                |> finalize(task)

            error ->
                error
        end
    end

    def process(%SigTask{}=task) do
        action = Action.from(task)
        case Producer.process(action) do
            {:ok, result} ->
                {:ok, result}

            {:error, reason} ->
                {:error, reason}

            crash when is_tuple(crash) ->
                handle_crash(crash)
        end
    end

    def execute(%SigTask{app: app, command: command, assigns: assigns}) do
        case Queue.handle(app, command, assigns, []) do
            {:ok, result} ->
                {:ok, result}

            {:error, reason} ->
                {:error, reason}

            crash when is_tuple(crash) ->
                handle_crash(crash)

            result ->
                {:ok, result}
        end
    end

    defp finalize({:ok, histories}, %SigTask{}=sig_task) do

        %SigTask{app: app, result: result, assigns: assigns, await: await} = sig_task

        events = Enum.reduce(histories, [], fn %History{events: events}, acc -> 
            acc ++ Enum.map(events, &Event.payload(&1))
        end)

        opts = [result: result, assigns: assigns, events: events]

        if await do
            states = 
                histories
                |> Enum.map(fn %History{stream: stream, version: version} -> 
                    state_opts = [version: version, timeout: :infinity]
                    Task
                    |> Signal.Application.supervisor(app)
                    |> Task.Supervisor.async_nolink(fn -> 
                        app
                        |> Signal.Aggregates.Supervisor.prepare_aggregate(stream)
                        |> Signal.Aggregates.Aggregate.state(state_opts)
                    end, [shutdown: :brutal_kill])
                end)
                |> Task.yield_many(timeout(await))
                |> Enum.map(fn {task, res} -> 
                    case res do
                        {:ok, agg} ->
                            agg
                        _ ->
                            Task.shutdown(task, :brutal_kill)
                            {:error, :task_timout}
                    end
                end)

            struct(Result, opts ++ [states: states])
        else
            struct(Result, opts)
        end
        |> Result.ok()
    end

    defp finalize({:error, reason}, %SigTask{}) do
        {:error, reason}
    end

    def timeout(true) do
        5000
    end

    def timeout(duration) do
        duration
    end

    def handle_crash({:error, :raised, {raised, stacktrace}}) do
        reraise(raised, stacktrace)
    end

    def handle_crash({:error, :threw, {thrown, _stacktrace}}) do
        throw(thrown)
    end

end
