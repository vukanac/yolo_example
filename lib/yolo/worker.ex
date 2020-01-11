defmodule Yolo.Worker do
  use GenServer

  @uuid4_size 16

  @models %{
    "yolov3" => <<0>>,
    "yolov3-tiny" => <<1>>
  }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  def init(:ok) do
    python = Application.get_env(:yolo, :python) |> System.find_executable()
    detect_script = Application.get_env(:yolo, :detect_script)

    port = Port.open({:spawn_executable, python}, [:binary, :nouse_stdio, {:packet, 4}, args: [detect_script]])
    {:ok, %{port: port, requests: %{}}}
  end


  def request_detection(pid, image, model \\"yolov3") do
    # UUID.uuid4(:hex) is 32 bytes
    image_id = UUID.uuid4() |> UUID.string_to_binary!()
    request_detection(pid, image_id, image, model)
  end

  def request_detection(pid, image_id, image, model) when byte_size(image_id) == @uuid4_size do
    GenServer.call(pid, {:detect, image_id, image, @models[model]})
  end

  def await(image_id) do
    receive do
      {:detected, ^image_id, result} -> Map.put(result, :id, image_id)
    end
  end

  def handle_call({:detect, image_id, image_data, model_byte}, {from_pid, _}, worker) do
    Port.command(worker.port, [model_byte, image_id, image_data])
    worker = put_in(worker, [:requests, image_id], from_pid)
    {:reply, image_id, worker}
  end


  def handle_info({port, {:data, <<image_id::binary-size(@uuid4_size), json_string::binary()>>}}, %{port: port}=worker) do
    result = Jason.decode!(json_string) |> get_result()
    # getting from pid and removing the request from the map
    {from_pid, worker} = pop_in(worker, [:requests, image_id])
    # sending the result map to from_pid
    send(from_pid, {:detected, image_id, result})
    {:noreply, worker}
  end

  defp get_result(result) do
    %{
      id: result["id"],
      shape: %{width: result["shape"]["width"], height: result["shape"]["height"]},
      objects: get_objects(result["labels"], result["boxes"])
    }
  end

  def get_objects(labels, boxes) do
    Enum.zip(labels, boxes)
    |> Enum.map(fn {label, [x, y, bottom_right_x, bottom_right_y]}->
      w = bottom_right_x - x
      h = bottom_right_y - y
      %{label: label, x: x, y: y, w: w, h: h}
    end)
  end
end