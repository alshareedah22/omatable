import QtQuick
import Quickshell
import Quickshell.Io

// Owns the tablectl process and the request/reply bookkeeping.
Item {
  id: helper

  property string program: ""
  property string status: "stopped"   // stopped | starting | installing | ready
  property string progressText: ""
  property int progressPct: 0
  property string fatalText: ""
  property string lastStderr: ""
  property int nextId: 1
  property var callbacks: ({})
  // Safe mode: confirmer(error, yes, no) asks the user when a production
  // connection answers "confirm"; yes() resends the request with confirmed.
  property var confirmer: null

  signal message(var msg)

  function start() {
    if (proc.running) return
    fatalText = ""
    status = "starting"
    proc.running = true
  }

  function stop() {
    proc.running = false
  }

  function request(method, params, callback) {
    if (!proc.running || status !== "ready") {
      if (callback) callback(null, { code: "stopped", message: "The helper is not running" })
      return
    }
    const id = nextId++
    callbacks[id] = { cb: callback || null, method: method, params: params || {} }
    proc.write(JSON.stringify({ id: id, method: method, params: params || {} }) + "\n")
  }

  function receive(line) {
    let msg
    try { msg = JSON.parse(line) } catch (e) { return }
    if (msg.event !== undefined) {
      if (msg.event === "ready") status = "ready"
      else if (msg.event === "progress") { status = "installing"; progressText = msg.text; progressPct = msg.pct || 0 }
      else if (msg.event === "fatal") fatalText = msg.message
      helper.message(msg)
      return
    }
    const pending = callbacks[msg.id]
    delete callbacks[msg.id]
    if (!pending) return
    const cb = pending.cb
    if (msg.error && msg.error.code === "confirm" && confirmer) {
      confirmer(msg.error, function() { request(pending.method, Object.assign({}, pending.params, { confirmed: true }), cb) },
                function() { if (cb) cb(null, { code: "cancelled", message: "Cancelled; nothing was changed" }) })
      return
    }
    if (cb) cb(msg.result === undefined ? null : msg.result, msg.error || null)
  }

  Process {
    id: proc
    command: [helper.program]
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { helper.receive(String(line)) } }
    stderr: SplitParser { onRead: function(line) { helper.lastStderr = String(line) } }
    onExited: function(exitCode) {
      helper.status = "stopped"
      if (exitCode !== 0 && !helper.fatalText) helper.fatalText = helper.lastStderr || ("Helper exited with code " + exitCode)
      const pending = helper.callbacks
      helper.callbacks = ({})
      for (const id in pending) if (pending[id] && pending[id].cb) pending[id].cb(null, { code: "stopped", message: "The helper stopped" })
    }
  }
}
