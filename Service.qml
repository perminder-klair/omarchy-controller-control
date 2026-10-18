import QtQuick
import Quickshell.Io

// Headless half of the plugin: owns the controller-control daemon.
//
// The daemon is a small pure-stdlib Python process that reads the pad from
// /dev/input and runs the bound actions. It speaks one JSON object per line on
// stdout, which is what everything below is parsing. Keeping the reader here
// -- rather than in the bar widget -- means the pad keeps working whether or
// not the widget is on the bar, and there is only ever one reader.
Item {
  id: root

  // Injected by omarchy-shell's service loader.
  property var shell: null
  property var manifest: null

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")
  readonly property string cli: pluginDir + "bin/controller-control"

  // Linux signal numbers, for Process.signal().
  readonly property int sigHup: 1
  readonly property int sigUsr1: 10
  readonly property int sigUsr2: 12

  // ---- live state, read by BarWidget.qml and Panel.qml -------------------

  property bool running: false
  property bool connected: false
  // Master switch, persisted in the config file. Not called `enabled`, which
  // would override Item's own property of that name.
  property bool switchedOn: true
  // Transient mute, held only while the panel is recording a combo.
  property bool paused: false
  property string deviceName: ""
  property bool exclusive: false
  property int bindingCount: 0
  property string lastError: ""
  readonly property bool enableBusy: enableProc.running
  property bool _enabledBefore: true

  // The full binding list, as the daemon last loaded it.
  property var bindings: []
  property string layout: "auto"
  // Tokens labelled differently under the current layout (Nintendo faces).
  property var labelOverrides: ({})

  // Buttons physically held right now, as canonical tokens.
  property var heldButtons: []

  function labelFor(token) {
    return root.labelOverrides[token] || token
  }

  function comboLabel(combo) {
    return combo.map(root.labelFor).join(" + ")
  }

  // ---- combo capture ("press the combo you want to bind") ---------------

  property bool capturing: false
  property var _capturePeak: []

  signal comboCaptured(var combo)
  signal fired(string label, string description)
  signal fireFailed(string label, string detail)

  function startCapture() {
    root._capturePeak = []
    root.capturing = true
    // Mute firing first: the buttons you are about to press are quite likely
    // the ones you are rebinding, and recording a combo should not also run
    // whatever it currently does.
    root.pauseFiring()
  }

  function cancelCapture() {
    if (!root.capturing) return
    root.capturing = false
    root._capturePeak = []
    root.resumeFiring()
  }

  // ---- signalling the daemon --------------------------------------------

  // True once the daemon has said "started". Before that its signal handlers
  // may not exist yet, and SIGUSR1's default action would kill it.
  property bool ready: false
  property bool _wantPaused: false

  function pauseFiring() {
    root._wantPaused = true
    if (root.ready) daemon.signal(root.sigUsr1)
  }

  function resumeFiring() {
    root._wantPaused = false
    if (root.ready) daemon.signal(root.sigUsr2)
  }

  function setEnabled(value) {
    if (enableProc.running) return
    // Show the change at once; the daemon's next state event confirms it,
    // and a failed command puts it back.
    root._enabledBefore = root.switchedOn
    root.switchedOn = value
    // `enable`/`disable` rewrite the config and signal the daemon
    // themselves, so there is nothing to reload afterwards.
    enableProc.command = [root.cli, value ? "enable" : "disable"]
    enableProc.running = true
  }

  function toggleEnabled() {
    root.setEnabled(!root.switchedOn)
  }

  function _captureButton(button, pressed, held) {
    if (!root.capturing) return
    if (pressed) {
      // Track the largest set held at once, so "L then R" records "L + R".
      if (held.length >= root._capturePeak.length) root._capturePeak = held.slice()
      return
    }
    if (held.length > 0 || root._capturePeak.length === 0) return
    var combo = root._capturePeak.slice().sort()
    root.capturing = false
    root._capturePeak = []
    root.resumeFiring()
    root.comboCaptured(combo)
  }

  // ---- daemon control ---------------------------------------------------

  // Restarts back off from 3s to a minute, so a daemon that cannot start
  // (a broken config, say) is not respawned every few seconds forever.
  readonly property int restartFloorMs: 3000
  readonly property int restartCeilingMs: 60000
  property int _restartDelay: restartFloorMs
  property bool _wanted: false
  property bool _quickRestart: false
  property double _startedAt: 0

  function start() {
    root._wanted = true
    if (daemon.running) return
    root._startedAt = Date.now()
    daemon.running = true
  }

  function stop() {
    root._wanted = false
    restartTimer.stop()
    daemon.running = false
  }

  function restart() {
    root._restartDelay = root.restartFloorMs
    if (daemon.running) {
      // onExited brings it back.
      root._wanted = true
      root._quickRestart = true
      daemon.running = false
    } else {
      root.start()
    }
  }

  // The daemon re-reads its config on SIGHUP, which is cheaper and less
  // disruptive than bouncing the process (no re-grab of the pad).
  function reload() {
    if (root.ready) daemon.signal(root.sigHup)
    else root.restart()
  }

  function _handle(line) {
    var event
    try {
      event = JSON.parse(line)
    } catch (e) {
      return
    }
    if (!event || !event.event) return

    switch (event.event) {
    case "started":
      root.running = true
      root.ready = true
      root.lastError = ""
      if (event.enabled !== undefined) root.switchedOn = event.enabled === true
      if (root._wantPaused) daemon.signal(root.sigUsr1)
      break
    case "state":
      root.connected = event.connected === true
      root.bindingCount = Number(event.bindings) || 0
      root.exclusive = event.exclusive === true
      if (event.enabled !== undefined && !enableProc.running) root.switchedOn = event.enabled === true
      if (event.paused !== undefined) root.paused = event.paused === true
      if (Array.isArray(event.devices) && event.devices.length > 0)
        root.deviceName = String(event.devices[0].name || "")
      else
        root.deviceName = ""
      break
    case "connected":
      root.connected = true
      root.deviceName = String(event.name || "")
      break
    case "disconnected":
      root.heldButtons = Array.isArray(event.held) ? event.held : []
      break
    case "bindings":
      root.bindings = Array.isArray(event.bindings) ? event.bindings : []
      root.layout = String(event.layout || "auto")
      root.labelOverrides = event.labels || {}
      break
    case "button":
      root.heldButtons = Array.isArray(event.held) ? event.held : []
      root._captureButton(String(event.button || ""), event.pressed === true, root.heldButtons)
      break
    case "fire":
      if (event.ok === false) {
        root.lastError = String(event.label || "") + ": " + String(event.detail || "failed")
        root.fireFailed(String(event.label || ""), String(event.detail || ""))
      } else {
        root.fired(String(event.label || ""), String(event.description || event.action || ""))
      }
      break
    case "reloaded":
      root.lastError = ""
      root.bindingCount = Number(event.bindings) || 0
      if (event.enabled !== undefined && !enableProc.running) root.switchedOn = event.enabled === true
      break
    case "error":
      root.lastError = String(event.message || "")
      break
    case "stopped":
      root.running = false
      root.ready = false
      break
    }
  }

  Process {
    id: daemon
    // The daemon leaves when this pipe closes, so a crashed shell cannot
    // leave it running beside the one the next shell starts.
    command: [root.cli, "daemon", "--exit-with-stdin"]
    stdinEnabled: true
    running: false

    stdout: SplitParser {
      onRead: function (line) { root._handle(line) }
    }
    stderr: SplitParser {
      onRead: function (line) {
        if (line && line.trim() !== "") root.lastError = line
      }
    }

    onExited: function (exitCode, exitStatus) {
      root.running = false
      root.ready = false
      root.connected = false
      root.heldButtons = []
      if (exitCode !== 0 && root.lastError === "")
        root.lastError = "daemon exited with code " + exitCode
      if (!root._wanted) return
      if (root._quickRestart) {
        root._quickRestart = false
        restartTimer.interval = 300
      } else {
        // 127 is the launcher finding no python3; retrying will not help.
        if (exitCode === 127) return
        // A run that lasted a while was healthy; start the backoff over.
        if (Date.now() - root._startedAt > 30000) root._restartDelay = root.restartFloorMs
        restartTimer.interval = root._restartDelay
        root._restartDelay = Math.min(root._restartDelay * 2, root.restartCeilingMs)
      }
      restartTimer.restart()
    }
  }

  Process {
    id: enableProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && text.trim() !== "") root.lastError = text.trim()
      }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) root.switchedOn = root._enabledBefore
    }
  }

  Timer {
    id: restartTimer
    repeat: false
    onTriggered: root.start()
  }

  IpcHandler {
    target: "controller"

    function status(): string {
      return JSON.stringify({
        running: root.running,
        connected: root.connected,
        enabled: root.switchedOn,
        paused: root.paused,
        device: root.deviceName,
        bindings: root.bindingCount,
        exclusive: root.exclusive,
        held: root.heldButtons,
        error: root.lastError
      })
    }

    function reload(): string {
      root.reload()
      return "ok"
    }

    function restart(): string {
      root.restart()
      return "ok"
    }

    function enable(): string {
      root.setEnabled(true)
      return "ok"
    }

    function disable(): string {
      root.setEnabled(false)
      return "ok"
    }

    function toggle(): string {
      root.toggleEnabled()
      return root.switchedOn ? "enabling" : "disabling"
    }
  }

  Component.onCompleted: start()
  Component.onDestruction: stop()
}
