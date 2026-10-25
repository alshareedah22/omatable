.pragma library

// How grid cells show and edit values that crossed the wire as JSON.

function display(v) {
  if (v === null || v === undefined) return "NULL"
  if (typeof v === "object") {
    if (v.$t === "bytes") return "‹binary " + Math.floor(String(v.v).length * 3 / 4) + " bytes›"
    return JSON.stringify(v)
  }
  return String(v).replace(/\n/g, "↵")
}

function editText(v) {
  if (v === null || v === undefined) return ""
  return typeof v === "object" ? JSON.stringify(v) : String(v)
}
