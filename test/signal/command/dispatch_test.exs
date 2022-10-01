defmodule Signal.Command.DispatchTest do

    use ExUnit.Case

    alias Signal.Task
    alias Signal.Result
    alias Signal.Void.Store
    alias Signal.Stream.History

    defmodule TestApplication do
        use Signal.Application,
            store: Store

        queue :default, timeout: 5000, retries: 0
    end

    defmodule Accounts do

        use Blueprint.Struct

        schema do
            field :number,      :string,    default: "123"
            field :balance,     :number,    default: 0
        end
    end

    defmodule Deposited do

        use Signal.Event,
            stream: {Accounts, :account}

        schema do
            field :account, :string,   default: ""
            field :amount,  :number,  default: 0
        end

    end

    defmodule Deposite do

        use Signal.Command,
            stream: {Accounts, :account}

        schema do
            field :account, :string,    default: "123"
            field :amount,  :number,    default: 0
        end

        def handle(%Deposite{}=deposite, _params, %Accounts{number: "123", balance: 0}) do
            Deposited.from(deposite)
        end

    end

    defimpl Signal.Stream.Reducer, for: Accounts do
        def apply(%Accounts{balance: balance}=account, _meta, %Deposited{amount: amt}) do
            {:ok, %Accounts{ account | balance: balance + amt }}
        end
    end

    setup do
        {:ok, _pid} = start_supervised(Store)
        {:ok, _pid} = start_supervised(TestApplication)
        :ok
    end

    describe "Dispatcher" do

        @tag :dispatcher
        test "should process task" do
            result =
                Deposite.new([amount: 5000])
                |>Task.new([
                    timeout: :infinity,
                    app: {TestApplication, TestApplication}
                ])
                |> Signal.Command.Dispatcher.execute()

            assert match?({:ok, %{}}, result)
        end

        @tag :dispatcher
        test "should execute task" do
            {:ok, histories} =
                Deposite.new([amount: 5000])
                |>Task.new([
                    timeout: :infinity,
                    app: {TestApplication, TestApplication}
                ])
                |> Signal.Command.Dispatcher.process()

            [%History{}=history] = histories
            assert length(history.events) == 1
            assert history.version == 1
        end

        @tag :dispatcher
        test "should dispatch and return result" do

            command = Deposite.new([amount: 5000])

            task = Task.new(command, [
                await: true,
                consistent: true,
                app: {TestApplication, TestApplication}
            ])

            {:ok, result} = Signal.Command.Dispatcher.dispatch(task)

            assert match?(%Result{
                aggregates: [%Accounts{number: "123", balance: 5000}],
                assigns: %{},
                result: nil,
            }, result)
        end

    end

end
