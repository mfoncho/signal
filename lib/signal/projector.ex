defmodule Signal.Projector do

    alias Signal.Event
    alias Signal.Logger
    alias Signal.Projector
    alias Signal.Event.Broker

    defstruct [:app, :name, :module, :consumer]

    defmacro __using__(opts) do
        app = Keyword.get(opts, :application)
        name = Keyword.get(opts, :name)
        topics = Keyword.get(opts, :topics)
        start = Keyword.get(opts, :start, :current)
        quote do
            use GenServer
            alias Signal.Event
            alias Signal.Projector

            @app unquote(app)

            @signal_start unquote(start)

            @name (if unquote(name) do 
                unquote(name) 
            else 
                Signal.Helper.module_to_string(__MODULE__) 
            end)

            @topics (unquote(topics) |> Enum.map(fn 
                topic when is_binary(topic) -> topic 
                topic when is_atom(topic) -> Signal.Helper.module_to_string(topic)
            end))

            @doc """
            Starts a new execution queue.
            """
            def start_link(opts) do
                opts = [
                    application: @app, 
                    topics: @topics, 
                    name: @name, 
                    start: @signal_start
                ] ++ opts 
                GenServer.start_link(__MODULE__, opts, name: __MODULE__)
            end

            @impl true
            def init(opts) do
                Projector.init(__MODULE__, opts)
            end

            @impl true
            def handle_info(%Event{}=event, %Projector{}=projector) do
                Projector.handle_event(projector, event)
            end

        end
    end


    def init(module, opts) do
        name = Keyword.get(opts, :name)
        topics = Keyword.get(opts, :topics)
        start = Keyword.get(opts, :start, :resume)
        application = Keyword.get(opts, :application)
        consumer = subscribe(application, name, topics, start)
        init_params = []
        case Kernel.apply(module, :init, [consumer, init_params]) do
            {:ok, state} ->
                params = [state: state, app: application, consumer: consumer, module: module]
                {:ok, struct(__MODULE__, params)} 
            error -> 
                error
        end
    end

    def subscribe(app, handle, topics, _start \\ :current) do
        opts = [topics: topics]
        Signal.Event.Broker.subscribe(app, handle, opts)
    end

    def handle_event(%Projector{}=projector, %Event{number: number}=event) do
        %Projector{
            app: app, 
            module: module, 
            consumer: consumer
        } = projector

        [
          app: app,
          projector: module,
          projecting: event.topic,
          number: event.number,
        ]
        |> Logger.info(label: :projector)

        args = [Event.data(event)]
        response = Kernel.apply(module, :project, args)
        case handle_response(projector, response) do
            {:noreply, handler} ->
                app
                |> Broker.acknowledge(consumer, number)
                {:noreply, handler}

            response ->            
                response
        end
    end

    def handle_response(%Projector{}=handler, response) do
        case response do
            :stop ->
                {:stop, :stopped, handler}

            {:stop, reason} ->
                {:stop, reason, handler}

            {:error, reason} ->
                {:stop, reason, handler}

            _resp ->
                {:noreply, handler}
        end
    end

end

