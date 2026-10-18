import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Controller indicator for the bar.
//
// Solid glyph when a pad is connected, dimmed when not. It pulses briefly
// whenever a binding fires, which doubles as the "is this thing working?"
// answer without opening anything, and pulses red when one fails. Left click
// opens the bindings panel.
BarWidget {
  id: root
  moduleName: "co.klair.controller-control"

  // `bar` arrives after creation, and a Connections target must never be
  // undefined, so this settles on null until then.
  readonly property var service: bar?.shell?.serviceFor("co.klair.controller-control") ?? null
  readonly property bool running: service ? service.running === true : false
  readonly property bool connected: service ? service.connected === true : false
  readonly property bool switchedOn: service ? service.switchedOn === true : true
  readonly property string deviceName: service ? service.deviceName : ""
  readonly property int bindingCount: service ? service.bindingCount : 0
  readonly property string lastError: service ? service.lastError : ""
  readonly property bool hideWhenDisconnected: setting("hideWhenDisconnected", false)

  readonly property string glyph: "󰊴"

  property bool flashing: false
  property bool flashFailed: false

  visible: connected || !hideWhenDisconnected
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---- panel plumbing, same shape the bar expects from any widget --------

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = root.service
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Connections {
    target: root.service
    enabled: root.service !== null
    function onFired(label, description) {
      root.flashFailed = false
      root.flashing = true
      flashTimer.restart()
    }
    function onFireFailed(label, detail) {
      root.flashFailed = true
      root.flashing = true
      flashTimer.restart()
    }
  }

  Timer {
    id: flashTimer
    interval: 320
    onTriggered: root.flashing = false
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // BarIconButton, not a bare WidgetButton: WidgetButton derives
  // hasVisualContent from its *text*, so an icon-only widget with empty text
  // reports no content and the bar collapses it to zero width. BarIconButton
  // owns the glyph, the icon slot sizing, and the optical centering.
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    tooltipText: {
      var status = !root.running
        ? "Controller Control is not running"
        : (!root.connected
            ? "No controller connected"
            : root.deviceName + " — " + (root.switchedOn ? root.bindingCount + " bindings" : "disabled"))
      return root.lastError !== "" ? status + "\n" + root.lastError : status
    }

    // Dim rather than hide when nothing is paired, so the widget still says
    // "the pad is off" instead of silently vanishing.
    readonly property color baseForeground: root.bar ? root.bar.barForeground : Commons.Color.foreground
    // Three states worth telling apart at a glance: working, connected but
    // switched off, and nothing paired at all.
    foreground: !root.connected
      ? Qt.darker(baseForeground, 2.0)
      : (root.switchedOn ? baseForeground : Qt.darker(baseForeground, 1.7))

    // The pulse on each fired binding.
    active: root.flashing
    activeColor: root.flashFailed ? Commons.Color.urgent : Commons.Color.accent

    onPressed: function (b) {
      // Middle click is the quickest way to silence the pad without
      // opening anything.
      if (b === Qt.MiddleButton && root.service) root.service.toggleEnabled()
      else if (b === Qt.RightButton && root.service) root.service.reload()
      else root.togglePanel()
    }

    Behavior on foreground {
      ColorAnimation { duration: 160 }
    }
  }
}
