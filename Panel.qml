import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The bindings editor.
//
// The whole point of this panel is that you never have to look up what a
// button is called: press it on the pad and the combo is captured for you.
// The daemon is already streaming button events to Service.qml, so capture
// reuses that stream rather than opening the device a second time. The
// binding list arrives the same way, so opening the panel runs nothing.
//
// Keys: up/down pick a binding, Enter edits it, x removes it, r records a
// new combo, t flips the master switch, Esc leaves a field or closes.
Panel {
  id: root
  moduleName: "co.klair.controller-control"
  ipcTarget: "co.klair.controller-control"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  readonly property var barIdentity: hostWidget || root

  // Items inside the lazily built content, null until the panel first opens.
  readonly property Item actionField: panel.loadedContent ? panel.loadedContent.actionField : null

  readonly property bool running: service ? service.running === true : false
  readonly property bool connected: service ? service.connected === true : false
  readonly property string deviceName: service ? service.deviceName : ""
  readonly property var heldButtons: service ? service.heldButtons : []
  readonly property bool capturing: service ? service.capturing === true : false
  readonly property bool switchedOn: service ? service.switchedOn === true : true
  readonly property string lastError: service ? service.lastError : ""
  readonly property var bindings: service ? service.bindings : []
  readonly property int offCount: bindings.filter(function (b) { return b.enabled === false }).length

  // Reads differently at each step, because "Record combo" on its own does
  // not tell you that the controller is what you are meant to press.
  readonly property string captureHint: {
    if (!running) return "Controller Control is not running."
    if (!connected) return "Connect a controller to record a combo."
    if (capturing) return "Press the buttons on your controller now, then let go. Bindings are muted while recording."
    if (draftCombo.length > 0) {
      if (draftExisting)
        return comboText(draftCombo) + " is bound to " + actionText(draftExisting) + ". Saving replaces it."
      return "Captured " + comboText(draftCombo) + ". Now choose what it should do."
    }
    return "Press Record, then press the buttons on your controller."
  }

  property string statusMessage: ""

  // Keyboard cursor over the binding list; -1 until an arrow is pressed.
  property int cursorIndex: -1
  property bool fieldFocused: false

  // ---- draft binding being composed -------------------------------------

  property var draftCombo: []
  property bool draftIsCommand: false
  property string draftAction: ""
  property string draftDescription: ""
  property bool draftRepeat: false
  property bool draftHold: false
  readonly property bool draftReady: draftCombo.length > 0 && draftAction.trim() !== ""
  // The binding the draft would replace, if its combo is already bound.
  readonly property var draftExisting: {
    var key = draftCombo.join(" + ")
    for (var i = 0; i < bindings.length; i++)
      if (bindings[i].combo === key) return bindings[i]
    return null
  }

  function open() {
    root.controller.show()
  }

  function close() {
    if (service) service.cancelCapture()
    root.controller.hide()
  }

  function toggle() {
    root.opened ? root.close() : root.open()
  }

  function comboText(combo) {
    return service ? service.comboLabel(combo) : combo.join(" + ")
  }

  function actionText(binding) {
    return binding.keys ? binding.keys : "$ " + (binding.exec || "")
  }

  function beginCapture() {
    if (!service || !connected) return
    root.statusMessage = ""
    root.draftCombo = []
    service.startCapture()
  }

  function focusAction() {
    if (root.actionField) root.actionField.forceActiveFocus()
  }

  // Load an existing binding into the form, flags and all, to change it.
  function editBinding(binding) {
    root.statusMessage = ""
    root.draftCombo = String(binding.combo).split(" + ")
    root.draftIsCommand = !binding.keys
    root.draftAction = binding.keys || binding.exec || ""
    root.draftDescription = binding.description || ""
    root.draftRepeat = binding.repeat === true
    root.draftHold = binding.hold === true
    root.focusAction()
  }

  function saveDraft() {
    if (!root.draftReady || !service) return
    var args = [service.cli, "bind", root.draftCombo.join(" + ")]
    args.push(root.draftIsCommand ? "--exec" : "--keys")
    args.push(root.draftAction.trim())
    if (root.draftDescription.trim() !== "") {
      args.push("--description")
      args.push(root.draftDescription.trim())
    }
    if (root.draftRepeat) args.push("--repeat")
    if (root.draftHold) args.push("--hold")
    root.runCli(args, true)
  }

  function removeBinding(combo) {
    if (service) root.runCli([service.cli, "unbind", combo], false)
  }

  function clearDraft() {
    root.draftCombo = []
    root.draftAction = ""
    root.draftDescription = ""
    root.draftRepeat = false
    root.draftHold = false
  }

  function moveCursor(dy) {
    if (root.bindings.length === 0) return
    // The first arrow only shows where the cursor is.
    if (root.cursorIndex < 0) root.cursorIndex = 0
    else root.cursorIndex = Math.max(0, Math.min(root.bindings.length - 1, root.cursorIndex + dy))
  }

  function activateCursor() {
    if (root.cursorIndex >= 0 && root.cursorIndex < root.bindings.length)
      root.editBinding(root.bindings[root.cursorIndex])
  }

  function deleteAtCursor() {
    if (root.cursorIndex >= 0 && root.cursorIndex < root.bindings.length)
      root.removeBinding(root.bindings[root.cursorIndex].combo)
  }

  onBindingsChanged: if (cursorIndex >= bindings.length) cursorIndex = bindings.length - 1

  Connections {
    target: root.service
    enabled: root.service !== null
    function onComboCaptured(combo) {
      root.draftCombo = combo
      // Fill in what it already does, so saving keeps its flags.
      if (root.draftExisting) root.editBinding(root.draftExisting)
      else root.focusAction()
    }
  }

  // ---- CLI calls ---------------------------------------------------------

  // Edits run one after another, so a quick second edit is queued instead of
  // replacing the one still running. The CLI signals the daemon itself, and
  // the daemon then sends the new binding list.
  property var _queue: []

  function runCli(args, clearsDraft) {
    root._queue.push({ args: args, clearsDraft: clearsDraft })
    root._runNext()
  }

  function _runNext() {
    if (mutateProc.running || root._queue.length === 0) return
    var job = root._queue.shift()
    mutateProc.clearsDraft = job.clearsDraft
    mutateProc.command = job.args
    mutateProc.running = true
  }

  Process {
    id: mutateProc
    property bool clearsDraft: false
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && text.trim() !== "") root.statusMessage = text.trim()
      }
    }
    onExited: function (exitCode) {
      if (exitCode === 0) {
        root.statusMessage = ""
        if (clearsDraft) root.clearDraft()
      } else if (root.statusMessage === "") {
        root.statusMessage = "The edit failed (exit code " + exitCode + ")."
      }
      root._runNext()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(470))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias actionField: actionField
      implicitHeight: form.implicitHeight
      anchors.fill: parent
      blocked: root.fieldFocused

      onMoveRequested: function (dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()
      onDeleteRequested: root.deleteAtCursor()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onCloseRequested: {
        if (root.capturing && root.service) root.service.cancelCapture()
        else root.close()
      }
      onTextKey: function (t) {
        if (t === "r" || t === "R") root.beginCapture()
        else if ((t === "t" || t === "T") && root.service) root.service.toggleEnabled()
      }

      ColumnLayout {
        id: form
        width: parent.width
        spacing: Style.space(10)

        // ---- status: device, live buttons, master switch, reload -------

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Rectangle {
            width: Style.space(8)
            height: width
            radius: width / 2
            color: root.connected
              ? (root.switchedOn ? Commons.Color.accent : Qt.darker(root.barForeground, 1.6))
              : Qt.darker(root.barForeground, 2.2)
          }

          Text {
            Layout.fillWidth: true
            text: root.connected
              ? root.deviceName
              : (root.running ? "No controller connected" : "Not running")
            color: root.barForeground
            elide: Text.ElideRight
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          // Whatever is held right now, sitting just before the controls so
          // you can watch the pad answer while your hands are on it.
          Row {
            spacing: Style.space(4)

            Repeater {
              model: root.heldButtons

              Rectangle {
                required property string modelData
                radius: Style.space(4)
                color: Style.selectedAccentFill
                implicitWidth: heldLabel.implicitWidth + Style.space(10)
                implicitHeight: heldLabel.implicitHeight + Style.space(4)

                Text {
                  id: heldLabel
                  anchors.centerIn: parent
                  text: root.service ? root.service.labelFor(parent.modelData) : parent.modelData
                  color: Commons.Color.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }
            }
          }

          ToggleSwitch {
            checked: root.switchedOn
            busy: root.service ? root.service.enableBusy : false
            foreground: root.barForeground
            onToggled: if (root.service) root.service.toggleEnabled()
          }

          PanelActionButton {
            iconText: "󰑐"
            tooltipText: root.running ? "Reload bindings" : "Start again"
            foreground: root.barForeground
            onClicked: if (root.service) root.service.reload()
          }
        }

        // Whatever went wrong last, until it is dismissed or the daemon
        // reloads cleanly.
        RowLayout {
          Layout.fillWidth: true
          visible: root.lastError !== ""
          spacing: Style.space(8)

          Text {
            Layout.fillWidth: true
            text: root.lastError
            color: Commons.Color.urgent
            wrapMode: Text.WordWrap
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          PanelActionButton {
            Layout.alignment: Qt.AlignTop
            iconText: "󰅖"
            tooltipText: "Dismiss"
            foreground: root.barForeground
            onClicked: if (root.service) root.service.lastError = ""
          }
        }

        PanelSeparator {
          Layout.fillWidth: true
          foreground: root.barForeground
        }

        // ---- existing bindings -------------------------------------------

        PanelSectionHeader {
          text: root.bindings.length + " BINDINGS"
            + (root.offCount > 0 ? " · " + root.offCount + " OFF" : "")
            + (root.switchedOn ? "" : " · DISABLED")
          foreground: root.switchedOn ? root.barForeground : Commons.Color.urgent
        }

        Flickable {
          id: bindingFlick
          Layout.fillWidth: true
          Layout.preferredHeight: Math.min(bindingColumn.implicitHeight, Style.space(280))
          contentWidth: width
          contentHeight: bindingColumn.implicitHeight
          clip: true
          interactive: contentHeight > height
          opacity: root.switchedOn ? 1.0 : 0.45
          ScrollBar.vertical: ScrollBar {
            id: bindingScroll
            policy: ScrollBar.AsNeeded
          }

          // Keep the keyboard cursor in view.
          Connections {
            target: root
            function onCursorIndexChanged() {
              var row = bindingRepeater.itemAt(root.cursorIndex)
              if (!row) return
              if (row.y < bindingFlick.contentY)
                bindingFlick.contentY = row.y
              else if (row.y + row.height > bindingFlick.contentY + bindingFlick.height)
                bindingFlick.contentY = row.y + row.height - bindingFlick.height
            }
          }

          ColumnLayout {
            id: bindingColumn
            width: bindingFlick.width - (bindingFlick.interactive ? bindingScroll.width + Style.space(6) : 0)
            spacing: Style.space(2)

            Repeater {
              id: bindingRepeater
              model: root.bindings

              Item {
                id: bindingRow
                required property var modelData
                required property int index
                readonly property bool isOn: modelData.enabled !== false
                Layout.fillWidth: true
                implicitHeight: rowLayout.implicitHeight + Style.space(6)

                CursorSurface {
                  anchors.fill: parent
                  hasCursor: root.cursorIndex === bindingRow.index
                  foreground: root.barForeground
                }

                // Clicking a row loads it into the form below, to change it.
                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.cursorIndex = bindingRow.index
                  onClicked: root.editBinding(bindingRow.modelData)
                }

                RowLayout {
                  id: rowLayout
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.leftMargin: Style.space(4)
                  spacing: Style.space(8)
                  opacity: bindingRow.isOn ? 1.0 : 0.45

                  Text {
                    Layout.preferredWidth: Style.space(112)
                    Layout.alignment: Qt.AlignTop
                    text: bindingRow.modelData.label || bindingRow.modelData.combo
                    color: Commons.Color.accent
                    elide: Text.ElideRight
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  // Description on top, what it actually does underneath --
                  // a description alone does not tell you which shortcut it
                  // sends, which is the thing you need when editing.
                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    Text {
                      Layout.fillWidth: true
                      visible: text !== ""
                      text: bindingRow.modelData.description || ""
                      color: root.barForeground
                      elide: Text.ElideRight
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }

                    Text {
                      Layout.fillWidth: true
                      text: root.actionText(bindingRow.modelData)
                        + (bindingRow.modelData.repeat ? "  ·  repeat" : "")
                        + (bindingRow.modelData.hold ? "  ·  hold" : "")
                        + (bindingRow.isOn ? "" : "  ·  off")
                      color: Qt.darker(root.barForeground, 1.6)
                      elide: Text.ElideRight
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                  }

                  PanelActionButton {
                    Layout.alignment: Qt.AlignTop
                    iconText: "󰆴"
                    tooltipText: "Remove binding"
                    foreground: root.barForeground
                    hoverColor: Commons.Color.urgent
                    onClicked: root.removeBinding(bindingRow.modelData.combo)
                  }
                }
              }
            }
          }
        }

        PanelSeparator {
          Layout.fillWidth: true
          foreground: root.barForeground
        }

        // ---- new binding --------------------------------------------------

        PanelSectionHeader {
          text: root.draftExisting ? "EDIT BINDING" : "NEW BINDING"
          foreground: root.barForeground
        }

        // Step 1 of the flow, spelled out: the pad is the input device for
        // this form, and that is not obvious from a button labelled "Record".
        Text {
          Layout.fillWidth: true
          text: root.captureHint
          color: root.capturing ? Commons.Color.accent : Qt.darker(root.barForeground, 1.5)
          wrapMode: Text.WordWrap
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Button {
            text: root.capturing
              ? "Waiting…"
              : (root.draftCombo.length > 0
                  ? root.comboText(root.draftCombo)
                  : "1. Record combo")
            tooltipText: "Record a combo (r)"
            enabled: root.connected
            selected: root.capturing || root.draftCombo.length > 0
            bordered: true
            foreground: root.barForeground
            onClicked: root.beginCapture()
          }

          Button {
            text: root.draftIsCommand ? "Command" : "Keys"
            tooltipText: root.draftIsCommand
              ? "Runs a shell command"
              : "Types a keyboard shortcut, e.g. SUPER+RETURN"
            bordered: true
            foreground: root.barForeground
            onClicked: root.draftIsCommand = !root.draftIsCommand
          }

          Item { Layout.fillWidth: true }

          Button {
            text: "Repeat"
            tooltipText: "Fire again while held, for volume and brightness"
            selected: root.draftRepeat
            bordered: true
            foreground: root.barForeground
            onClicked: {
              root.draftRepeat = !root.draftRepeat
              if (root.draftRepeat) root.draftHold = false
            }
          }

          Button {
            text: "Hold"
            tooltipText: "Only fire after a long press, for anything destructive"
            selected: root.draftHold
            bordered: true
            foreground: root.barForeground
            onClicked: {
              root.draftHold = !root.draftHold
              if (root.draftHold) root.draftRepeat = false
            }
          }
        }

        TextField {
          id: actionField
          Layout.fillWidth: true
          foreground: root.barForeground
          text: root.draftAction
          placeholderText: root.draftIsCommand
            ? "2. Command to run, e.g. omarchy capture screenshot"
            : "2. Keys to send, e.g. SUPER+RETURN"
          onTextEdited: root.draftAction = text
          onActiveFocusChanged: root.fieldFocused = activeFocus || descriptionField.activeFocus
          onAccepted: root.saveDraft()
          Keys.onEscapePressed: keyCatcher.forceActiveFocus()
        }

        TextField {
          id: descriptionField
          Layout.fillWidth: true
          foreground: root.barForeground
          text: root.draftDescription
          placeholderText: "Description (optional)"
          onTextEdited: root.draftDescription = text
          onActiveFocusChanged: root.fieldFocused = activeFocus || actionField.activeFocus
          onAccepted: root.saveDraft()
          Keys.onEscapePressed: keyCatcher.forceActiveFocus()
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Button {
            text: root.draftExisting ? "3. Save changes" : "3. Save binding"
            enabled: root.draftReady
            bordered: true
            foreground: root.barForeground
            onClicked: root.saveDraft()
          }

          Item { Layout.fillWidth: true }

          Button {
            text: "Clear"
            bordered: true
            foreground: root.barForeground
            onClicked: {
              if (root.service) root.service.cancelCapture()
              root.clearDraft()
            }
          }
        }

        Text {
          Layout.fillWidth: true
          visible: root.statusMessage !== ""
          text: root.statusMessage
          color: Commons.Color.urgent
          wrapMode: Text.WordWrap
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
