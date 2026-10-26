.pragma library

// How grid cells show and edit values that crossed the wire as JSON.

function display(v) {
  if (v === null || v === undefined) return "NULL"
  if (typeof v === "object") {
    if (v.$t === "default") return "DEFAULT"
    if (v.$t === "bytes") return "‹binary " + Math.floor(String(v.v).length * 3 / 4) + " bytes›"
    return JSON.stringify(v)
  }
  return String(v).replace(/\n/g, "↵")
}

function editText(v) {
  if (v === null || v === undefined || (typeof v === "object" && v.$t === "default")) return ""
  return typeof v === "object" ? JSON.stringify(v) : String(v)
}

// Binary data as redis-cli prints it: printable ASCII kept, other bytes \xHH.
function escaped(v) {
  if (v === null || typeof v !== "object" || v.$t !== "bytes") return v === null || v === undefined ? "" : String(v)
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  const s = String(v.v).replace(/=+$/, "")
  let out = "", bits = 0, acc = 0
  for (let i = 0; i < s.length; i++) {
    acc = (acc << 6) | chars.indexOf(s[i])
    bits += 6
    if (bits >= 8) {
      bits -= 8
      const b = (acc >> bits) & 0xff
      out += b >= 0x20 && b < 0x7f && b !== 0x5c ? String.fromCharCode(b) : "\\x" + (b < 16 ? "0" : "") + b.toString(16)
    }
  }
  return out
}
