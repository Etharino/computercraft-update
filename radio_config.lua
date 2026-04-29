return {
  -- Only these modem channels can be used as radio frequencies.
  frequencies = { 101, 102, 103 },

  -- The frequency the radio opens on.
  defaultFrequency = 101,

  -- Leave nil to use the pocket computer label or computer ID.
  name = nil,

  maxMessageLength = 180,
}
