function handle()
  if action == "delete" then
    return record
  end

  if record.creativeWorkType == "video_game" then
    return record
  end

  return nil
end
