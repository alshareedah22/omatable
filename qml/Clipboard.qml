import QtQuick
import Quickshell.Io

// Copies text with wl-copy through its stdin. Never as an argument: every local account can
// read a process's arguments (ps), and copied cells can be private data.
Item {
  id: clip

  property var pending: []

  function copy(text) {
    pending = pending.concat([String(text)])
    next()
  }

  function next() {
    if (proc.running || pending.length === 0) return
    proc.payload = pending[0]
    pending = pending.slice(1)
    proc.stdinEnabled = true
    proc.running = true
  }

  Process {
    id: proc
    property string payload: ""
    command: ["wl-copy"]
    stdinEnabled: true
    // wl-copy reads until end of input, then keeps serving the clipboard in the background
    onStarted: { write(payload); stdinEnabled = false }
    onExited: clip.next()
  }
}
