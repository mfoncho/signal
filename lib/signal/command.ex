defmodule Signal.Command  do

    defmacro __using__(opts) do
        quote do
            use Signal.Type
            import Signal.Command
            @module __MODULE__
            @before_compile unquote(__MODULE__)
            @version Keyword.get(unquote(opts), :version)
            @stream_opts Keyword.get(unquote(opts), :stream)
        end
    end

    defmacro __before_compile__(_env) do
        quote generated: true, location: :keep do
            with {stream_mod, field} <- Module.get_attribute(__MODULE__, :stream_opts) do
                defimpl Signal.Stream, for: __MODULE__ do
                    @field field
                    @stream_module stream_mod
                    def stream(command, _res) do 
                        {@stream_module, Map.get(command, @field)}
                    end
                end
            end

            if Module.defines?(__MODULE__, {:handle, 3}, :def) do
                with module <- @module do
                    defimpl Signal.Command.Handler do
                        @pmodule module
                        def handle(cmd, meta, aggr) do 
                            Kernel.apply(@pmodule, :handle, [cmd, meta, aggr])
                        end
                    end
                end
            end

            if Module.defines?(__MODULE__, {:execute, 2}, :def) do
                with module <- @module do
                    defimpl Signal.Command.Executor do
                        @pmodule module
                        def execute(cmd, params) do 
                            Kernel.apply(@pmodule, :execute, [cmd, params])
                        end
                    end
                end
            end

        end
    end

end
