import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// One maintainer-based form shared by the bar popup and ordinary window.
FocusScope {
  id: root
  property var service: null
  property color foreground: Commons.Color.foreground
  property bool windowMode: false
  signal closeRequested()
  signal windowRequested()
  signal switchRequested(int direction)
  signal focusRequested(var item)
  readonly property Item navigationItem: keyCatcher
  readonly property Item cursorRow: bindingRepeater.itemAt(cursorIndex)
  readonly property Item focusScrollTarget: profilePicker.popupOpen ? profilePickerExtent : actionPicker.popupOpen ? actionPickerExtent : focusedControl === root || focusedControl === keyCatcher ? cursorRow : focusedControl
  readonly property Item focusedControl: Window.window ? Window.window.activeFocusItem : null
  onFocusedControlChanged: {
    for (var item = focusedControl; item && item !== root; item = item.parent) {
      if (item.parent === root) {
        root.focusRequested(root.focusScrollTarget)
        break
      }
    }
  }
  readonly property real pickerPopupHeight: Math.min(Style.space(320), Math.max(Style.space(70), (Window.window ? Window.window.height : 680) - Style.space(100)))
  implicitHeight: form.implicitHeight
  height: implicitHeight
  focus: true
  Keys.forwardTo: [keyCatcher]
  Keys.priority: Keys.AfterItem

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
  readonly property bool bindingWritesBlocked: settingsOperation !== "" || pointerProc.running || modeProc.running
  readonly property bool refreshing: mappingsProc.running || keyboardProc.running || shortcutsProc.running
  readonly property bool configuredModesEnabled: service ? service.savedModes.enabled === true : false
  readonly property string configuredMode: service ? service.savedModes.active : "game"
  readonly property string modeDescription: {
    if (!configuredModesEnabled) return "Mode switching is off. Existing mappings and sharing settings are unchanged."
    if (configuredMode === "game") {
      if (!service || !service.running) return "Game passthrough selected. The plugin is inactive."
      if (service.inputMode !== "game" || service.inputStatus !== "passthrough") return "Switching to Game passthrough…"
      return "Game passthrough: desktop actions are inactive and the controller is available to games."
    }
    if (!service || !service.running) return "OS selected. Start the plugin to activate desktop controls."
    if (service.inputMode !== "os") return "Switching to OS controls…"
    var status = service.inputStatus
    if (status === "waiting_grab") return "OS waiting: another client owns the controller."
    if (status === "waiting_neutral") return "Release buttons and center the sticks to activate OS controls." + (service.inputBlocker ? " " + service.inputBlocker : "")
    if (status === "disabled") return "OS controls are disabled by the master switch."
    if (status === "paused") return "OS controls are paused while recording a combo."
    if (status === "disconnected") return "Connect the selected controller to activate OS controls."
    return service.inputReady ? "OS active: desktop shortcuts." : "OS controls are waiting for the controller."
  }
  property string settingsOperation: ""
  readonly property bool settingsBusy: settingsOperation !== "" || modeProc.running || mutateProc.running || pointerProc.running || profileProc.running
  readonly property string activeProfile: service ? service.savedProfiles.active : "Current"
  readonly property var profileNames: service ? service.savedProfiles.names : ["Current"]
  readonly property bool profilesLoaded: service ? service.profilesLoaded : false
  property string profileMessage: ""
  property bool profileNameMissing: false
  property string profileDeleteSelection: ""
  property string deleteProfileTarget: ""
  property string deleteProfileReplacement: ""
  onActiveProfileChanged: { cancelProfileDelete(); profileDeleteSelection = "" }
  onProfileNamesChanged: cancelProfileDelete()
  onProfilesLoadedChanged: if (!profilesLoaded) cancelProfileDelete()
  onConfiguredModeChanged: cancelProfileDelete()
  onConfiguredModesEnabledChanged: cancelProfileDelete()
  onCapturingChanged: cancelProfileDelete()
  onDraftComboChanged: cancelProfileDelete()
  onPointerDirtyChanged: cancelProfileDelete()
  readonly property bool profileEditingVisible: !configuredModesEnabled || configuredMode !== "game"
  property var pointerSaved: pointerDefaults()
  property var pointerDraft: pointerDefaults()
  property string pointerLeftSource: "L2"
  property string pointerRightSource: "R2"
  property string pointerLeftToken: "L2"
  property string pointerRightToken: "R2"
  property var pointerResult: null
  property int pointerRevision: 0
  readonly property bool pointerDirty: pointerFingerprint(pointerSettingsDraft()) !== pointerFingerprint(pointerSaved)
  readonly property bool pointerEditingVisible: !configuredModesEnabled || configuredMode !== "game"
  readonly property string pointerDescription: {
    if (!configuredModesEnabled) return "Pointer and scrolling require OS Mode. Settings stay inactive until then."
    if (configuredMode === "game") return "Pointer and scrolling are inactive in Game Mode." + (pointerDirty ? " Unsaved edits are retained." : "")
    if (!pointerSaved.enabled) return "Pointer and scrolling are off. Enable them below, then Apply settings."
    var status = service && "pointerStatus" in service ? service.pointerStatus : ""
    if (status === "select_one_controller") return "Select one controller in the plugin configuration to use pointer controls."
    if (status === "error") return "Pointer output is unavailable. Check controller permissions and reload."
    if (status === "requires_os") return "Pointer settings are saved; waiting for OS Mode."
    if (status === "ready") return "Pointer and scrolling are ready in OS Mode."
    return "Pointer settings are saved."
  }
  property var shortcutOptions: []
  property string shortcutMessage: ""
  property bool shortcutsLoaded: false
  property string shortcutOutput: ""
  property string shortcutError: ""
  property string autoDescription: ""
  property var keyboardOptions: []
  property string keyboardMessage: ""
  readonly property var deviceAliases: service ? service.deviceAliases : ({})
  property var compositorBindings: []
  property string mappingState: "not_loaded"
  property int unidentifiedMappings: 0
  readonly property var matchingMappings: mappingsForInputs()
  readonly property string mappingMessage: {
    if (mappingState === "not_loaded") return ""
    if (mappingState === "loading") return "Loading compositor mappings…"
    if (mappingState === "unavailable") return "Compositor mappings unavailable. Check the active Hyprland session."
    var incomplete = unidentifiedMappings ? " " + unidentifiedMappings + " bindings have no usable identity; this list is incomplete." : ""
    if (service && service.exclusiveActive) return "Physical controller events are exclusively grabbed. These potential overlaps apply when sharing input." + incomplete
    if (!compositorBindings.length) return "No recognized compositor input mappings were reported." + incomplete
    if (!matchingMappings.length) return "No compositor mappings match the selected or saved inputs." + incomplete
    return "Potential overlaps only: modifiers, submaps and input grabs affect whether both actions fire." + incomplete
  }

  // "bindings" for everyday editing, "advanced" for modes, profiles,
  // pointer and overlaps.
  property string currentTab: "bindings"

  // One picker for both catalogs: your Hyprland shortcuts, then plain keys.
  readonly property var pickerOptions: {
    var options = []
    for (var i = 0; i < shortcutOptions.length; i++) {
      var shortcut = shortcutOptions[i]
      options.push({ value: "shortcut:" + shortcut.value, label: shortcut.label,
        description: "Shortcut · " + (shortcut.description || shortcut.keys) })
    }
    for (var j = 0; j < keyboardOptions.length; j++) {
      var key = keyboardOptions[j]
      options.push({ value: "key:" + key.value, label: key.label, description: "Key · " + key.description })
    }
    return options
  }
  readonly property string pickerMessage: [shortcutMessage, keyboardMessage].filter(function (m) { return m !== "" }).join(" ")

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

  readonly property string cli: service ? service.cli : ""

  function pointerDefaults() {
    return { enabled: false, pointer_stick: "left", scroll_stick: "right", speed: 900,
      scroll_speed: 8, dead_zone: 0.18, scroll_dead_zone: 0.35, invert_scroll: false,
      buttons: { L2: "left", R2: "right" } }
  }

  function copyObject(value) { return JSON.parse(JSON.stringify(value)) }

  function pointerFingerprint(value) {
    var ordered = {}
    var keys = Object.keys(value).sort()
    for (var i = 0; i < keys.length; i++) {
      if (keys[i] !== "buttons") ordered[keys[i]] = value[keys[i]]
      else {
        ordered.buttons = {}
        var tokens = Object.keys(value.buttons).sort()
        for (var j = 0; j < tokens.length; j++) ordered.buttons[tokens[j]] = value.buttons[tokens[j]]
      }
    }
    return JSON.stringify(ordered)
  }

  function firstClickToken(buttons, action) {
    var tokens = Object.keys(buttons).sort()
    for (var i = 0; i < tokens.length; i++) if (buttons[tokens[i]] === action) return tokens[i]
    return ""
  }

  function normalizedPointerToken(token) {
    return token.trim().toUpperCase().replace(/-/g, "_").replace(/ /g, "_")
  }

  function pointerSettingsDraft() {
    var draft = copyObject(pointerDraft)
    // Replace the two displayed assignments while preserving extra saved clicks.
    delete draft.buttons[pointerLeftSource]
    delete draft.buttons[pointerRightSource]
    var left = normalizedPointerToken(pointerLeftToken)
    var right = normalizedPointerToken(pointerRightToken)
    if (left) draft.buttons[left] = "left"
    if (right) draft.buttons[right] = "right"
    return draft
  }

  function resetPointerDraft() {
    pointerDraft = copyObject(pointerSaved)
    pointerLeftSource = firstClickToken(pointerSaved.buttons, "left")
    pointerRightSource = firstClickToken(pointerSaved.buttons, "right")
    pointerLeftToken = pointerLeftSource
    pointerRightToken = pointerRightSource
  }

  function acceptPointer(value, force) {
    var dirty = pointerDirty
    var saved = pointerDefaults()
    if (value && typeof value === "object") {
      var keys = Object.keys(saved)
      for (var i = 0; i < keys.length; i++) {
        if (Object.prototype.hasOwnProperty.call(value, keys[i])) saved[keys[i]] = value[keys[i]]
      }
    }
    pointerSaved = saved
    if (force || !dirty) resetPointerDraft()
  }

  function editPointerSetting(name, value) {
    var draft = copyObject(pointerDraft)
    draft[name] = value
    pointerDraft = draft
  }

  function applyPointerSettings() {
    if (settingsBusy || !pointerDirty) return
    var draft = pointerSettingsDraft()
    var left = normalizedPointerToken(pointerLeftToken)
    var right = normalizedPointerToken(pointerRightToken)
    if ((left && !/^[A-Z0-9_]+$/.test(left)) || (right && !/^[A-Z0-9_]+$/.test(right)) || (left && left === right)) {
      statusMessage = "Use one controller token for each click, with different tokens for left and right."
      return
    }
    if (draft.pointer_stick !== "none" && draft.pointer_stick === draft.scroll_stick) {
      statusMessage = "Choose different sticks for pointer and scrolling, or set one to None."
      return
    }
    if (service && service.capturing) service.cancelCapture()
    pointerResult = null
    settingsOperation = "pointer"
    pointerRevision++
    pointerProc.command = [root.cli, "pointer", "--set", JSON.stringify(draft), "--json"]
    pointerProc.running = true
  }


  function refresh() {
    loadMappings()
    shortcutsLoaded = false
    if (actionPicker.popupOpen) loadShortcuts()
  }
  function loadShortcuts() {
    if (service && cli !== "" && !shortcutsLoaded && !shortcutsProc.running) shortcutsProc.running = true
  }
  function selectAction(keys, description, append) {
    draftIsCommand = false
    draftAction = append && /\+\s*$/.test(draftAction) ? draftAction.trim() + keys : keys
    if (!draftDescription.trim() || draftDescription === autoDescription) {
      draftDescription = description
      autoDescription = description
    }
  }
  function loadMappings() {
    if (!service || !cli || mappingsProc.running) return
    mappingState = "loading"
    mappingsProc.running = true
  }

  property string pendingMode: ""
  function setInputMode(value) {
    cancelProfileDelete()
    if (["game", "os", "enable", "disable"].indexOf(value) < 0) return
    if (settingsBusy) { pendingMode = value; return }
    if (service && service.capturing) service.cancelCapture()
    settingsOperation = "mode"
    modeProc.command = [root.cli, "mode", value]
    modeProc.running = true
  }

  function changeProfile(operation, name) {
    if (["use", "create", "rename"].indexOf(operation) < 0 || settingsBusy) return
    cancelProfileDelete()
    if (!profileChangeAllowed()) return
    var selected = name.trim()
    if (!selected) {
      profileMessage = ""
      profileNameMissing = true
      profileNameField.forceActiveFocus()
      return
    }
    profileNameMissing = false
    profileMessage = ""
    pointerRevision++
    settingsOperation = "profile"
    profileProc.operation = operation
    profileProc.command = [root.cli, "profile", operation]
      .concat(operation === "rename" ? [activeProfile, selected] : [selected])
    profileProc.running = true
  }

  function profileChangeAllowed() {
    if (settingsBusy) return false
    if (!profileEditingVisible) {
      profileMessage = "Game uses passthrough. Select OS to change its profile."
      return false
    }
    if (!profilesLoaded) {
      profileMessage = "Wait for settings to finish loading before changing profiles."
      return false
    }
    if (capturing || draftCombo.length || draftAction.trim() || draftDescription.trim()) {
      profileMessage = "Finish or Clear the current binding before changing OS profiles."
      return false
    }
    if (pointerDirty) {
      profileMessage = "Apply or Reset pointer settings before changing OS profiles."
      return false
    }
    return true
  }

  function cancelProfileDelete() {
    deleteProfileTarget = ""
    deleteProfileReplacement = ""
  }

  function requestProfileDelete() {
    cancelProfileDelete()
    if (!profileChangeAllowed()) return
    var others = profileNames.filter(function(name) { return name !== root.activeProfile })
    if (!others.length) {
      profileMessage = "Keep at least one OS profile."
      return
    }
    profileMessage = ""
    deleteProfileTarget = profileDeleteSelection || activeProfile
    deleteProfileReplacement = deleteProfileTarget === activeProfile ? others[0] : activeProfile
  }

  function confirmProfileDelete() {
    var target = deleteProfileTarget
    var replacement = deleteProfileReplacement
    if (!target || profileNames.indexOf(target) < 0 || !replacement || target === replacement ||
        profileNames.indexOf(replacement) < 0 || !profileChangeAllowed()) {
      cancelProfileDelete()
      return
    }
    cancelProfileDelete()
    profileMessage = ""
    pointerRevision++
    settingsOperation = "profile"
    profileProc.operation = "delete"
    profileProc.command = [root.cli, "profile", "delete", target].concat(target === activeProfile ? ["--switch-to", replacement] : [])
    profileProc.running = true
  }

  function mappingsForInputs() {
    var inputs = {}
    for (var i = 0; i < draftCombo.length; i++) inputs[draftCombo[i]] = true
    for (var j = 0; j < bindings.length; j++) {
      if (bindings[j].enabled === false) continue
      var combo = bindings[j].combo
      var tokens = Array.isArray(combo) ? combo : String(combo || "").split(/\s*\+\s*/)
      for (var k = 0; k < tokens.length; k++) inputs[tokens[k]] = true
    }
    var matches = []
    for (var n = 0; n < compositorBindings.length; n++) {
      var row = compositorBindings[n]
      if (!row || typeof row.token !== "string") continue
      // Match the decoder's one-step device alias application, not a chain.
      var recorded = Object.prototype.hasOwnProperty.call(deviceAliases, row.token)
        ? deviceAliases[row.token] : row.token
      if (!inputs[recorded]) continue
      matches.push({ token: row.token, recorded: recorded, code: row.code,
        description: row.description, modifiers: row.modifiers, submap: row.submap })
    }
    return matches
  }

  function acceptMappingReport(text) {
    try {
      var parsed = JSON.parse(text)
      if (parsed.available !== true || !Array.isArray(parsed.bindings)) throw new Error("unavailable")
      compositorBindings = parsed.bindings
      unidentifiedMappings = Number(parsed.unidentified) || 0
      mappingState = "available"
    } catch (e) {
      compositorBindings = []
      mappingState = "unavailable"
    }
  }

  function modifierContext(value) {
    var mask = Number(value)
    if (!isFinite(mask) || mask < 0 || Math.floor(mask) !== mask) return "Unknown modifiers"
    var flags = [[1, "Shift held"], [2, "Caps lock active"], [4, "Ctrl held"],
      [8, "Alt held"], [16, "Mod2 held"], [32, "Mod3 held"],
      [64, "Super held"], [128, "Mod5 held"]]
    var names = []
    for (var i = 0; i < flags.length; i++) {
      if (mask & flags[i][0]) names.push(flags[i][1])
    }
    var unknown = mask - (mask & 255)
    if (unknown) names.push("Unknown modifiers 0x" + unknown.toString(16))
    return names.length ? names.join(", ") : "No modifiers"
  }

  function chooseShortcut(value) {
    for (var i = 0; i < shortcutOptions.length; i++) {
      var option = shortcutOptions[i]
      if (option.value === value) {
        selectAction(option.keys, option.actionDescription || option.label, false)
        return
      }
    }
  }

  function loadKeyboard() {
    if (service && cli !== "" && !keyboardOptions.length && !keyboardProc.running) keyboardProc.running = true
  }
  function choosePicked(value) {
    if (value.indexOf("shortcut:") === 0) chooseShortcut(value.slice(9))
    else if (value.indexOf("key:") === 0) chooseKeyboardKey(value.slice(4))
  }

  function chooseKeyboardKey(value) {
    for (var i = 0; i < keyboardOptions.length; i++) {
      var option = keyboardOptions[i]
      if (option.value === value) {
        selectAction(option.keys, option.actionDescription || option.label, true)
        return
      }
    }
  }

  function comboText(combo) {
    return service ? service.comboLabel(combo) : combo.join(" + ")
  }

  function actionText(binding) {
    return binding.keys ? binding.keys : "$ " + (binding.exec || "")
  }

  function beginCapture() {
    if (!service || !connected || bindingWritesBlocked || mutateProc.running || _queue.length) return
    root.statusMessage = ""
    root.draftCombo = []
    root.currentTab = "bindings"
    service.startCapture()
  }

  function focusNavigation() { keyCatcher.forceActiveFocus() }

  function focusAction() {
    if (actionField) actionField.forceActiveFocus()
  }

  // Load an existing binding into the form, flags and all, to change it.
  function editBinding(binding) {
    root.currentTab = "bindings"
    root.statusMessage = ""
    root.draftCombo = String(binding.combo).split(" + ")
    root.draftIsCommand = !binding.keys
    root.draftAction = binding.keys || binding.exec || ""
    root.draftDescription = binding.description || ""
    root.autoDescription = root.draftDescription
    root.draftRepeat = binding.repeat === true
    root.draftHold = binding.hold === true
    root.focusAction()
  }

  function saveDraft() {
    if (!root.draftReady || !service || bindingWritesBlocked) return
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
    if (service && !bindingWritesBlocked) root.runCli([service.cli, "unbind", combo], false)
  }

  function clearDraft() {
    root.draftCombo = []
    root.draftAction = ""
    root.draftDescription = ""
    root.autoDescription = ""
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
  onCursorIndexChanged: Qt.callLater(function() { root.focusRequested(root.focusScrollTarget) })

  function focusControl(direction) {
    var first = root.focusedControl || keyCatcher
    var next = first.nextItemInFocusChain(direction > 0)
    while (next && next !== first) {
      if (next.visible && next.enabled && next.activeFocusOnTab) {
        next.forceActiveFocus(direction > 0 ? Qt.TabFocusReason : Qt.BacktabFocusReason)
        return
      }
      next = next.nextItemInFocusChain(direction > 0)
    }
  }

  onServiceChanged: if (service) acceptPointer(service.savedPointer, false)
  Connections {
    target: root.service
    function onSavedPointerChanged() { root.acceptPointer(root.service.savedPointer, false) }
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
    id: profileProc
    property string operation: ""
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim()) root.profileMessage = text.trim()
    }
    onExited: function(exitCode) {
      root.settingsOperation = ""
      if (exitCode === 0) {
        root.profileMessage = ""
        if (operation !== "use") profileNameField.text = ""
        if (root.pendingMode) { var next = root.pendingMode; root.pendingMode = ""; root.setInputMode(next) }
      } else if (!root.profileMessage) root.profileMessage = "Could not change the OS profile."
    }
  }

  Process {
    id: modeProc
    property string errorText: ""
    onStarted: errorText = ""
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: modeProc.errorText = text.trim() }
    onExited: function(exitCode) {
      Qt.callLater(function() {
        root.settingsOperation = ""
        root.statusMessage = exitCode === 0 ? "" : (modeProc.errorText || "Mode update failed (exit code " + exitCode + ").")
        if (root.pendingMode) { var next = root.pendingMode; root.pendingMode = ""; root.setInputMode(next) }
      })
    }
  }

  Process {
    id: pointerProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.pointerResult = JSON.parse(text) } catch (e) { root.pointerResult = null }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim()) root.statusMessage = text.trim()
    }
    onExited: function(exitCode) {
      root.settingsOperation = ""
      if (exitCode === 0) {
        if (root.pointerResult && typeof root.pointerResult === "object") {
          root.acceptPointer(root.pointerResult, true)
          root.statusMessage = ""
        } else root.statusMessage = "Settings saved, but readback failed. Reload to confirm them."
        if (root.pendingMode) { var next = root.pendingMode; root.pendingMode = ""; root.setInputMode(next) }
      }
    }
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
      root.settingsOperation = ""
      if (exitCode === 0) {
        root.statusMessage = ""
        if (clearsDraft) root.clearDraft()
      } else if (root.statusMessage === "") {
        root.statusMessage = "The edit failed (exit code " + exitCode + ")."
      }
      root._runNext()
      if (!mutateProc.running && root.pendingMode) { var next = root.pendingMode; root.pendingMode = ""; root.setInputMode(next) }
    }
  }

  PanelKeyCatcher {
    id: keyCatcher
    anchors.fill: parent
    // Text fields and focused buttons keep their normal editing/Tab keys.
    blocked: root.fieldFocused
    onMoveRequested: function (dx, dy) {
      if (dy !== 0 && root.currentTab === "bindings") root.moveCursor(dy)
      else if (dx !== 0) root.currentTab = dx > 0 ? "advanced" : "bindings"
    }
    onActivateRequested: if (root.currentTab === "bindings") root.activateCursor()
    onDeleteRequested: if (root.currentTab === "bindings") root.deleteAtCursor()
    onTabRequested: function (direction) {
      if (root.windowMode) root.focusControl(direction)
      else root.switchRequested(direction)
    }
    onCloseRequested: {
      if (root.capturing && root.service) root.service.cancelCapture()
      else root.closeRequested()
    }
    onTextKey: function (t) {
      if (t === "r" || t === "R") root.beginCapture()
      else if ((t === "t" || t === "T") && root.service) root.service.toggleEnabled()
    }
  }

  Process {
    id: mappingsProc
    command: [root.cli, "conflicts", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.acceptMappingReport(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.compositorBindings = []
        root.mappingState = "unavailable"
      }
    }
  }

  Process {
    id: shortcutsProc
    command: [root.cli, "shortcuts"]
    onStarted: {
      root.shortcutMessage = "Loading current shortcuts…"
      root.shortcutOutput = ""
      root.shortcutError = ""
    }
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.shortcutOutput = text }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.shortcutError = text.trim() }
    onExited: function(exitCode) {
      Qt.callLater(function() {
        root.shortcutOptions = []
        if (exitCode !== 0) {
          root.shortcutMessage = root.shortcutError || "Cannot read shortcuts; check the active Hyprland session."
          return
        }
        try {
          var parsed = JSON.parse(root.shortcutOutput)
          if (!Array.isArray(parsed)) throw new Error("Invalid catalog")
          root.shortcutOptions = parsed
          root.shortcutsLoaded = true
          root.shortcutMessage = parsed.length ? "" : "No replayable keyboard shortcuts found. Custom keys and commands are available below."
        } catch (e) { root.shortcutMessage = "Cannot read shortcuts; custom keys and commands are available below." }
      })
    }
  }

  Process {
    id: keyboardProc
    command: [root.cli, "keyboard-keys"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text)
          root.keyboardOptions = Array.isArray(parsed) ? parsed : []
          root.keyboardMessage = root.keyboardOptions.length ? "" : "Standard keys unavailable; type keys below."
        } catch (e) {
          root.keyboardOptions = []
          root.keyboardMessage = "Standard keys unavailable; type keys below."
        }
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.keyboardOptions = []
        root.keyboardMessage = "Standard keys unavailable; type keys below."
      }
    }
  }

  ColumnLayout {
    id: form
    width: parent.width
    spacing: Style.space(10)

    // ---- header: title, device status, messages, tabs ----------------

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)
      Text {
        Layout.fillWidth: true
        text: "Controller Control"
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
      }
      Button {
        visible: !root.windowMode
        text: "Open window"
        focusable: root.windowMode
        bordered: true
        foreground: root.foreground
        onClicked: root.windowRequested()
      }
      Button {
        text: "Close"
        focusable: root.windowMode
        bordered: true
        foreground: root.foreground
        onClicked: root.closeRequested()
      }
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)

      Rectangle {
        width: Style.space(8)
        height: width
        radius: width / 2
        color: root.connected
          ? (root.switchedOn ? Commons.Color.accent : Qt.darker(root.foreground, 1.6))
          : Qt.darker(root.foreground, 2.2)
      }

      Text {
        Layout.fillWidth: true
        text: root.connected
          ? root.deviceName
          : (root.running ? "No controller connected" : "Not running")
        color: root.foreground
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
        foreground: root.foreground
        onToggled: if (!root.settingsBusy && root.service) root.service.toggleEnabled()
      }

      PanelActionButton {
        iconText: "󰑐"
        tooltipText: root.running ? "Reload bindings" : "Start again"
        foreground: root.foreground
        onClicked: { root.refresh(); if (root.service) root.service.reload() }
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
        foreground: root.foreground
        onClicked: if (root.service) root.service.lastError = ""
      }
    }

    // A failed save or Apply, shown above the tabs so it is seen from either.
    Text {
      Layout.fillWidth: true
      visible: root.statusMessage !== ""
      text: root.statusMessage
      color: Commons.Color.urgent
      wrapMode: Text.WordWrap
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Text {
      Layout.fillWidth: true
      visible: root.configuredModesEnabled && root.configuredMode === "game"
      text: "Game mode: bindings are off and games get the controller. Change it under Advanced."
      textFormat: Text.PlainText
      color: Qt.darker(root.foreground, 1.5)
      wrapMode: Text.WordWrap
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    ButtonGroup {
      objectName: "editorTabs"
      options: [{ value: "bindings", label: "Bindings" }, { value: "advanced", label: "Advanced" }]
      value: root.currentTab
      focusable: root.windowMode
      foreground: root.foreground
      onChanged: function (value) { root.currentTab = value }
    }

    PanelSeparator {
      Layout.fillWidth: true
      foreground: root.foreground
    }

    // ---- bindings tab: the list, then adding or editing one ----------

    ColumnLayout {
      objectName: "bindingsPage"
      Layout.fillWidth: true
      visible: root.currentTab === "bindings"
      spacing: Style.space(10)

      PanelSectionHeader {
        text: root.bindings.length + " BINDINGS"
          + (root.offCount > 0 ? " · " + root.offCount + " OFF" : "")
          + (root.profileNames.length > 1 ? " · " + root.activeProfile.toUpperCase() : "")
          + (root.switchedOn ? "" : " · DISABLED")
        foreground: root.switchedOn ? root.foreground : Commons.Color.urgent
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
                foreground: root.foreground
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
                    color: root.foreground
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
                    color: Qt.darker(root.foreground, 1.6)
                    elide: Text.ElideRight
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }

                PanelActionButton {
                  Layout.alignment: Qt.AlignTop
                  iconText: "󰆴"
                  tooltipText: "Remove binding"
                  enabled: !root.bindingWritesBlocked
                  foreground: root.foreground
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
        foreground: root.foreground
      }

      PanelSectionHeader {
        text: root.draftExisting ? "EDIT BINDING" : "ADD BINDING"
        foreground: root.foreground
      }

      // The pad is the input device for this form, which is not obvious
      // from a button labelled "Record", so the next step is spelled out.
      Text {
        Layout.fillWidth: true
        text: root.captureHint
        color: root.capturing ? Commons.Color.accent : Qt.darker(root.foreground, 1.5)
        wrapMode: Text.WordWrap
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Button {
          focusable: root.windowMode
          text: root.capturing
            ? "Waiting…"
            : (root.draftCombo.length > 0 ? root.comboText(root.draftCombo) : "Record combo")
          tooltipText: "Record a combo (r)"
          enabled: root.connected && !root.settingsBusy
          selected: root.capturing || root.draftCombo.length > 0
          bordered: true
          foreground: root.foreground
          onClicked: root.beginCapture()
        }

        Button {
          focusable: root.windowMode
          text: root.draftIsCommand ? "Command" : "Keys"
          tooltipText: root.draftIsCommand
            ? "Runs a shell command"
            : "Types a keyboard shortcut, e.g. SUPER+RETURN"
          bordered: true
          foreground: root.foreground
          onClicked: root.draftIsCommand = !root.draftIsCommand
        }

        Item { Layout.fillWidth: true }

        Button {
          focusable: root.windowMode
          text: "Repeat"
          tooltipText: "Fire again while held, for volume and brightness"
          selected: root.draftRepeat
          bordered: true
          foreground: root.foreground
          onClicked: {
            root.draftRepeat = !root.draftRepeat
            if (root.draftRepeat) root.draftHold = false
          }
        }

        Button {
          focusable: root.windowMode
          text: "Hold"
          tooltipText: "Only fire after a long press, for anything destructive"
          selected: root.draftHold
          bordered: true
          foreground: root.foreground
          onClicked: {
            root.draftHold = !root.draftHold
            if (root.draftHold) root.draftRepeat = false
          }
        }
      }

      // Both catalogs load the first time the picker opens, never before.
      SearchableDropdown {
        id: actionPicker
        objectName: "actionPicker"
        onPopupOpenChanged: if (popupOpen) {
          root.loadShortcuts()
          root.loadKeyboard()
          Qt.callLater(function() { root.focusRequested(root.focusScrollTarget) })
        }
        Layout.bottomMargin: popupOpen ? root.pickerPopupHeight : 0
        popupMinHeight: Math.min(Style.spacing.searchablePopupMinHeight, root.pickerPopupHeight)
        popupRowHeight: Math.max(1, Math.floor((root.pickerPopupHeight - Style.space(50) - 5 * Style.spacing.labelGap) / 6))
        Item { id: actionPickerExtent; width: parent.width; height: parent.height + root.pickerPopupHeight }
        Layout.fillWidth: true
        visible: !root.draftIsCommand
        showLabel: false
        label: "PICK A SHORTCUT OR KEY"
        options: root.pickerOptions
        value: ""
        triggerLabel: "Pick one of your shortcuts or a key…"
        placeholderText: "Search shortcuts and keys…"
        emptyText: "Nothing matches"
        foreground: root.foreground
        onChanged: function(value) {
          root.choosePicked(value)
          actionPicker.value = ""
        }
      }

      Text {
        Layout.fillWidth: true
        visible: !root.draftIsCommand && root.pickerMessage !== ""
        text: root.pickerMessage
        textFormat: Text.PlainText
        color: Qt.darker(root.foreground, 1.5)
        wrapMode: Text.WordWrap
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      TextField {
        id: actionField
        onTextChanged: root.cancelProfileDelete()
        Layout.fillWidth: true
        foreground: root.foreground
        text: root.draftAction
        placeholderText: root.draftIsCommand
          ? "Command to run, e.g. omarchy capture screenshot"
          : "Keys to send, e.g. SUPER+RETURN"
        onTextEdited: root.draftAction = text
        onActiveFocusChanged: root.fieldFocused = activeFocus || descriptionField.activeFocus
        onAccepted: root.saveDraft()
        Keys.onEscapePressed: keyCatcher.forceActiveFocus()
      }

      TextField {
        id: descriptionField
        onTextChanged: root.cancelProfileDelete()
        Layout.fillWidth: true
        foreground: root.foreground
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
          focusable: root.windowMode
          text: root.draftExisting ? "Save changes" : "Save binding"
          enabled: root.draftReady && !root.bindingWritesBlocked
          bordered: true
          foreground: root.foreground
          onClicked: root.saveDraft()
        }

        Item { Layout.fillWidth: true }

        Button {
          focusable: root.windowMode
          text: "Clear"
          bordered: true
          foreground: root.foreground
          onClicked: {
            if (root.service) root.service.cancelCapture()
            root.clearDraft()
          }
        }
      }
    }

    // ---- advanced tab: mode, profiles, pointer, overlaps ---------------

    ColumnLayout {
      objectName: "advancedPage"
      Layout.fillWidth: true
      visible: root.currentTab === "advanced"
      spacing: Style.space(10)

      PanelSectionHeader { text: "CONTROLLER MODE"; foreground: root.foreground }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)
        Button {
          objectName: "modeOffButton"
          text: "Off"
          tooltipText: "No mode switching: bindings work and the controller stays shared"
          selected: !root.configuredModesEnabled
          enabled: !modeProc.running
          focusable: root.windowMode
          bordered: true
          foreground: root.foreground
          onClicked: if (root.configuredModesEnabled) root.setInputMode("disable")
        }
        Button {
          objectName: "gameModeButton"
          text: "Game"
          tooltipText: "Leave the controller to games; bindings are off"
          selected: root.configuredModesEnabled && root.configuredMode === "game"
          enabled: !modeProc.running
          focusable: root.windowMode
          bordered: true
          foreground: root.foreground
          onClicked: root.setInputMode("game")
        }
        Button {
          objectName: "osModeButton"
          text: "OS"
          tooltipText: "Take the controller over to drive the desktop"
          selected: root.configuredModesEnabled && root.configuredMode === "os"
          enabled: !modeProc.running
          focusable: root.windowMode
          bordered: true
          foreground: root.foreground
          onClicked: root.setInputMode("os")
        }
      }

      Text {
        Layout.fillWidth: true
        text: root.modeDescription
        textFormat: Text.PlainText
        color: Qt.darker(root.foreground, 1.5)
        wrapMode: Text.WordWrap
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      PanelSectionHeader { text: "PROFILES"; foreground: root.foreground }

      Text {
        objectName: "gameProfileSummary"
        Layout.fillWidth: true
        visible: !root.profileEditingVisible
        text: root.profilesLoaded ? "Passthrough · OS profile: " + root.activeProfile : "Loading OS profile…"
        textFormat: Text.PlainText
        color: root.foreground
        wrapMode: Text.WordWrap
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      ColumnLayout {
        objectName: "profileSettingsForm"
        Layout.fillWidth: true
        visible: root.profileEditingVisible
        enabled: !root.settingsBusy && root.profilesLoaded
        spacing: Style.space(8)

        SearchableDropdown {
          id: profilePicker
          onPopupOpenChanged: if (popupOpen) Qt.callLater(function() { root.focusRequested(root.focusScrollTarget) })
          Layout.bottomMargin: popupOpen ? root.pickerPopupHeight : 0
          popupMinHeight: Math.min(Style.spacing.searchablePopupMinHeight, root.pickerPopupHeight)
          popupRowHeight: Math.max(1, Math.floor((root.pickerPopupHeight - Style.space(50) - 5 * Style.spacing.labelGap) / 6))
          Item { id: profilePickerExtent; width: parent.width; height: parent.height + root.pickerPopupHeight }
          objectName: "osProfilePicker"
          Layout.fillWidth: true
          showLabel: false
          value: ""
          options: root.profileNames
          triggerLabel: "Profile: " + root.activeProfile
          placeholderText: "Search profiles…"
          foreground: root.foreground
          onChanged: function(value) {
            root.changeProfile("use", value)
            profilePicker.value = ""
          }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          TextField {
            id: profileNameField
            onTextChanged: {
              root.cancelProfileDelete()
              if (text.trim()) root.profileNameMissing = false
            }
            objectName: "profileNameField"
            Layout.fillWidth: true
            maximumLength: 64
            placeholderText: "New profile name"
            foreground: root.foreground
            onAccepted: root.changeProfile("create", text)
          }
          Button {
            objectName: "copyProfileButton"
            text: "Create profile"
            tooltipText: "A new profile starting from this one's bindings and pointer settings"
            focusable: root.windowMode
            bordered: true
            foreground: root.foreground
            onClicked: root.changeProfile("create", profileNameField.text)
          }
          Button {
            objectName: "renameProfileButton"
            text: "Rename current"
            enabled: profileNameField.text.trim() !== "" && profileNameField.text.trim() !== root.activeProfile
            focusable: root.windowMode
            bordered: true
            foreground: root.foreground
            onClicked: root.changeProfile("rename", profileNameField.text)
          }
        }

        Text {
          objectName: "profileNameError"
          Layout.fillWidth: true
          visible: root.profileNameMissing
          text: "Enter a name for the new profile."
          color: Commons.Color.urgent
          wrapMode: Text.WordWrap
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)
          visible: root.profileNames.length > 1

          Dropdown {
            objectName: "deleteProfilePicker"
            Layout.fillWidth: true
            label: "Profile to delete"
            options: root.profileNames
            value: root.profileDeleteSelection || root.activeProfile
            foreground: root.foreground
            onChanged: function(value) { root.cancelProfileDelete(); root.profileDeleteSelection = value }
          }
          Button {
            objectName: "deleteProfileButton"
            Layout.alignment: Qt.AlignBottom
            text: "Delete profile"
            enabled: root.profileNames.length > 1 && !root.deleteProfileTarget
            focusable: root.windowMode
            bordered: true
            foreground: root.foreground
            onClicked: root.requestProfileDelete()
          }
        }

        Text {
          Layout.fillWidth: true
          visible: root.deleteProfileTarget !== ""
          text: "Delete “" + root.deleteProfileTarget + "” and its saved mappings and pointer settings?"
            + (root.deleteProfileTarget === root.activeProfile ? " Switch to “" + root.deleteProfileReplacement + "”." : "")
          textFormat: Text.PlainText
          color: root.foreground
          wrapMode: Text.WordWrap
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Dropdown {
          objectName: "replacementProfilePicker"
          Layout.fillWidth: true
          visible: root.deleteProfileTarget === root.activeProfile && root.deleteProfileTarget !== ""
          label: "Switch to"
          options: root.profileNames.filter(function(name) { return name !== root.deleteProfileTarget })
          value: root.deleteProfileReplacement
          foreground: root.foreground
          onChanged: function(value) { root.deleteProfileReplacement = value }
        }

        RowLayout {
          Layout.fillWidth: true
          visible: root.deleteProfileTarget !== ""
          spacing: Style.space(8)
          Button {
            objectName: "confirmDeleteProfileButton"
            text: "Confirm delete"
            focusable: root.windowMode
            bordered: true
            foreground: Commons.Color.urgent
            onClicked: root.confirmProfileDelete()
          }
          Button {
            objectName: "cancelDeleteProfileButton"
            text: "Cancel"
            focusable: root.windowMode
            bordered: true
            foreground: root.foreground
            onClicked: root.cancelProfileDelete()
          }
        }
      }

      Text {
        objectName: "profileMessage"
        Layout.fillWidth: true
        visible: root.profileEditingVisible && root.profileMessage !== ""
        text: root.profileMessage
        textFormat: Text.PlainText
        color: Commons.Color.urgent
        wrapMode: Text.WordWrap
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      PanelSectionHeader { text: "POINTER AND SCROLLING"; foreground: root.foreground }

      Text {
        Layout.fillWidth: true
        text: root.pointerDescription
        textFormat: Text.PlainText
        color: Qt.darker(root.foreground, 1.5)
        wrapMode: Text.WordWrap
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      ColumnLayout {
        objectName: "pointerSettingsForm"
        Layout.fillWidth: true
        visible: root.pointerEditingVisible
        enabled: !root.settingsBusy
        spacing: Style.space(8)

        Toggle {
          objectName: "pointerEnabledToggle"
          Layout.fillWidth: true
          label: "Use a stick as the mouse (OS mode)"
          checked: root.pointerDraft.enabled
          foreground: root.foreground
          onClicked: root.editPointerSetting("enabled", !root.pointerDraft.enabled)
        }

        // The details only matter once the pointer is on.
        GridLayout {
          Layout.fillWidth: true
          visible: root.pointerDraft.enabled
          columns: root.width < Style.space(460) ? 1 : 2
          columnSpacing: Style.space(12)
          rowSpacing: Style.space(8)

          Dropdown {
            objectName: "pointerStickPicker"
            Layout.fillWidth: true
            label: "Pointer stick"
            options: [{value:"left", label:"Left"}, {value:"right", label:"Right"}, {value:"none", label:"None"}]
            value: root.pointerDraft.pointer_stick
            foreground: root.foreground
            onChanged: function(value) { root.editPointerSetting("pointer_stick", value) }
          }
          Dropdown {
            objectName: "scrollStickPicker"
            Layout.fillWidth: true
            label: "Scroll stick"
            options: [{value:"left", label:"Left"}, {value:"right", label:"Right"}, {value:"none", label:"None"}]
            value: root.pointerDraft.scroll_stick
            foreground: root.foreground
            onChanged: function(value) { root.editPointerSetting("scroll_stick", value) }
          }
          NumberField {
            objectName: "pointerSpeedField"
            Layout.fillWidth: true
            label: "Pointer speed (px/s)"
            value: Math.round(root.pointerDraft.speed)
            from: 1; to: 4000; stepSize: 50
            foreground: root.foreground
            onModified: function(value) { root.editPointerSetting("speed", value) }
          }
          NumberField {
            objectName: "scrollSpeedField"
            Layout.fillWidth: true
            label: "Scroll speed (steps/s)"
            value: Math.round(root.pointerDraft.scroll_speed)
            from: 1; to: 60
            foreground: root.foreground
            onModified: function(value) { root.editPointerSetting("scroll_speed", value) }
          }
          NumberField {
            objectName: "pointerDeadZoneField"
            Layout.fillWidth: true
            label: "Pointer dead zone (%)"
            value: Math.round(root.pointerDraft.dead_zone * 100)
            from: 0; to: 94
            foreground: root.foreground
            onModified: function(value) { root.editPointerSetting("dead_zone", value / 100) }
          }
          NumberField {
            objectName: "scrollDeadZoneField"
            Layout.fillWidth: true
            label: "Scroll dead zone (%)"
            value: Math.round(root.pointerDraft.scroll_dead_zone * 100)
            from: 0; to: 94
            foreground: root.foreground
            onModified: function(value) { root.editPointerSetting("scroll_dead_zone", value / 100) }
          }
          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.labelGap
            Text { text: "Left click button"; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption }
            TextField {
              objectName: "leftClickTokenField"
              Layout.fillWidth: true
              foreground: root.foreground
              text: root.pointerLeftToken
              placeholderText: "e.g. L2; blank for none"
              onTextEdited: root.pointerLeftToken = text
            }
          }
          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.labelGap
            Text { text: "Right click button"; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption }
            TextField {
              objectName: "rightClickTokenField"
              Layout.fillWidth: true
              foreground: root.foreground
              text: root.pointerRightToken
              placeholderText: "e.g. R2; blank for none"
              onTextEdited: root.pointerRightToken = text
            }
          }
        }

        Toggle {
          objectName: "invertScrollToggle"
          Layout.fillWidth: true
          visible: root.pointerDraft.enabled
          label: "Invert scrolling"
          checked: root.pointerDraft.invert_scroll
          foreground: root.foreground
          onClicked: root.editPointerSetting("invert_scroll", !root.pointerDraft.invert_scroll)
        }

        Text {
          Layout.fillWidth: true
          visible: root.pointerDraft.enabled
          text: "A button that has a binding keeps it, and won't also click."
          textFormat: Text.PlainText
          color: Qt.darker(root.foreground, 1.5)
          wrapMode: Text.WordWrap
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)
          Button {
            objectName: "applyPointerButton"
            text: "Apply"
            enabled: root.pointerDirty && !root.settingsBusy
            focusable: root.windowMode
            bordered: true
            foreground: root.foreground
            onClicked: root.applyPointerSettings()
          }
          Button {
            objectName: "resetPointerButton"
            text: "Reset"
            enabled: root.pointerDirty && !root.settingsBusy
            focusable: root.windowMode
            bordered: true
            foreground: root.foreground
            onClicked: root.resetPointerDraft()
          }
          Text {
            text: root.pointerDirty ? "Unsaved changes" : "Saved"
            color: Qt.darker(root.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      PanelSectionHeader { text: "HYPRLAND OVERLAPS"; foreground: root.foreground }

      Button {
        text: "Check Hyprland shortcuts"
        tooltipText: "List Hyprland shortcuts that use the same buttons as your bindings"
        focusable: root.windowMode
        bordered: true
        foreground: root.foreground
        onClicked: root.loadMappings()
      }

      Text {
        Layout.fillWidth: true
        visible: text !== ""
        text: root.mappingMessage
        textFormat: Text.PlainText
        color: Qt.darker(root.foreground, 1.5)
        wrapMode: Text.WordWrap
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Repeater {
        model: root.mappingState === "available" ? root.matchingMappings : []
        Text {
          required property var modelData
          Layout.fillWidth: true
          text: "Potential overlap · " + root.comboText([modelData.token])
            + (modelData.recorded !== modelData.token ? " → " + root.comboText([modelData.recorded]) : "")
            + "\n" + modelData.description
            + " · " + root.modifierContext(modelData.modifiers) + " · submap " + (modelData.submap || "default")
          textFormat: Text.PlainText
          color: root.foreground
          wrapMode: Text.WordWrap
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
