defmodule Phoenix.LiveView.Upload do
  # Operations integrating Phoenix.LiveView.Socket with UploadConfig.
  @moduledoc false

  alias Phoenix.LiveView.{Socket, Utils, UploadConfig, UploadEntry}

  @refs_to_names :__phoenix_refs_to_names__

  @doc """
  Allows an upload.
  """
  def allow_upload(%Socket{} = socket, name, opts) when is_atom(name) and is_list(opts) do
    case uploaded_entries(socket, name) do
      {[], []} ->
        :ok

      {_, _} ->
        raise ArgumentError, """
        cannot allow_upload on an existing upload with active entries.

        Use cancel_upload and/or consume_upload to handle the active entries before allowing a new upload.
        """
    end

    ref = Utils.random_id()
    uploads = socket.assigns[:uploads] || %{}
    upload_config = UploadConfig.build(name, ref, opts)

    new_uploads =
      uploads
      |> Map.put(name, upload_config)
      |> Map.update(@refs_to_names, %{ref => name}, fn refs -> Map.put(refs, ref, name) end)

    Utils.assign(socket, :uploads, new_uploads)
  end

  @doc """
  Disallows a previously allowed upload.
  """
  def disallow_upload(%Socket{} = socket, name) when is_atom(name) do
    # TODO raise or cancel active upload for existing name?
    uploads = socket.assigns[:uploads] || %{}

    upload_config =
      uploads
      |> Map.fetch!(name)
      |> UploadConfig.disallow()

    new_refs =
      Enum.reduce(uploads[@refs_to_names], uploads[@refs_to_names], fn
        {ref, ^name}, acc -> Map.drop(acc, ref)
        {_ref, _name}, acc -> acc
      end)

    new_uploads =
      uploads
      |> Map.put(name, upload_config)
      |> Map.update!(@refs_to_names, fn _ -> new_refs end)

    Utils.assign(socket, :uploads, new_uploads)
  end

  @doc """
  Cancels an upload entry.
  """
  def cancel_upload(socket, name, entry_ref) do
    upload_config = Map.fetch!(socket.assigns[:uploads] || %{}, name)
    %UploadEntry{} = entry = UploadConfig.get_entry_by_ref(upload_config, entry_ref)

    upload_config
    |> UploadConfig.cancel_entry(entry)
    |> update_uploads(socket)
  end

  @doc """
  Returns the uploaded entries as a 2-tuple of completed and in progress.
  """
  def get_uploaded_entries(%Socket{} = socket, name) when is_atom(name) do
    upload_config = Map.fetch!(socket.assigns[:uploads] || %{}, name)
    UploadConfig.uploaded_entries(upload_config)
  end

  @doc """
  Updates the entry metadata.
  """
  def update_upload_entry_meta(%Socket{} = socket, upload_conf_name, %UploadEntry{} = entry, meta) do
    socket.assigns.uploads
    |> Map.fetch!(upload_conf_name)
    |> UploadConfig.update_entry_meta(entry.ref, meta)
    |> update_uploads(socket)
  end

  @doc """
  Updates the entry progress.

  Progress is either an integer percently between 0 and 100, or a map
  with an `"error"` key containing the information for a failed upload
  while in progress on the client.
  """
  def update_progress(%Socket{} = socket, config_ref, entry_ref, progress)
      when is_integer(progress) and progress >= 0 and progress <= 100 do
    socket
    |> get_upload_by_ref!(config_ref)
    |> UploadConfig.update_progress(entry_ref, progress)
    |> update_uploads(socket)
  end

  def update_progress(%Socket{} = socket, config_ref, entry_ref, %{"error" => reason})
      when is_binary(reason) do
    conf = get_upload_by_ref!(socket, config_ref)

    put_upload_error(socket, conf.name, entry_ref, :external_client_failure)
  end

  @doc """
  Puts the entries into the `%UploadConfig{}`.
  """
  def put_entries(%Socket{} = socket, %UploadConfig{} = conf, entries) do
    case UploadConfig.put_entries(conf, entries) do
      {:ok, new_config} ->
        {:ok, update_uploads(new_config, socket)}

      {:error, new_config} ->
        {:error, update_uploads(new_config, socket), new_config.errors}
    end
  end

  @doc """
  Unregisters a completed entry from an `Phoenix.LiveView.UploadChannel` process.
  """
  def unregister_completed_entry_upload(%Socket{} = socket, %UploadConfig{} = conf, pid)
      when is_pid(pid) do
    conf
    |> UploadConfig.unregister_completed_entry(pid)
    |> update_uploads(socket)
  end

  @doc """
  Registers a new entry upload for an `Phoenix.LiveView.UploadChannel` process.
  """
  def register_entry_upload(%Socket{} = socket, %UploadConfig{} = conf, pid, entry_ref)
      when is_pid(pid) do
    case UploadConfig.register_entry_upload(conf, pid, entry_ref) do
      {:ok, new_config} ->
        entry = UploadConfig.get_entry_by_ref(new_config, entry_ref)
        {:ok, update_uploads(new_config, socket), entry}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Populates the errors for a given entry.
  """
  def put_upload_error(%Socket{} = socket, conf_name, entry_ref, reason) do
    conf = Map.fetch!(socket.assigns.uploads, conf_name)

    conf
    |> UploadConfig.put_error(entry_ref, reason)
    |> update_uploads(socket)
  end

  @doc """
  Retrieves thes `%UploadConfig{}` from the socket for the provided ref or raises.
  """
  def get_upload_by_ref!(%Socket{} = socket, config_ref) do
    uploads = socket.assigns[:uploads] || raise(ArgumentError, "no uploads have been allowed")
    name = Map.fetch!(uploads[@refs_to_names], config_ref)
    Map.fetch!(uploads, name)
  end

  @doc """
  Returns the `%UploadConfig{}` from the socket for the `Phoenix.LiveView.UploadChannel` pid.
  """
  def get_upload_by_pid(socket, pid) when is_pid(pid) do
    Enum.find_value(socket.assigns[:uploads] || %{}, fn
      {@refs_to_names, _} -> false
      {_name, %UploadConfig{} = conf} -> UploadConfig.get_entry_by_pid(conf, pid) && conf
    end)
  end

  @doc """
  Returns the completed and in progress entries for the upload.
  """
  def uploaded_entries(%Socket{} = socket, name) do
    entries =
      case Map.fetch(socket.assigns[:uploads] || %{}, name) do
        {:ok, conf} -> conf.entries
        :error -> []
      end

    Enum.reduce(entries, {[], []}, fn entry, {done, in_progress} ->
      if entry.done? do
        {[entry | done], in_progress}
      else
        {done, [entry | in_progress]}
      end
    end)
  end

  @doc """
  Consumes the uploaded entries or raises if entries are stil in progress.
  """
  def consume_uploaded_entries(%Socket{} = socket, name, func) when is_function(func, 2) do
    conf =
      socket.assigns[:uploads][name] ||
        raise ArgumentError, "no upload allowed for #{inspect(name)}"

    entries =
      case uploaded_entries(socket, name) do
        {[_ | _] = done_entries, []} ->
          done_entries

        {_, [_ | _]} ->
          raise ArgumentError, "cannot consume uploaded files when entries are still in progress"

        {[], []} ->
          raise ArgumentError, "cannot consume uploaded files without active entries"
      end

    consume_entries(conf, entries, func)
  end

  @doc """
  Consumes an individual entry or raises if it is still in progress.
  """
  def consume_uploaded_entry(%Socket{} = socket, %UploadEntry{} = entry, func)
      when is_function(func, 1) do
    unless entry.done?,
      do: raise(ArgumentError, "cannot consume uploaded files when entries are still in progress")

    conf = Map.fetch!(socket.assigns[:uploads], entry.upload_config)
    [result] = consume_entries(conf, [entry], func)

    result
  end

  @doc """
  Drops all entries from the upload.
  """
  def drop_upload_entries(%Socket{} = socket, %UploadConfig{} = conf) do
    conf.entries
    |> Enum.reduce(conf, fn entry, acc -> UploadConfig.drop_entry(acc, entry) end)
    |> update_uploads(socket)
  end

  defp update_uploads(%UploadConfig{} = new_conf, %Socket{} = socket) do
    new_uploads = Map.update!(socket.assigns.uploads, new_conf.name, fn _ -> new_conf end)
    Utils.assign(socket, :uploads, new_uploads)
  end

  defp consume_entries(%UploadConfig{} = conf, entries, func)
       when is_list(entries) and is_function(func) do
    if conf.external do
      results =
        entries
        |> Enum.map(fn entry -> {entry, Map.fetch!(conf.entry_refs_to_metas, entry.ref)} end)
        |> Enum.map(fn {entry, meta} ->
          cond do
            is_function(func, 1) -> func.(meta)
            is_function(func, 2) -> func.(meta, entry)
          end
        end)

      Phoenix.LiveView.Channel.drop_upload_entries(conf)

      results
    else
      entries
      |> Enum.map(fn entry -> {entry, UploadConfig.entry_pid(conf, entry)} end)
      |> Enum.filter(fn {_entry, pid} -> is_pid(pid) end)
      |> Enum.map(fn {entry, pid} -> Phoenix.LiveView.UploadChannel.consume(pid, entry, func) end)
    end
  end

  @doc """
  Generates a preflight resposne by calling the `:external` function.
  """
  def generate_preflight_response(%Socket{} = socket, name) do
    %UploadConfig{} = conf = Map.fetch!(socket.assigns.uploads, name)

    client_meta = %{
      max_file_size: conf.max_file_size,
      max_entries: conf.max_entries,
      chunk_size: conf.chunk_size
    }

    case conf do
      %UploadConfig{external: false} = conf ->
        channel_preflight(socket, conf, client_meta)

      %UploadConfig{external: func} when is_function(func) ->
        external_preflight(socket, conf, client_meta)
    end
  end

  defp channel_preflight(%Socket{} = socket, %UploadConfig{} = conf, %{} = client_config_meta) do
    reply_entries =
      for entry <- conf.entries, into: %{} do
        token =
          Phoenix.LiveView.Static.sign_token(socket.endpoint, %{
            pid: self(),
            ref: {conf.ref, entry.ref}
          })

        {entry.ref, token}
      end

    {:ok, %{ref: conf.ref, config: client_config_meta, entries: reply_entries}, socket}
  end

  defp external_preflight(%Socket{} = socket, %UploadConfig{} = conf, client_config_meta) do
    reply_entries =
      Enum.reduce_while(conf.entries, {:ok, %{}, socket}, fn entry, {:ok, metas, acc} ->
        case conf.external.(entry, acc) do
          {:ok, %{} = meta, new_socket} ->
            new_socket = update_upload_entry_meta(new_socket, conf.name, entry, meta)
            {:cont, {:ok, Map.put(metas, entry.ref, meta), new_socket}}

          {:error, %{} = meta, new_socket} ->
            {:halt, {:error, {entry.ref, meta}, new_socket}}
        end
      end)

    case reply_entries do
      {:ok, entry_metas, new_socket} ->
        {:ok, %{ref: conf.ref, config: client_config_meta, entries: entry_metas}, new_socket}

      {:error, {ref, meta_reason}, new_socket} ->
        new_socket = put_upload_error(new_socket, conf.name, ref, meta_reason)
        {:error, %{ref: conf.ref, error: [ref, :preflight_failed]}, new_socket}
    end
  end
end