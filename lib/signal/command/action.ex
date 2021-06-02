defmodule Signal.Command.Action do

    alias Signal.Execution.Task
    alias Signal.Command.Action


    defstruct [
        :app,
        :params,
        :result,
        :stream,
        :states,
        :command,
        :indices,
        :consistent,
        :causation_id,
        :correlation_id,
    ]


    def from(%Task{command: command, app: app, assigns: params}=task) do

        stream = Signal.Stream.stream(command, params)

        struct(Action, [
            app: app,
            params: params,
            stream: stream,
            result: task.result,
            command: command,
            states: task.states,
            indices: task.indices,
            consistent: task.consistent,
            causation_id: task.uuid, 
            correlation_id: UUID.uuid4()
        ])
    end

end
