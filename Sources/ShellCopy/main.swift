import AppKit
import ShellCopyCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var controller: ClipboardController!
    private var timer: Timer?
    private var updates: UpdateController!
    private var hasAPIKey = false
    private var keychainMessage: String?
    private var providerItems: [NSMenuItem] = []
    private let automaticItem = NSMenuItem(title: "Automatically Join Wrapped Lines", action: #selector(toggleAutomatic), keyEquivalent: "")
    private let providerItem = NSMenuItem(title: "Processing Method", action: nil, keyEquivalent: "")
    private let fallbackItem = NSMenuItem(title: "Use Local Rules If AI Fails", action: #selector(toggleLocalFallback), keyEquivalent: "")
    private let hybridItem = NSMenuItem(title: "Use Local Rules Before AI", action: #selector(toggleHybrid), keyEquivalent: "")
    private let cloudStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let diagnosticsItem = NSMenuItem(title: "Last Copy Details", action: nil, keyEquivalent: "")
    private let restoreItem = NSMenuItem(title: "Restore Original Text", action: #selector(restore), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = ApplicationMenu.make()
        updates = UpdateController { [weak self] message in
            NSApp.activate(ignoringOtherApps: true)
            self?.showError(message)
        }
        controller = ClipboardController(pasteboard: .general)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "text.line.first.and.arrowtriangle.forward", accessibilityDescription: "Shell Copy")
            ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Shell Copy")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.setAccessibilityLabel("Shell Copy")

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        for item in [automaticItem, hybridItem, fallbackItem, restoreItem] { item.target = self }
        menu.addItem(automaticItem)
        let methods = NSMenu()
        methods.autoenablesItems = false
        addProviderItem("Local Rules (Offline)", value: "local", to: methods)
        for provider in CloudProvider.allCases {
            addProviderItem("\(provider.name) (Sends Text to \(provider.serviceName))", value: provider.rawValue, to: methods)
        }
        providerItem.submenu = methods
        menu.addItem(providerItem)
        menu.addItem(hybridItem)
        menu.addItem(fallbackItem)
        for provider in CloudProvider.allCases {
            let item = NSMenuItem(title: "\(provider.serviceName) API Key…", action: #selector(configureAPIKey(_:)), keyEquivalent: "")
            item.representedObject = provider.rawValue
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(cloudStatusItem)
        cloudStatusItem.isEnabled = false
        menu.addItem(diagnosticsItem)
        menu.addItem(.separator())
        menu.addItem(restoreItem)
        menu.addItem(.separator())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let versionItem = NSMenuItem(title: "Shell Copy \(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(updates.checkItem)
        menu.addItem(updates.automaticItem)
        let quit = NSMenuItem(title: "Quit Shell Copy", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu

        controller.onStateChange = { [weak self] in self?.updateMenu() }
        loadAPIKey()
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in self?.controller.poll() }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        updates.start()
    }

    private func addProviderItem(_ title: String, value: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: #selector(selectProvider(_:)), keyEquivalent: "")
        item.representedObject = value
        item.target = self
        menu.addItem(item)
        providerItems.append(item)
    }

    func menuWillOpen(_ menu: NSMenu) { updateMenu() }

    private func updateMenu() {
        updates.refreshMenu()
        let provider = controller.cloudProvider
        automaticItem.state = controller.isEnabled ? .on : .off
        providerItem.title = "Processing Method: " + (provider.map {
            $0.name + (controller.isHybridEnabled ? " + Rules" : "")
        } ?? "Local Rules")
        for item in providerItems {
            item.state = (item.representedObject as? String) == (provider?.rawValue ?? "local") ? .on : .off
        }
        fallbackItem.state = controller.isLocalFallbackEnabled ? .on : .off
        fallbackItem.isEnabled = controller.isCloudEnabled
        hybridItem.state = controller.isHybridEnabled ? .on : .off
        hybridItem.isEnabled = controller.isCloudEnabled
        restoreItem.isEnabled = controller.canRestore
        if let keychainMessage {
            cloudStatusItem.title = keychainMessage
        } else if !controller.isEnabled {
            cloudStatusItem.title = "Automatic joining is off."
        } else if let provider {
            if controller.isProcessing {
                cloudStatusItem.title = "\(provider.name) is checking the copied text…"
            } else if let message = controller.cloudMessage {
                cloudStatusItem.title = message
            } else if !hasAPIKey {
                cloudStatusItem.title = "Set a \(provider.serviceName) API key to use \(provider.name)."
            } else {
                cloudStatusItem.title = "\(provider.name) ready. Copy new text to check it."
            }
        } else {
            cloudStatusItem.title = controller.cloudMessage ?? "Local rules only."
        }
        let details = NSMenu()
        details.autoenablesItems = false
        for row in controller.diagnosticDetails {
            let item = NSMenuItem(title: row, action: nil, keyEquivalent: "")
            item.isEnabled = false
            details.addItem(item)
        }
        diagnosticsItem.submenu = details
        diagnosticsItem.isEnabled = !controller.diagnosticDetails.isEmpty
        statusItem.button?.toolTip = "Shell Copy — " + cloudStatusItem.title
    }

    @objc private func toggleAutomatic() { controller.setEnabled(!controller.isEnabled) }
    @objc private func toggleLocalFallback() { controller.setLocalFallbackEnabled(!controller.isLocalFallbackEnabled) }
    @objc private func toggleHybrid() { controller.setHybridEnabled(!controller.isHybridEnabled) }
    @objc private func selectProvider(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        controller.setProvider(CloudProvider(rawValue: value))
        loadAPIKey()
        if let provider = controller.cloudProvider, !hasAPIKey, keychainMessage == nil { configureKey(for: provider) }
    }

    private func loadAPIKey() {
        hasAPIKey = false
        keychainMessage = nil
        do {
            if let provider = controller.cloudProvider, let key = try APIKeyStore.load(for: provider) {
                hasAPIKey = true
                let normalizer = SystemOneNormalizer(provider: provider)
                controller.setCloudNormalizer { text in try await normalizer.normalizeWithReport(text, apiKey: key) }
            } else {
                controller.setCloudNormalizer(nil)
            }
        } catch {
            keychainMessage = error.localizedDescription
            controller.setCloudNormalizer(nil)
        }
        updateMenu()
    }

    @objc private func configureAPIKey(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let provider = CloudProvider(rawValue: value) else { return }
        configureKey(for: provider)
    }

    private func configureKey(for provider: CloudProvider) {
        do {
            let hasKey = try APIKeyStore.load(for: provider) != nil
            let alert = NSAlert()
            alert.messageText = "\(provider.serviceName) API Key"
            alert.informativeText = "When \(provider.name) is selected and automatic joining is on, eligible copied text is sent to \(provider.serviceName). Each service has a separate key in the macOS keychain. You can paste a key or import a plain text key file."
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
            field.placeholderString = hasKey ? "Enter a replacement API key" : "Enter your API key"
            defer { field.stringValue = "" }
            alert.accessoryView = field
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Import File…")
            if hasKey { alert.addButton(withTitle: "Remove Key") }
            NSApp.activate(ignoringOtherApps: true)
            alert.window.initialFirstResponder = field
            let response = alert.runModal()
            switch response.rawValue {
            case NSApplication.ModalResponse.alertFirstButtonReturn.rawValue:
                try APIKeyStore.save(APIKeyFile.validated(field.stringValue), for: provider)
            case NSApplication.ModalResponse.alertThirdButtonReturn.rawValue:
                let panel = NSOpenPanel()
                panel.title = "Import \(provider.name) API Key"
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try APIKeyStore.save(APIKeyFile.read(url), for: provider)
            case NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1:
                try APIKeyStore.remove(for: provider)
                if controller.cloudProvider == provider { controller.setProvider(nil) }
            default: return
            }
            if controller.cloudProvider == provider || !controller.isCloudEnabled { loadAPIKey() }
        } catch { showError(error.localizedDescription) }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Shell Copy"
        alert.informativeText = message
        alert.runModal()
    }
    @objc private func restore() { controller.restoreOriginal() }
    @objc private func quitApp() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate() }
}

// Import files without placing the secret in shell arguments or the clipboard.
if CommandLine.arguments.count > 1 {
    let args = Array(CommandLine.arguments.dropFirst())
    guard (args.count == 3 || (args.count == 4 && args[3] == "--select")),
          args[0] == "--import-api-key", let provider = CloudProvider(rawValue: args[1]) else {
        fputs("Usage: ShellCopy --import-api-key jev|bjev /path/to/key.txt [--select]\n", stderr)
        exit(2)
    }
    do {
        try APIKeyStore.save(APIKeyFile.read(URL(fileURLWithPath: args[2])), for: provider)
        if args.count == 4 {
            let appID = "local.shell-copy.app" as CFString
            CFPreferencesSetAppValue(ClipboardController.providerKey as CFString, provider.rawValue as CFString, appID)
            guard CFPreferencesAppSynchronize(appID) else {
                fputs("API key saved, but the provider preference could not be saved. Select it in the app menu.\n", stderr)
                exit(1)
            }
        }
        print("\(provider.name) API key saved in the macOS keychain. Restart Shell Copy to load it.")
        exit(0)
    } catch {
        fputs("API key import failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.setActivationPolicy(.accessory)
application.delegate = delegate
application.run()
