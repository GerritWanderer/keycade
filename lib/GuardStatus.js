.pragma library

// Consumer-side boundary for the launch preflight record. The record is
// trusted because it matches the versioned guard schema, not because the
// helper emitted it: the input is bounded before it is parsed, exactly
// schemaVersion 1 / type "guard" / boolean disabled is accepted, and only
// the validated field is handed back. Anything else throws, and the caller
// fails closed.
var MAX_RECORD_CHARS = 4096

function object(value) { return value !== null && typeof value === "object" && !Array.isArray(value) }

function parsePreflightRecord(text) {
  if (typeof text !== "string" || text.length > MAX_RECORD_CHARS)
    throw new Error("invalid preflight record")
  var record = JSON.parse(text)
  if (!object(record) || record.schemaVersion !== 1 || record.type !== "guard"
      || typeof record.disabled !== "boolean")
    throw new Error("invalid preflight schema")
  return { "disabled": record.disabled }
}
