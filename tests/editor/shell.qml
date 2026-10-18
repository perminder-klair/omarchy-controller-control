import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import QtTest
import qs.Commons
import qs.Commons as Commons

ShellRoot {
  Service {
    id: fake
    running: true
    switchedOn: true
    profilesLoaded: true
    deviceAliases: ({"A": "B", "B": "Y"})
    bindings: [{combo: "B", label: "B", keys: "RETURN", repeat: true, hold: false, enabled: true}]
    labelOverrides: ({"A": "B"})
    connected: true
    deviceName: "Fixture controller"
    property int reloads: 0
    property int cancels: 0
    // Override startup and reload only: never create an input-reading daemon.
    function start() {}
    function reload() { reloads++ }
    onCapturingChanged: if (!capturing) cancels++
  }
  component FakeBar: QtObject {
    property QtObject shell: QtObject {
      function serviceFor(id) { return fake }
    }
    property string position: "top"
    property bool popoutSwitching: false
    property bool vertical: false
    property int barSize: 32
    property color barForeground: "#cacccc"
    property color urgent: "#ff0000"
    property string fontFamily: "monospace"
    property bool foregroundAnimationEnabled: false
    property var activePopout: false
    // Like the shell's bar: one popout at a time, closing the previous one.
    function requestPopout(owner) {
      if (activePopout === owner) return
      if (activePopout && "closeForPopoutSwitch" in activePopout) activePopout.closeForPopoutSwitch()
      activePopout = owner
    }
    function releasePopout(owner) { if (activePopout === owner) activePopout = false }
    function hideTooltip(item) {}
  }
  FakeBar { id: fakeBar }
  // A second monitor's bar.
  FakeBar { id: fakeBar2 }
  Loader {
    id: widgetLoader
    active: false
    sourceComponent: Component { BarWidget { bar: fakeBar } }
  }
  Loader {
    id: otherWidget
    active: false
    sourceComponent: Component { BarWidget { bar: fakeBar2 } }
  }
  Process {
    id: ipcClose
    property string method: "closeWindow"
    command: ["quickshell", "ipc", "-p", Quickshell.env("CONTROLLER_EDITOR_FIXTURE_PATH"), "--any-display", "call", "controller", ipcClose.method]
    property string reply: ""
    stdout: StdioCollector { onStreamFinished: ipcClose.reply = text }
    stderr: StdioCollector { onStreamFinished: ipcClose.reply += text }
    property int code: -1
    onExited: function(exitCode) { code = exitCode }
  }
  Process {
    id: compositorClose
    command: [Quickshell.env("CONTROLLER_TEST_SWAYMSG"), "-s", Quickshell.env("CONTROLLER_TEST_SWAYSOCK"), "[title=\"Controller Control\"] kill"]
    property int code: -1
    onExited: function(exitCode) { code = exitCode }
  }
  Process {
    id: snapshotProc
    command: [fake.cli, "fixture-snapshot"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var event = JSON.parse(text)
        event.bindings = fake.bindings
        event.aliases = fake.deviceAliases
        event.labels = fake.labelOverrides
        fake._handle(JSON.stringify(event))
      }
    }
  }
  Connections {
    target: timer.editor
    function onSettingsBusyChanged() { if (timer.stage >= 17 && !timer.editor.settingsBusy) snapshotProc.running = true }
  }
  TestCase { id: keys; when: false }
  Timer {
    id: timer
    interval: 120
    running: true
    repeat: true
    property int stage: 0
    property int startupWaits: 0
    property int ticks: 0
    readonly property var widget: widgetLoader.item
    property var panel: null
    property var editor: null
    property var action: null
    property var description: null
    property real savedScroll: 0
    function check(ok, message) { if (!ok) throw new Error(message) }
    function find(item, predicate) {
      if (predicate(item)) return item
      var children = item.children || []
      for (var i = 0; i < children.length; i++) {
        var match = find(children[i], predicate)
        if (match) return match
      }
      return null
    }
    function control(name) { return find(editor, function(item) { return item.objectName === name }) }
    function configurePointer() {
      control("pointerEnabledToggle").clicked()
      control("pointerStickPicker").changed("right")
      control("scrollStickPicker").changed("left")
      control("pointerSpeedField").modified(1450)
      control("scrollSpeedField").modified(12)
      control("pointerDeadZoneField").modified(22)
      control("scrollDeadZoneField").modified(41)
      control("invertScrollToggle").clicked()
      var left = control("leftClickTokenField")
      left.forceActiveFocus(); left.selectAll()
      keys.keyClick(Qt.Key_L); keys.keyClick(Qt.Key_2)
      var right = control("rightClickTokenField")
      right.forceActiveFocus(); right.selectAll()
      keys.keyClick(Qt.Key_R); keys.keyClick(Qt.Key_2)
    }
    onTriggered: {
      if (++ticks > 110) { console.error("STAGE TIMEOUT " + stage); Qt.quit(); return }
      if (snapshotProc.running || (stage > 0 && editor && (editor.refreshing || editor.settingsBusy))) return
      if (stage === 1 && !editor.shortcutOptions.length && !editor.shortcutMessage) return
      try {
        // Wait for real process completion, including slower native ARM runs.
        if (stage > 0 && editor && editor.settingsBusy) return
        if (stage === 0) {
          check(fake.editor === null, "Checking bar state does not load editor")
          check(widget === null, "Launcher starts without any bar widget")
          panel = fake.ensureEditor()
          check(panel !== null && !panel.opened && !panel.windowOpened, "Editor starts closed")
          check(fake.ensureEditor() === panel, "IPC reuses one service editor")
          // The editor is reparented into the hidden popup initially.
          editor = panel.form
          check(editor !== null, "Shared content exists")
          action = find(editor, function(item) { return item.placeholderText !== undefined && /^(Keys to send|Command to run)/.test(item.placeholderText) })
          description = find(editor, function(item) { return item.placeholderText === "Description (optional)" })
          check(action && description, "Manual key/command and description inputs retained")
          Commons.Color.shellValues = {"popups.text": "#64efab"}
          panel.openWindow()
          check(editor.shortcutOptions.length === 0, "Opening the editor does not fetch shortcuts")
          editor.loadShortcuts()
          editor.loadKeyboard()
          editor.loadMappings()
        } else if (stage === 1) {
          if (!editor.keyboardOptions.length) {
            if (!editor.keyboardMessage) return
            check(editor.keyboardMessage.indexOf("unavailable") >= 0, "Failed standard catalog keeps manual input available")
            editor.loadKeyboard()
            return
          }
          check(panel.windowOpened && !panel.opened, "Window opens independently of bar")
          widgetLoader.active = true
          check(widget.panel === panel && !widget.opened, "A later bar adopts the same service editor")
          fake.switchedOn = false
          check(editor.enabled && !editor.switchedOn, "Master switch off keeps editor controls usable")
          fake.switchedOn = true
          check(fake.cancels === 0, "Opening an inactive form does not resume external pause")
          check(editor.foreground.toString() === Commons.Color.popups.text.toString(), "Window uses popup foreground")
          check(editor.width >= 280 && editor.implicitHeight > 100, "Real form is laid out")
          check(editor.bindings.length === 1, "Daemon binding snapshot is used")
          check(editor.shortcutOptions.length >= 2, "Fake live shortcuts loaded: " + editor.shortcutOptions.length + " / " + editor.shortcutMessage)
          editor.draftIsCommand = true
          var shortcutPicker = find(editor, function(item) { return item.label === "PICK A SHORTCUT OR KEY" })
          check(shortcutPicker !== null, "Shared searchable picker exists")
          check(editor.pickerOptions.length === editor.shortcutOptions.length + editor.keyboardOptions.length
                && editor.pickerOptions[0].value.indexOf("shortcut:") === 0, "One picker lists shortcuts first, then keys")
          shortcutPicker.changed("shortcut:SUPER+RETURN")
          check(!editor.draftIsCommand && action.text === "SUPER+RETURN" && description.text === "Terminal", "Picker fills editable keys and empty description")
          editor.chooseShortcut("PRINT")
          check(editor.draftDescription === "Screenshot", "A second choice replaces its unchanged automatic description")
          editor.chooseShortcut("SUPER+RETURN")
          check(editor.draftDescription === "Terminal" && editor.draftCombo.length === 0, "Selection changes the draft without saving")
          editor.draftDescription = "My description"
          editor.chooseShortcut("SUPER+RETURN")
          check(description.text === "My description", "Picker preserves a custom description")
          check(editor.keyboardOptions.length === 119, "Fake standard keys loaded")
          var keyboardPicker = shortcutPicker
          editor.draftIsCommand = true
          check(!keyboardPicker.visible, "The picker is hidden in Command mode")
          editor.draftIsCommand = false
          keyboardPicker.changed("key:ENTER")
          check(action.text === "ENTER" && description.text === "My description", "Standard key fills editable input and preserves custom description")
          editor.draftDescription = ""
          editor.chooseKeyboardKey("LEFTSHIFT")
          editor.chooseKeyboardKey("RIGHTSHIFT")
          check(editor.draftDescription === "Right Shift", "Automatic key descriptions follow repeated selection")
          editor.draftAction = "SUPER+"
          editor.chooseKeyboardKey("A")
          check(editor.draftAction === "SUPER+A" && editor.draftCombo.length === 0, "Key choice appends to typed modifiers without saving")
          editor.editBinding({combo:"A",keys:"SUPER+RETURN",description:"Terminal"})
          editor.chooseKeyboardKey("F5")
          check(editor.draftDescription === "F5", "Loaded action description follows replacement key")
          editor.clearDraft()
          editor.refresh()
          editor.draftCombo = ["B"]
          editor.draftAction = "SUPER+"
          action.forceActiveFocus()
          keys.keyClick(Qt.Key_J)
          check(action.text === "SUPER+j", "Typing reaches manual input")
          keys.keyClick(Qt.Key_Tab)
          check(description.activeFocus, "Tab reaches description")
          editor.draftDescription = "custom keys"
          editor.saveDraft()
          editor.Window.window.height = 360
          var picker = find(editor, function(item) { return item.label === "PICK A SHORTCUT OR KEY" })
          picker.open()
        } else if (stage === 2) {
          var picker = find(editor, function(item) { return item.label === "PICK A SHORTCUT OR KEY" })
          check(picker.popupOpen && picker.filtered.length >= 2, "Real dropdown opens with captured compositor catalog")
          var list = find(editor.Window.window.contentItem, function(item) { return item.currentIndex !== undefined && item.count !== undefined && item.clip === true })
          check(list !== null && list.height > 0, "Dropdown has a clipped result viewport")
          var point = list.mapToItem(editor.Window.window.contentItem,0,0)
          check(point.y >= -1 && point.y + list.height <= editor.Window.window.height + 1, "Dropdown results fit inside a short window: " + point.y + " / " + list.height)
          picker.close()
          check(fake.reloads === 0 && editor.draftCombo.length === 0, "Saving clears draft without duplicate reload")
          check(editor.mappingState === "available", "Read-only discovery recovers after unavailable")
          fake._handle(JSON.stringify({event:"bindings", aliases:{A:"B",B:"Y"}, bindings:fake.bindings, labels:{A:"B"}}))
          check(editor.deviceAliases.A === "B", "Alias context follows the real service event handler")
          check(editor.matchingMappings.length === 1 && editor.matchingMappings[0].token === "A", "Raw A maps once to saved B; raw B maps elsewhere and is excluded")
          check(editor.matchingMappings[0].recorded === "B" && editor.matchingMappings[0].modifiers === 64 && editor.matchingMappings[0].submap === "desktop", "Alias and compositor context retained")
          var warning = find(editor, function(item) { return typeof item.text === "string" && item.text.indexOf("Potential overlap · B → B") === 0 })
          check(warning !== null && warning.text.indexOf("Super held · submap desktop") >= 0, "Visible advisory shows readable modifiers and submap")
          check(warning.text.indexOf("modifiers 64") < 0 && warning.text.indexOf("evdev") < 0, "Primary advisory omits implementation codes")
          check(editor.modifierContext(0) === "No modifiers", "No-modifier mapping is readable")
          check(editor.modifierContext(79) === "Shift held, Caps lock active, Ctrl held, Alt held, Super held", "Combined modifier context is readable")
          check(editor.modifierContext(176) === "Mod2 held, Mod3 held, Mod5 held", "Other Hyprland modifiers retain names")
          check(editor.modifierContext(320) === "Super held, Unknown modifiers 0x100", "Unknown bits are explicit")
          editor.draftCombo = ["Y"]
          check(editor.matchingMappings.length === 2, "Draft tokens add matching context without action-key inventory")
          editor.draftAction = "CUSTOM+KEYS"
          editor.draftDescription = "Keep custom input"
          editor.acceptMappingReport('{"available":true,"bindings":[]}')
          check(editor.mappingMessage.indexOf("No recognized") === 0, "Successful empty discovery differs from unavailable")
          editor.acceptMappingReport('{"available":false,"bindings":[]}')
          check(editor.mappingState === "unavailable" && editor.compositorBindings.length === 0, "Later unavailable response clears previous mappings")
          check(action.text === "CUSTOM+KEYS" && description.text === "Keep custom input", "Context updates preserve editable custom input")
          editor.refresh()
          editor.draftCombo = ["X"]
          editor.draftIsCommand = true
          editor.draftAction = "printf 'custom command'"
          editor.draftDescription = "custom command"
          editor.saveDraft()
        } else if (stage === 3) {
          check(fake.reloads === 0, "Manual command saved without duplicate reload")
          check(editor.mappingState === "available", "Discovery recovers without disturbing manual save")
          editor.beginCapture()
          check(fake.capturing, "Capture started through stub")
          action.forceActiveFocus()
          keys.keyClick(Qt.Key_Escape)
          check(panel.windowOpened && fake.capturing, "Escape leaves field before cancelling capture")
          keys.keyClick(Qt.Key_Escape)
          check(panel.windowOpened && !fake.capturing && fake.cancels === 1, "Escape cancels recording before closing")
          keys.keyClick(Qt.Key_Escape)
          check(!panel.windowOpened, "Next Escape closes the window")
          widget.open()
          check(panel.opened && !panel.windowOpened, "Bar popup remains available")
          editor.draftCombo = ["Y"]
          editor.draftAction = "SUPER+RETURN"
          panel.openWindow()
          check(!panel.opened && panel.windowOpened, "Open window replaces popup")
          check(editor.draftCombo[0] === "Y" && action.text === "SUPER+RETURN", "Shared draft survives reparenting")
          widget.open()
          editor.beginCapture()
          panel.openWindow()
          check(fake.capturing, "Window handoff preserves active capture")
          panel.close()
          check(!fake.capturing && !panel.windowOpened && !panel.opened && fake.cancels === 2, "Close releases capture exactly once")
          panel.close()
          check(fake.cancels === 2, "Closing inactive form leaves external pause alone")
          panel.openWindow()
          editor.beginCapture()
          widgetLoader.active = false
        } else if (stage === 4) {
          check(fake.capturing && panel.windowOpened && fake.cancels === 2, "Removing bar preserves independent window capture")
          check(panel.bar === null && panel.anchorItem === null && panel.hostWidget === null, "Removing bar clears its references")
          widgetLoader.active = true
          check(widget.panel === panel && fake.ensureEditor() === panel, "Restored bar reuses same service editor")
          panel.close()
          check(fake.cancels === 3, "Shared editor cancels its single recording")
          panel.openWindow()
          editor.Window.window.height = 300
        } else if (stage === 5) {
          // Wait for openWindow's fake list refresh, then fill the list.
          fake.bindings = Array(15).fill({combo: "A", keys: "RETURN"})
          editor.draftCombo = ["B"]
          editor.draftAction = "RETURN"
        } else if (stage === 6) {
          action.forceActiveFocus()
          keys.keyClick(Qt.Key_Tab)
        } else if (stage === 7) {
          var scroll = editor.parent.parent
          check(scroll.height < 300, "Small ordinary-window viewport is active")
          check(description.activeFocus && scroll.contentY > 0, "Tab scrolls to the lower description field")
          var point = description.mapToItem(scroll, 0, 0)
          check(point.y >= 0 && point.y + description.height <= scroll.height, "Focused description is fully visible")
          keys.keyClick(Qt.Key_Tab)
        } else if (stage === 8) {
          var scroll = editor.parent.parent
          var save = find(editor, function(item) { return item.text === "Save binding" })
          check(save.activeFocus, "Tab reaches Save")
          var point = save.mapToItem(scroll, 0, 0)
          check(point.y >= 0 && point.y + save.height <= scroll.height, "Focused Save is fully visible")
          // Preserve the merged editor's canonical identities and edit flags.
          fake.bindings = [
            {combo: "A", label: "B", keys: "RETURN", description: "repeat flag", repeat: true, hold: false, enabled: false},
            {combo: "X", exec: "true", description: "hold flag", repeat: false, hold: true}
          ]
          check(editor.comboText(["A"]) === "B", "Nintendo display labels remain separate from saved tokens")
          fake.comboCaptured(["A"])
          check(editor.draftRepeat && !editor.draftHold && editor.draftAction === "RETURN", "Capturing an existing combo preserves its action and flags")
          editor.saveDraft()
          editor.editBinding(fake.bindings[1])
          check(editor.draftHold && !editor.draftRepeat, "Editing preserves Hold")
          editor.saveDraft()
          check(editor._queue.length === 1, "The second edit queues behind the first")
        } else if (stage === 9) {
          check(editor._queue.length === 0 && editor.draftCombo.length === 0, "Both queued edits complete")
          check(fake.reloads === 0, "Queued mutations do not issue duplicate reloads")
          fake._handle(JSON.stringify({event: "error", message: "fixture config error"}))
          check(editor.lastError === "fixture config error", "Daemon errors reach the shared form")
          fake._handle(JSON.stringify({event: "fire", ok: false, label: "A", detail: "fixture action error"}))
          check(widget.flashFailed && widget.flashing, "Failed actions still pulse the bar red")
          editor.focusNavigation()
          editor.cursorIndex = -1
          keys.keyClick(Qt.Key_Down)
          check(editor.cursorIndex === 0, "Keyboard navigation selects a binding")
          keys.keyClick(Qt.Key_Return)
          check(editor.draftCombo[0] === "A" && editor.draftRepeat && action.activeFocus, "Enter edits the selected binding with flags")
          editor.runCli([fake.cli, "bind", "Z", "--keys", "RETURN"], false)
        } else if (stage === 10) {
          check(editor.statusMessage === "fixture mutation failed", "Failed CLI mutation is visible")
          check(editor.draftCombo[0] === "A", "Failed mutation preserves the current draft")
          editor.removeBinding("Y")
          editor.beginCapture()
          check(!fake.capturing, "Queued binding writes prevent recording")
        } else if (stage === 11) {
          check(editor.statusMessage === "", "A later successful edit recovers")
          check(fake.reloads === 0 && editor.bindings === fake.bindings, "Daemon owns the binding snapshot and reload policy")
          panel.close()
          panel.openWindow()
          editor.clearDraft()
        } else if (stage === 12) {
          var record = find(editor, function(item) { return item.text === "Record combo" })
          check(record !== null && record.focusable, "Window buttons are focusable")
          record.forceActiveFocus()
          record.clicked()
          keys.keyClick(Qt.Key_Escape)
          check(!fake.capturing && panel.windowOpened, "Escape from a focused button cancels capture")
          keys.keyClick(Qt.Key_R)
          check(fake.capturing, "Record shortcut still works after clicking a button")
          keys.keyClick(Qt.Key_Escape)
          action.forceActiveFocus()
          keys.keyClick(Qt.Key_Backtab, Qt.ShiftModifier)
          check(!action.activeFocus, "Shift+Tab traverses backwards")
          keys.keyClick(Qt.Key_Tab)
          check(action.activeFocus, "Tab returns to the action field")
          editor.focusNavigation()
          editor.cursorIndex = -1
          var scroll = editor.parent.parent
          scroll.contentY = Math.min(160, scroll.contentHeight - scroll.height)
          savedScroll = scroll.contentY
          fake.lastError = "Resize without moving navigation focus"
        } else if (stage === 13) {
          var scroll = editor.parent.parent
          check(savedScroll > 0 && Math.abs(scroll.contentY - savedScroll) < 2, "Content resize does not jump to the full-height key catcher")
          editor.beginCapture()
          widget.togglePanel()
          check(panel.opened && !panel.windowOpened && fake.capturing, "Bar click hands the window into the popup without cancelling capture")
          var owner = panel.hostWidget
          var anchor = panel.anchorItem
          otherWidget.active = true
          otherWidget.item.settings = {hideWhenDisconnected: false}
          check(panel.hostWidget === owner && panel.anchorItem === anchor && !otherWidget.item.opened, "Passive second widget cannot steal an open popup")
          ipcClose.code = -1
          ipcClose.running = true
        } else if (stage === 14) {
          if (ipcClose.running || ipcClose.code < 0) return
          check(ipcClose.code === 0 && panel.opened && fake.capturing, "Real closeWindow IPC leaves a popup and recording alone: " + ipcClose.code + " / " + ipcClose.reply + " / " + panel.opened + " / " + fake.capturing)
          check(fakeBar.activePopout === widget && fakeBar2.activePopout === false, "The open popup is registered with its own bar")
          otherWidget.item.open()
          check(panel.hostWidget === otherWidget.item && otherWidget.item.opened && !widget.opened, "Explicit second-widget open transfers ownership")
          check(fakeBar.activePopout === false && fakeBar2.activePopout === otherWidget.item, "Moving the popup to another bar releases the old bar and claims the new one")
          check(panel.opened && fake.capturing, "Moving the popup between bars keeps it open and keeps recording")
          widget.closeForPopoutSwitch()
          check(panel.opened && fake.capturing, "A bar that no longer hosts the popup cannot close it")
          panel.openWindow()
          ipcClose.code = -1
          ipcClose.running = true
        } else if (stage === 15) {
          if (ipcClose.running || ipcClose.code < 0) return
          check(ipcClose.code === 0 && !panel.windowOpened && !fake.capturing, "Real closeWindow IPC closes just the window and cancels recording")
          ipcClose.method = "openWindow"
          ipcClose.code = -1
          ipcClose.running = true
        } else if (stage === 16) {
          if (ipcClose.running || ipcClose.code < 0) return
          check(ipcClose.code === 0 && panel.windowOpened && !panel.opened, "Real openWindow IPC opens the ordinary window")
          editor.beginCapture()
          if (Quickshell.env("CONTROLLER_TEST_SWAYSOCK")) compositorClose.running = true
          else editor.Window.window.close()
        } else if (stage === 17) {
          if (compositorClose.running) return
          check(!panel.windowOpened && !fake.capturing, "Window close event releases capture")
          fake.running = false
          panel.openWindow()
          check(panel.windowOpened, "Editor can reopen after a native window close")
          check(control("bindingsPage").visible && !control("advancedPage").visible, "The Bindings tab shows by default")
          editor.currentTab = "advanced"
          editor.editBinding({combo: "A", keys: "RETURN"})
          check(editor.currentTab === "bindings", "Editing a binding returns to the Bindings tab")
          editor.clearDraft()
          editor.setInputMode("game")
        } else if (stage === 18) {
          // The reopened window is active by now, so keys reach it.
          editor.focusNavigation()
          keys.keyClick(Qt.Key_Right)
          check(editor.currentTab === "advanced" && control("advancedPage").visible && !control("bindingsPage").visible, "Right arrow opens the Advanced tab")
          // The binding cursor remains selected when its page is hidden.
          // x must not delete it, nor Enter open its hidden edit form. The
          // Python runner also checks the exact fake CLI mutation sequence.
          keys.keyClick(Qt.Key_Left)
          editor.cursorIndex = -1
          keys.keyClick(Qt.Key_Down)
          check(editor.cursorIndex === 0, "Keyboard selects a visible binding")
          keys.keyClick(Qt.Key_Right)
          check(!control("bindingsPage").visible, "Selected binding is hidden on Advanced")
          keys.keyClick(Qt.Key_X)
          keys.keyClick(Qt.Key_Return)
          check(editor.currentTab === "advanced" && editor.draftCombo.length === 0,
                "Advanced ignores hidden binding activation and deletion")
          // The rest of the fixture exercises mode, pointer and profile controls.
          fake._handle(JSON.stringify({event:"bindings", modes:{enabled:true,active:"game"}, bindings:fake.bindings}))
          check(editor.configuredModesEnabled && editor.configuredMode === "game", "Game mode is explicit opt-in")
          var game = find(editor, function(item) { return item.objectName === "gameModeButton" })
          check(game.selected && !fake.running, "Saved choice is visible without starting a daemon")
          fake._handle(JSON.stringify({event:"state", modes_enabled:true, input_mode:"game", input_ready:true, input_status:"passthrough"}))
          fake.running = true
          check(fake.inputMode === "game" && editor.modeDescription.indexOf("available to games") >= 0, "Actual passthrough status is shown")
          editor.setInputMode("os")
        } else if (stage === 19) {
          fake._handle(JSON.stringify({event:"bindings", modes:{enabled:true,active:"os"}, bindings:fake.bindings}))
          check(editor.configuredModesEnabled && editor.configuredMode === "os", "OS mode choice saved")
          check(editor.modeDescription.indexOf("Switching") >= 0, "Requested OS choice does not claim ownership")
          fake._handle(JSON.stringify({event:"state", modes_enabled:true, input_mode:"os", input_ready:false, input_status:"waiting_grab"}))
          check(editor.modeDescription.indexOf("another client") >= 0, "Failed ownership is visible")
          fake._handle(JSON.stringify({event:"state", modes_enabled:true, input_mode:"os", input_ready:false, input_status:"waiting_neutral"}))
          check(editor.modeDescription.indexOf("center the sticks") >= 0, "Neutral guard is visible")
          editor.setInputMode("disable")
        } else if (stage === 20) {
          fake._handle(JSON.stringify({event:"bindings", modes:{enabled:false,active:"os"}, bindings:fake.bindings}))
          check(!editor.configuredModesEnabled && editor.bindings[0].combo === "A", "Turning modes off preserves saved assignments")
          fake.running = false
          check(!editor.pointerSaved.enabled && !editor.pointerDirty, "Pointer starts disabled with stable saved assignments")
          panel.openWindow()
        } else if (stage === 21) {
          fake.savedPointer = {enabled:false, buttons:{A:"left",X:"left",B:"right"}}
          configurePointer()
          check(editor.pointerDirty && editor.pointerRevision === 0, "Editing shared controls does not write settings")
          editor.refresh()
        } else if (stage === 22) {
          check(editor.pointerDirty && editor.pointerDraft.speed === 1450, "Read-only refresh preserves unsaved settings")
          control("resetPointerButton").clicked()
          check(!editor.pointerDirty && !editor.pointerDraft.enabled && editor.pointerLeftToken === "A", "Reset discards edits without saving")
          configurePointer()
          control("scrollStickPicker").changed("right")
          editor.applyPointerSettings()
          check(editor.pointerRevision === 0 && editor.statusMessage.indexOf("different sticks") >= 0, "Same-stick draft is rejected without writing")
          control("scrollStickPicker").changed("left")
          control("applyPointerButton").clicked()
          check(editor.settingsBusy, "Apply owns the settings writer")
          editor.saveDraft()
          editor.removeBinding("B")
        } else if (stage === 23) {
          if (editor.settingsBusy) return
          check(!editor.pointerDirty && editor.pointerSaved.enabled && editor.pointerSaved.speed === 1450, "Apply accepts confirmed settings")
          check(editor.pointerSaved.buttons.L2 === "left" && editor.pointerSaved.buttons.R2 === "right" && editor.pointerSaved.buttons.X === "left", "Edited clicks preserve extra saved assignments")
          check(editor.pointerRevision === 1, "Only Apply wrote pointer settings")
          editor.setInputMode("os")
        } else if (stage === 24) {
          fake.savedModes = {enabled:true,active:"os"}
          check(editor.configuredMode === "os" && control("pointerSettingsForm").visible, "OS exposes pointer settings")
          fake._handle(JSON.stringify({event:"state", modes_enabled:true, input_mode:"os", input_ready:true, input_status:"ready", pointer_status:"select_one_controller"}))
          check(editor.pointerDescription.indexOf("Select one controller") >= 0, "Multiple-controller status gives a useful action")
          fake._handle(JSON.stringify({event:"state", modes_enabled:true, input_mode:"os", input_ready:true, input_status:"ready", pointer_status:"error"}))
          check(editor.pointerDescription.indexOf("unavailable") >= 0, "Pointer output error is visible")
          editor.setInputMode("game")
        } else if (stage === 25) {
          fake.savedModes = {enabled:true,active:"game"}
          check(!control("pointerSettingsForm").visible && editor.pointerDescription.indexOf("inactive in Game") >= 0, "Game shows a read-only pointer summary")
          editor.setInputMode("os")
        } else if (stage === 26) {
          fake.savedModes = {enabled:true,active:"os"}
          control("pointerSpeedField").modified(1337)
          control("applyPointerButton").clicked()
        } else if (stage === 27) {
          if (editor.settingsBusy) return
          check(editor.pointerDirty && editor.statusMessage.indexOf("Fixture rejected") >= 0, "Failed Apply retains the draft and error")
          control("resetPointerButton").clicked()
          check(!editor.pointerDirty && editor.pointerDraft.speed === 1450, "Reset restores last confirmed settings after an error")
          editor.setInputMode("disable")
        } else if (stage === 28) {
          fake.savedModes = {enabled:false,active:"os"}
          check(!editor.configuredModesEnabled && editor.bindings[0].combo === "A", "Pointer edits preserve existing mappings and mode choice")
          editor.clearDraft()
          fake.profilesLoaded = true
          check(editor.activeProfile === "Current" && editor.profileNames.length === 1, "Legacy config exposes implicit Current profile")
          check(control("copyProfileButton").text === "Create profile" && control("copyProfileButton").enabled, "Create label is clear and blank submission can show feedback")
          control("copyProfileButton").clicked()
          check(editor.profileNameMissing && control("profileNameError").visible && control("profileNameField").activeFocus && !editor.settingsBusy, "Blank create shows an inline error and focuses the name without dispatch")
          control("profileNameField").text = "   "
          control("profileNameField").accepted()
          check(editor.profileNameMissing && !editor.settingsBusy, "Whitespace and Enter use the same required-name feedback")
          control("profileNameField").text = "Work"
          check(!editor.profileNameMissing, "Typing a name clears the required-name error")
          control("profileNameField").text = ""

          editor.draftCombo = ["A"]
          editor.changeProfile("create", "BlockedCombo")
          check(editor.profileMessage.indexOf("Finish or Clear") === 0 && !editor.settingsBusy, "Recorded binding blocks profile changes")
          editor.clearDraft()
          editor.draftAction = "RETURN"
          editor.changeProfile("use", "Current")
          check(!editor.settingsBusy && action.text === "RETURN", "Manual action draft blocks switching and survives")
          editor.clearDraft()
          editor.draftDescription = "Unsaved label"
          editor.changeProfile("create", "BlockedDescription")
          check(!editor.settingsBusy && description.text === "Unsaved label", "Description-only draft blocks copying")
          editor.clearDraft()
          fake.capturing = true
          editor.changeProfile("create", "BlockedCapture")
          check(!editor.settingsBusy && fake.capturing, "Profile changes preserve active recording")
          fake.capturing = false
          editor.editPointerSetting("speed", 1449)
          editor.changeProfile("create", "BlockedPointer")
          check(editor.profileMessage.indexOf("Apply or Reset") === 0 && editor.pointerDirty && !editor.settingsBusy, "Pointer draft blocks copying with useful guidance")
          editor.resetPointerDraft()
          control("profileNameField").text = "Work"
          control("copyProfileButton").clicked()
          check(editor.settingsBusy, "Profile copy takes the settings writer immediately")
          editor.removeBinding("B")
          editor.beginCapture()
          check(!fake.capturing, "Profile writer prevents starting recording")
        } else if (stage === 29) {
          if (editor.settingsBusy || editor.activeProfile !== "Work") return
          check(editor.profileNames.join(",") === "Current,Work", "Copy retains original and selects named profile")
          check(!editor.configuredModesEnabled && !editor.pointerDirty && editor.pointerSaved.speed === 1450 && editor.bindings[0].combo === "A", "Copy preserves global mode, mappings and pointer settings")
          check(control("profileNameField").text === "", "Successful copy clears the name field")
          control("profileNameField").text = "Couch"
          control("renameProfileButton").clicked()
        } else if (stage === 30) {
          if (editor.settingsBusy || editor.activeProfile !== "Couch") return
          check(editor.profileNames.join(",") === "Couch,Current", "Rename updates active profile and preserves original")
          control("profileNameField").text = "Current"
          control("copyProfileButton").clicked()
        } else if (stage === 31) {
          if (editor.settingsBusy) return
          check(editor.activeProfile === "Couch" && control("profileNameField").text === "Current" && editor.profileMessage.indexOf("already exists") >= 0, "Failed copy preserves selection, name and error")
          control("osProfilePicker").changed("Current")
        } else if (stage === 32) {
          if (editor.settingsBusy || editor.activeProfile !== "Current") return
          check(editor.profileNames.join(",") === "Couch,Current" && !editor.pointerDirty, "Shared picker selects existing profile and refreshes settings")
          editor.setInputMode("game")
        } else if (stage === 33) {
          if (editor.settingsBusy || editor.configuredMode !== "game") return
          check(!control("profileSettingsForm").visible && control("gameProfileSummary").visible, "Game profile is read only")
          check(control("gameProfileSummary").text === "Passthrough · OS profile: Current", "Game retains a named OS profile without a game remap")
          editor.changeProfile("use", "Couch")
          check(!editor.settingsBusy && editor.activeProfile === "Current", "Game summary cannot dispatch a profile switch")
          editor.setInputMode("os")
        } else if (stage === 34) {
          if (editor.settingsBusy || editor.configuredMode !== "os") return
          check(control("profileSettingsForm").visible && editor.activeProfile === "Current", "OS restores remembered profile editing")
          control("profileNameField").text = "Next"
          control("profileNameField").forceActiveFocus()
          keys.keyClick(Qt.Key_Tab)
          check(control("copyProfileButton").activeFocus, "Keyboard navigation reaches profile copy")
          keys.keyClick(Qt.Key_Return)
        } else if (stage === 35) {
          if (editor.settingsBusy || editor.activeProfile !== "Next") return
          check(editor.pointerSaved.speed === 1450 && editor.bindings[0].combo === "A" && editor.configuredMode === "os", "Keyboard copy preserves pointer, mapping and mode state")
          control("deleteProfileButton").clicked()
          control("replacementProfilePicker").changed("Current")
          check(editor.deleteProfileReplacement === "Current", "User can choose the replacement profile")
          control("replacementProfilePicker").changed("Couch")
          check(editor.deleteProfileTarget === "Next" && editor.deleteProfileReplacement === "Couch" && !editor.settingsBusy, "First delete click only arms a named confirmation")
          check(!control("deleteProfileButton").enabled && control("confirmDeleteProfileButton").visible, "Confirmation is a separate control below the first click")
          control("cancelDeleteProfileButton").clicked()
          check(!editor.deleteProfileTarget && editor.activeProfile === "Next", "Cancel keeps active profile and does not dispatch")
          editor.requestProfileDelete()
          editor.changeProfile("use", "Current")
          check(!editor.deleteProfileTarget, "Switching cancels pending deletion")
        } else if (stage === 36) {
          if (editor.activeProfile !== "Current") return
          editor.requestProfileDelete()
          editor.draftCombo = ["A"]
          check(!editor.deleteProfileTarget, "Binding draft cancels deletion")
          editor.clearDraft()
          editor.requestProfileDelete()
          fake.capturing = true
          check(!editor.deleteProfileTarget, "Capture cancels deletion")
          fake.capturing = false
          editor.requestProfileDelete()
          fake.savedModes = {enabled:true,active:"game"}
          check(!editor.deleteProfileTarget, "Mode change cancels deletion")
          fake.savedModes = {enabled:true,active:"os"}
          var names = editor.profileNames
          fake.savedProfiles = {active:"Current",names:["Current"]}
          editor.requestProfileDelete()
          check(!editor.deleteProfileTarget && !control("deleteProfileButton").enabled && editor.profileMessage.indexOf("at least one") >= 0, "Last profile is protected")
          fake.savedProfiles = {active:"Current",names:names}
          editor.changeProfile("use", "Next")
        } else if (stage === 37) {
          if (editor.activeProfile !== "Next") return
          editor.requestProfileDelete()
          control("confirmDeleteProfileButton").clicked()
          check(editor.settingsBusy && !editor.deleteProfileTarget, "Second click dispatches one delete and takes writer")
        } else if (stage === 38) {
          check(editor.activeProfile === "Next" && editor.profileNames.length === 3 && editor.profileMessage.indexOf("Fixture refused delete") >= 0, "Failed delete retains selection and profiles with useful error")
          editor.changeProfile("use", "Couch")
        } else if (stage === 39) {
          if (editor.activeProfile !== "Couch") return
          editor.requestProfileDelete()
          check(editor.deleteProfileReplacement === "Current", "Confirmation names the replacement")
          control("confirmDeleteProfileButton").clicked()
          editor.confirmProfileDelete()
        } else if (stage === 40) {
          if (editor.activeProfile !== "Current") return
          check(editor.profileNames.join(",") === "Current,Next", "Confirmed deletion removes selected profile and selects replacement")
          check(editor.pointerSaved.speed === 1450 && editor.bindings[0].combo === "A" && editor.configuredMode === "os", "Delete preserves replacement settings and global mode")
          control("deleteProfilePicker").changed("Next")
          editor.requestProfileDelete()
          check(editor.deleteProfileTarget === "Next" && editor.activeProfile === "Current", "Inactive deletion does not activate its target")
          editor.confirmProfileDelete()
        } else if (stage === 41) {
          check(editor.activeProfile === "Current" && editor.profileMessage.indexOf("Fixture refused delete") >= 0, "Inactive delete failure preserves the active profile")
          console.log("EDITOR CHECK PASS")
          Qt.quit()
        }
        stage++
      } catch (e) {
        console.error("EDITOR CHECK FAIL stage " + stage + ": " + e)
        Qt.quit()
      }
    }
  }
}
