function handle()
  -- Record hook for graph.like
  -- Fires on create/delete from firehose
  -- No indexing needed for likes currently
  if action == "delete" then return true end
  return record
end
